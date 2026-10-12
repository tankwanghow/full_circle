defmodule FullCircle.BankPayment do
  @moduledoc """
  Bank bulk payment files: supplier Payments → a bank upload file (RHB Reflex
  Bulk Pay, PB enterprise ECP Payment), batch lifecycle, bank result import.
  See docs/superpowers/specs/2026-10-12-bank-bulk-payment-design.md and
  .claude/skills/bank-bulk-payment.md.
  """
  import Ecto.Query, warn: false
  import FullCircle.Authorization

  alias Ecto.Multi
  alias FullCircle.{FileSpec, Repo, Sys}
  alias FullCircle.Accounting.Account
  alias FullCircle.BankPayment.{FileFormat, Profile}

  @sources ["payments"]
  @row_vars ~w(record_id payment_no doc_date amount bank_code account_no account_name contact_name reg_no email emails descriptions advice advice_text)
  @child_vars ~w(advice_doc_no advice_doc_date advice_amount)
  @header_vars ~w(our_account_no payment_date today company_name seq batch_no)

  # ── Basics ─────────────────────────────────────────

  @doc "The company's local date. Every 'today' in this feature uses it."
  def today(company),
    do: (company.timezone || "Asia/Kuala_Lumpur") |> DateTime.now!() |> DateTime.to_date()

  def reserved_variables, do: @row_vars ++ @child_vars ++ @header_vars

  @doc "Profile params the spec declares under \"params\"."
  def spec_params(spec),
    do: spec |> Map.get("params", []) |> List.wrap() |> Enum.filter(&is_binary/1)

  def format_variables(spec), do: reserved_variables() ++ spec_params(spec)

  def validate_spec(spec) do
    errors =
      case FileSpec.validate(spec, format_variables(spec), @sources) do
        :ok -> []
        {:error, e} -> e
      end

    case errors ++ bank_key_errors(spec) do
      [] -> :ok
      all -> {:error, all}
    end
  end

  defp bank_key_errors(spec) do
    digits =
      case Map.get(spec, "our_account_no_digits") do
        nil ->
          []

        l when is_list(l) and l != [] ->
          if Enum.all?(l, &(is_integer(&1) and &1 > 0)),
            do: [],
            else: ["our_account_no_digits must be a list of positive integers"]

        _ ->
          ["our_account_no_digits must be a list of positive integers"]
      end

    params =
      case Map.get(spec, "params") do
        nil ->
          []

        l when is_list(l) ->
          if Enum.all?(l, &is_binary/1), do: [], else: ["params must be a list of names"]

        _ ->
          ["params must be a list of names"]
      end

    digits ++ params
  end

  @doc "Renders a bank spec against FileSpec rows and a header context."
  def render_file(spec, rows, header),
    do: FileSpec.render(spec, rows, header, format_variables(spec), @sources)

  # ── Formats ────────────────────────────────────────

  def list_formats(company_id) do
    from(f in FileFormat,
      where: f.company_id == ^company_id,
      order_by: [asc: f.code, desc: f.effective_from]
    )
    |> Repo.all()
  end

  def format_codes(company_id) do
    from(f in FileFormat, where: f.company_id == ^company_id, distinct: true, select: f.code)
    |> Repo.all()
  end

  def effective_format(company_id, code, date) do
    from(f in FileFormat,
      where: f.company_id == ^company_id and f.code == ^code and f.effective_from <= ^date,
      order_by: [desc: f.effective_from],
      limit: 1
    )
    |> Repo.one()
  end

  def format_version_exists?(company_id, code, date_string),
    do: find_format(company_id, code, date_string) != nil

  defp find_format(company_id, code, date_string) do
    with true <- is_binary(code),
         {:ok, date} <- Date.from_iso8601(to_string(date_string)) do
      Repo.get_by(FileFormat, company_id: company_id, code: code, effective_from: date)
    else
      _ -> nil
    end
  end

  @doc "Saves a format version; `replace: true` updates the same (code, effective_from) row. Batches keep their own spec copy."
  def save_format(attrs, company, user, opts \\ []) do
    if can?(user, :manage_bank_payment_config, company) do
      attrs = attrs |> stringify() |> Map.put("company_id", company.id)

      base =
        (opts[:replace] && find_format(company.id, attrs["code"], attrs["effective_from"])) ||
          %FileFormat{}

      Multi.new()
      |> Multi.insert_or_update(:save_bank_file_format, FileFormat.changeset(base, attrs))
      |> Sys.insert_log_for(:save_bank_file_format, Map.drop(attrs, ["spec"]), company, user)
      |> Repo.transaction()
      |> case do
        {:ok, %{save_bank_file_format: f}} -> {:ok, f}
        {:error, _, cs, _} -> {:error, cs}
      end
    else
      :not_authorise
    end
  end

  # ── Templates ──────────────────────────────────────

  defp template_dir, do: Application.app_dir(:full_circle, "priv/bank_file_templates")

  def templates do
    template_dir()
    |> Path.join("*.json")
    |> Path.wildcard()
    |> Enum.map(fn path ->
      t = path |> File.read!() |> Jason.decode!()
      %{code: t["code"], name: t["name"]}
    end)
    |> Enum.sort_by(& &1.code)
  end

  def load_template(code) when is_binary(code) do
    path = Path.join(template_dir(), code <> ".json")

    if code =~ ~r/\A[a-z0-9_]+\z/ and File.exists?(path),
      do: {:ok, path |> File.read!() |> Jason.decode!()},
      else: {:error, "no bank file template '#{code}'"}
  end

  # ── Profiles ───────────────────────────────────────

  defp profiles_query(company) do
    from(p in Profile,
      join: a in Account,
      on: a.id == p.account_id,
      where: p.company_id == ^company.id,
      select: %{p | account_name: a.name}
    )
  end

  def list_profiles(company),
    do: company |> profiles_query() |> order_by([_p, a], a.name) |> Repo.all()

  def get_profile(id, company) do
    case Ecto.UUID.cast(id || "") do
      {:ok, uuid} -> company |> profiles_query() |> where([p], p.id == ^uuid) |> Repo.one()
      :error -> nil
    end
  end

  def bank_accounts(company) do
    from(a in Account,
      where: a.company_id == ^company.id and a.account_type == "Bank",
      order_by: a.name,
      select: {a.name, a.id}
    )
    |> Repo.all()
  end

  def save_profile(%Profile{} = profile, attrs, company, user) do
    if can?(user, :manage_bank_payment_config, company) do
      attrs = attrs |> stringify() |> Map.put("company_id", company.id)
      name = if profile.id, do: :update_bank_payment_profile, else: :create_bank_payment_profile

      Multi.new()
      |> Multi.insert_or_update(name, Profile.changeset(profile, attrs))
      |> Sys.insert_log_for(name, Map.drop(attrs, ["params"]), company, user)
      |> Repo.transaction()
      |> case do
        {:ok, %{^name => p}} -> {:ok, p}
        {:error, _, cs, _} -> {:error, cs}
      end
    else
      :not_authorise
    end
  end

  @doc "What the profile lacks for its format in force today; :no_format when none is."
  def profile_warnings(%Profile{} = profile, company) do
    case effective_format(company.id, profile.format_code, today(company)) do
      nil -> :no_format
      f -> missing_params(f.spec, profile) ++ our_account_errors(f.spec, profile)
    end
  end

  defp missing_params(spec, profile) do
    have = for {k, v} <- profile.params || %{}, v not in [nil, ""], do: k
    Enum.map(spec_params(spec) -- have, &"missing param: #{&1}")
  end

  defp our_account_errors(spec, profile) do
    case Map.get(spec, "our_account_no_digits") do
      l when is_list(l) and l != [] ->
        if String.length(profile.our_account_no || "") in l,
          do: [],
          else: ["our account number must be #{Enum.join(l, "/")} digits for this format"]

      _ ->
        []
    end
  end

  defp stringify(attrs), do: Map.new(attrs, fn {k, v} -> {to_string(k), v} end)
end
