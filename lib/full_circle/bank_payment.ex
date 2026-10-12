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
  alias FullCircle.BillPay.Payment

  alias FullCircle.BankPayment.{
    Banks,
    Batch,
    BatchLine,
    Dismissal,
    Download,
    FileFormat,
    Profile,
    Result,
    Rows
  }

  @max_days_ahead 59
  @recent_change_days 30
  @duplicate_days 14
  @preload [:contact, payment_details: :good, transaction_matchers: :transaction]

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

    digits ++ params ++ Result.validate(Map.get(spec, "result"))
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

  # ── Eligibility ────────────────────────────────────

  defp base_query(%Profile{} = profile, company) do
    from(p in Payment,
      join: c in assoc(p, :contact),
      as: :contact,
      where:
        p.company_id == ^company.id and p.funds_account_id == ^profile.account_id and
          p.payment_date >= ^profile.start_date and p.funds_amount > 0
    )
  end

  defp live_payment_ids, do: from(l in BatchLine, where: l.live, select: l.payment_id)
  defp dismissed_payment_ids, do: from(d in Dismissal, select: d.payment_id)

  defp eligible_query(profile, company) do
    from(p in base_query(profile, company),
      where:
        p.id not in subquery(live_payment_ids()) and p.id not in subquery(dismissed_payment_ids())
    )
  end

  def eligible_payments(%Profile{} = profile, company) do
    since = DateTime.add(DateTime.utc_now(), -@recent_change_days * 86_400, :second)

    rows =
      from([p, contact: c] in eligible_query(profile, company),
        order_by: [desc: p.payment_date, desc: p.payment_no],
        select: %{
          id: p.id,
          payment_no: p.payment_no,
          payment_date: p.payment_date,
          amount: p.funds_amount,
          contact_name: c.name,
          bank_code: c.bank_code,
          account_no: c.bank_account_no,
          account_name: c.bank_account_name,
          changed_at: c.bank_details_changed_at
        }
      )
      |> Repo.all()

    reasons = last_bank_reasons(Enum.map(rows, & &1.id))

    Enum.map(rows, fn r ->
      Map.merge(r, %{
        bank_name: Banks.name(r.bank_code),
        has_bank:
          not is_nil(r.bank_code) and not is_nil(r.account_no) and not is_nil(r.account_name),
        recent_change: not is_nil(r.changed_at) and DateTime.compare(r.changed_at, since) == :gt,
        last_reason: Map.get(reasons, r.id)
      })
    end)
  end

  defp last_bank_reasons(ids) do
    from(l in BatchLine,
      where: l.payment_id in ^ids and l.status == "rejected",
      order_by: l.record_no,
      select: {l.payment_id, l.bank_reason}
    )
    |> Repo.all()
    |> Map.new()
  end

  # ── Batch creation ─────────────────────────────────

  def create_batches(profile_id, payment_ids, %Date{} = payment_date, company, user, opts \\ []) do
    with true <- can?(user, :create_bank_payment_batch, company) || :not_authorise,
         %Profile{} = profile <-
           get_profile(profile_id, company) || {:error, "bank payment profile not found"},
         :ok <- check_payment_date(payment_date, company),
         %FileFormat{} = format <-
           effective_format(company.id, profile.format_code, today(company)) ||
             {:error, "no bank file format '#{profile.format_code}' in force today"},
         :ok <- check_profile(format.spec, profile),
         {:ok, payments} <- load_selected(profile, payment_ids, company),
         :ok <- preflight(payments),
         :ok <- if(opts[:force], do: :ok, else: no_duplicates(payments, company)) do
      do_create(profile, format, Enum.map(payments, & &1.id), payment_date, company, user)
    end
  end

  defp check_payment_date(date, company) do
    first = today(company)
    last = Date.add(first, @max_days_ahead)

    if Date.compare(date, first) != :lt and Date.compare(date, last) != :gt,
      do: :ok,
      else: {:error, "payment date must be between #{first} and #{last}"}
  end

  defp check_profile(spec, profile) do
    case missing_params(spec, profile) ++ our_account_errors(spec, profile) do
      [] -> :ok
      problems -> {:error, "the bank payment profile needs fixing: " <> Enum.join(problems, "; ")}
    end
  end

  defp load_selected(profile, payment_ids, company) do
    ids = payment_ids |> List.wrap() |> Enum.uniq()

    payments =
      from(p in base_query(profile, company), where: p.id in ^ids, preload: ^@preload)
      |> Repo.all()

    cond do
      ids == [] ->
        {:error, "tick at least one payment"}

      length(payments) != length(ids) ->
        {:error, "some ticked payments are not eligible for this bank account"}

      true ->
        {:ok, Enum.sort_by(payments, &{&1.payment_date, &1.payment_no})}
    end
  end

  defp preflight(payments) do
    ids = Enum.map(payments, & &1.id)

    live =
      MapSet.new(
        Repo.all(
          from(l in BatchLine, where: l.live and l.payment_id in ^ids, select: l.payment_id)
        )
      )

    dismissed =
      MapSet.new(
        Repo.all(from(d in Dismissal, where: d.payment_id in ^ids, select: d.payment_id))
      )

    errors =
      Enum.flat_map(payments, fn p ->
        c = p.contact
        bank = Banks.get(c.bank_code)

        cond do
          MapSet.member?(live, p.id) ->
            ["#{p.payment_no}: already in a bank batch"]

          MapSet.member?(dismissed, p.id) ->
            ["#{p.payment_no}: marked paid outside file"]

          is_nil(c.bank_code) or is_nil(c.bank_account_no) or is_nil(c.bank_account_name) ->
            ["#{p.payment_no}: #{c.name} has no bank details"]

          is_nil(bank) or String.length(c.bank_account_no) not in bank.lengths ->
            ["#{p.payment_no}: #{c.name}'s account number does not suit #{c.bank_code}"]

          not Decimal.equal?(p.funds_amount, Decimal.round(p.funds_amount, 2)) ->
            ["#{p.payment_no}: amount #{p.funds_amount} has more than 2 decimal places"]

          true ->
            []
        end
      end)

    if errors == [], do: :ok, else: {:error, errors}
  end

  defp no_duplicates(payments, company) do
    since = DateTime.add(DateTime.utc_now(), -@duplicate_days * 86_400, :second)
    ids = Enum.map(payments, & &1.id)

    existing =
      from(l in BatchLine,
        join: b in Batch,
        on: b.id == l.batch_id,
        join: p in Payment,
        on: p.id == l.payment_id,
        where:
          b.company_id == ^company.id and l.live and b.inserted_at >= ^since and
            l.payment_id not in ^ids,
        select: {p.contact_id, l.amount, l.payment_no, b.filename}
      )
      |> Repo.all()

    in_files =
      for p <- payments,
          {cid, amt, no, file} <- existing,
          cid == p.contact_id and Decimal.equal?(amt, p.funds_amount) do
        "#{p.payment_no}: #{p.contact.name} #{p.funds_amount} looks like #{no} already in #{file}"
      end

    within =
      payments
      |> Enum.group_by(&{&1.contact_id, Decimal.normalize(&1.funds_amount)})
      |> Enum.filter(fn {_, ps} -> length(ps) > 1 end)
      |> Enum.map(fn {_, ps} ->
        "#{Enum.map_join(ps, ", ", & &1.payment_no)}: same supplier and amount in this selection"
      end)

    case in_files ++ within do
      [] -> :ok
      msgs -> {:duplicates, msgs}
    end
  end

  defp do_create(profile, format, ids, payment_date, company, user) do
    Repo.transaction(fn ->
      # Serialises batch creation per profile so sequence numbers never collide.
      Repo.one!(from(p in Profile, where: p.id == ^profile.id, lock: "FOR UPDATE", select: p.id))
      # Any open Payment form now saves stale instead of changing the amount.
      Repo.update_all(from(p in Payment, where: p.id in ^ids), inc: [lock_version: 1])

      payments =
        with {:ok, ps} <- load_selected(profile, ids, company),
             :ok <- preflight(ps) do
          ps
        else
          {:error, e} -> Repo.rollback(e)
        end

      base = header_ctx(profile, company, payment_date)

      stem =
        filename!(fn -> FileSpec.filename(format.spec, base, nil) end) ||
          "#{format.code}_#{Calendar.strftime(payment_date, "%Y%m%d")}_"

      first = next_seq(company.id, stem)

      payments
      |> Enum.chunk_every(FileSpec.max_rows(format.spec) || length(payments))
      |> Enum.with_index(first)
      |> Enum.map(fn {chunk, seq} ->
        insert_batch!(profile, format, chunk, base, stem, seq, payment_date, company, user)
      end)
    end)
  end

  defp header_ctx(profile, company, payment_date) do
    profile.params
    |> Kernel.||(%{})
    |> Map.drop(reserved_variables())
    |> Map.merge(%{
      "our_account_no" => profile.our_account_no,
      "payment_date" => payment_date,
      "today" => today(company),
      "company_name" => company.name
    })
  end

  defp filename!(fun) do
    fun.()
  rescue
    e in ArgumentError -> Repo.rollback(Exception.message(e))
  end

  # Voided batches count: banks refuse a filename that was already uploaded.
  defp next_seq(company_id, stem) do
    (Repo.one(
       from(b in Batch,
         where: b.company_id == ^company_id and b.filename_stem == ^stem,
         select: max(b.seq)
       )
     ) || 0) + 1
  end

  defp batch_no(company, seq),
    do: Calendar.strftime(today(company), "%Y%m%d") <> String.pad_leading("#{seq}", 3, "0")

  defp insert_batch!(profile, format, chunk, base, stem, seq, payment_date, company, user) do
    header = base |> Map.put("seq", seq) |> Map.put("batch_no", batch_no(company, seq))

    filename =
      filename!(fn -> FileSpec.filename(format.spec, base, seq) end) ||
        "#{stem}#{seq}.#{FileSpec.extension(format.spec)}"

    total = Enum.reduce(chunk, Decimal.new(0), &Decimal.add(&1.funds_amount, &2))

    batch =
      %Batch{}
      |> Batch.changeset(%{
        company_id: company.id,
        profile_id: profile.id,
        format_id: format.id,
        spec: format.spec,
        payment_date: payment_date,
        filename_stem: stem,
        filename: filename,
        seq: seq,
        header: dump_header(header),
        count: length(chunk),
        total: total,
        created_by_id: user.id
      })
      |> Repo.insert()
      |> case do
        {:ok, b} -> b
        {:error, _} -> Repo.rollback("file #{filename} already exists; try again")
      end

    lines =
      Enum.map(chunk, fn p ->
        attrs =
          p
          |> Rows.line_attrs()
          |> Map.merge(%{batch_id: batch.id, payment_id: p.id, record_no: next_record_no()})

        case %BatchLine{} |> BatchLine.changeset(attrs) |> Repo.insert() do
          {:ok, l} ->
            l

          {:error, cs} ->
            if Keyword.has_key?(cs.errors, :payment_id),
              do: Repo.rollback("#{p.payment_no} was just batched by someone else"),
              else:
                Repo.rollback(
                  "#{p.payment_no}: " <>
                    Enum.map_join(cs.errors, "; ", fn {f, {m, _}} -> "#{f} #{m}" end)
                )
        end
      end)

    case render_file(format.spec, Enum.map(lines, &Rows.to_row/1), header) do
      {:ok, _} -> :ok
      {:error, msg} -> Repo.rollback(msg)
    end

    Repo.insert!(
      Sys.log_changeset(
        :create_bank_payment_batch,
        batch,
        %{
          "filename" => filename,
          "count" => "#{batch.count}",
          "total" => Decimal.to_string(total)
        },
        company,
        user
      )
    )

    batch
  end

  defp next_record_no do
    %{rows: [[n]]} = Repo.query!("SELECT nextval('bank_payment_record_seq')")
    n
  end

  defp dump_header(header) do
    Map.new(header, fn
      {k, %Date{} = d} -> {k, Date.to_iso8601(d)}
      kv -> kv
    end)
  end

  defp load_header(header) do
    Enum.reduce(["payment_date", "today"], header, fn k, acc ->
      Map.update(acc, k, nil, &Date.from_iso8601!/1)
    end)
  end

  # ── Listing and downloads ──────────────────────────

  defp get_batch(id, company) do
    case Ecto.UUID.cast(id || "") do
      {:ok, uuid} -> Repo.get_by(Batch, id: uuid, company_id: company.id)
      :error -> nil
    end
  end

  def list_batches(company) do
    from(b in Batch,
      where: b.company_id == ^company.id,
      order_by: [desc: b.inserted_at, desc: b.seq],
      limit: 50,
      preload: [:created_by]
    )
    |> Repo.all()
  end

  def downloads_by_batch(ids) do
    from(d in Download, where: d.batch_id in ^ids, order_by: d.inserted_at, preload: [:user])
    |> Repo.all()
    |> Enum.group_by(& &1.batch_id)
  end

  @doc """
  Rebuilds each batch's file from its saved lines, header and spec, logging the
  download. A batch already downloaded needs a reason; after submission only an
  admin may download again; voided batches never.
  """
  def download_files(ids, reason, company, user) do
    reason = String.trim(reason || "")

    with true <- can?(user, :create_bank_payment_batch, company) || :not_authorise do
      Repo.transaction(fn ->
        Enum.map(List.wrap(ids), fn id ->
          case download_one(id, reason, company, user) do
            {:ok, file} -> file
            {:error, msg} -> Repo.rollback(msg)
          end
        end)
      end)
    end
  end

  defp download_one(id, reason, company, user) do
    with %Batch{} = batch <- get_batch(id, company) || {:error, "batch not found"},
         :ok <- may_download(batch, reason, company, user),
         {:ok, file} <- batch_file(batch) do
      Repo.insert!(
        Download.changeset(%Download{}, %{
          batch_id: batch.id,
          user_id: user.id,
          reason: if(reason == "", do: nil, else: reason)
        })
      )

      Repo.insert!(
        Sys.log_changeset(
          :download_bank_payment_batch,
          batch,
          %{"filename" => batch.filename, "reason" => reason},
          company,
          user
        )
      )

      {:ok, file}
    end
  end

  defp may_download(%Batch{status: "voided", filename: f}, _reason, _company, _user),
    do: {:error, "#{f} is voided and cannot be downloaded; its payments may be in a newer file"}

  defp may_download(batch, reason, company, user) do
    cond do
      not Repo.exists?(from(d in Download, where: d.batch_id == ^batch.id)) ->
        :ok

      reason == "" ->
        {:error, "a reason is needed to download #{batch.filename} again"}

      batch.status != "exported" and not can?(user, :admin_bank_payment_batch, company) ->
        {:error,
         "#{batch.filename} was submitted to the bank; only an admin can download it again"}

      true ->
        :ok
    end
  end

  defp batch_file(batch) do
    lines = Repo.all(from(l in BatchLine, where: l.batch_id == ^batch.id, order_by: l.record_no))

    case render_file(batch.spec, Enum.map(lines, &Rows.to_row/1), load_header(batch.header)) do
      {:ok, text} -> {:ok, {batch.filename, text}}
      {:error, msg} -> {:error, msg}
    end
  end

  def zip(files) do
    entries = Enum.map(files, fn {name, text} -> {String.to_charlist(name), text} end)
    {:ok, {_name, bin}} = :zip.create(~c"bank_batches.zip", entries, [:memory])
    {:ok, bin}
  end

  @doc "Renders `spec` (saved or not) against up to 10 currently eligible payments with bank details."
  def preview(spec, %Profile{} = profile, company) do
    rows =
      from([p, contact: c] in eligible_query(profile, company),
        where:
          not is_nil(c.bank_code) and not is_nil(c.bank_account_no) and
            not is_nil(c.bank_account_name),
        order_by: [desc: p.payment_date],
        limit: 10,
        preload: ^@preload
      )
      |> Repo.all()
      |> Enum.with_index(1)
      |> Enum.map(fn {p, i} ->
        p |> Rows.line_attrs() |> Map.put(:record_no, i) |> Rows.to_row()
      end)

    header =
      profile
      |> header_ctx(company, today(company))
      |> Map.merge(%{"seq" => 1, "batch_no" => batch_no(company, 1)})

    render_file(spec, rows, header)
  end

  # ── Payment lock ───────────────────────────────────

  @locked_fields [:funds_amount, :contact_id, :funds_account_id, :payment_date]

  @doc "Refuses changes to a batched Payment's amount, supplier, funds account or date."
  def assert_payment_unlocked(%Payment{id: id}, %Ecto.Changeset{} = cs) do
    case live_batch_filename(id) do
      nil ->
        :ok

      filename ->
        if Enum.any?(@locked_fields, &Map.has_key?(cs.changes, &1)),
          do: {:error, :bank_batched, filename},
          else: :ok
    end
  end

  def live_batch_filename(payment_id) do
    from(l in BatchLine,
      join: b in Batch,
      on: b.id == l.batch_id,
      where: l.payment_id == ^payment_id and l.live,
      select: b.filename
    )
    |> Repo.one()
  end

  # ── Lifecycle ──────────────────────────────────────

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  def batch_lines(batch_id, company) do
    case get_batch(batch_id, company) do
      nil -> []
      b -> Repo.all(from(l in BatchLine, where: l.batch_id == ^b.id, order_by: l.record_no))
    end
  end

  def mark_submitted(batch_id, company, user) do
    with true <- can?(user, :create_bank_payment_batch, company) || :not_authorise,
         %Batch{status: "exported"} = batch <-
           get_batch(batch_id, company) || {:error, "batch not found"} do
      Multi.new()
      |> Multi.update(
        :submit_bank_payment_batch,
        Batch.submit_changeset(batch, %{submitted_by_id: user.id, submitted_at: now()})
      )
      |> Sys.insert_log_for(
        :submit_bank_payment_batch,
        %{"filename" => batch.filename},
        company,
        user
      )
      |> Repo.transaction()
      |> case do
        {:ok, %{submit_bank_payment_batch: b}} -> {:ok, b}
        {:error, _, cs, _} -> {:error, cs}
      end
    else
      %Batch{} -> {:error, "only an exported batch can be marked submitted"}
      other -> other
    end
  end

  def void_batch(batch_id, reason, company, user) do
    reason = String.trim(reason || "")

    with true <- can?(user, :create_bank_payment_batch, company) || :not_authorise,
         %Batch{} = batch <- get_batch(batch_id, company) || {:error, "batch not found"},
         :ok <- may_void(batch, company, user),
         true <- reason != "" || {:error, "a reason is required to void a batch"} do
      Multi.new()
      |> Multi.update(
        :void_bank_payment_batch,
        Batch.void_changeset(batch, %{
          void_reason: reason,
          voided_by_id: user.id,
          voided_at: now()
        })
      )
      |> Multi.update_all(:free_lines, from(l in BatchLine, where: l.batch_id == ^batch.id),
        set: [live: false]
      )
      |> Sys.insert_log_for(
        :void_bank_payment_batch,
        %{"reason" => reason, "filename" => batch.filename},
        company,
        user
      )
      |> Repo.transaction()
      |> case do
        {:ok, %{void_bank_payment_batch: b}} -> {:ok, b}
        {:error, _, cs, _} -> {:error, cs}
      end
    end
  end

  defp may_void(%Batch{status: "exported"}, _company, _user), do: :ok

  defp may_void(%Batch{status: "submitted"}, company, user) do
    if can?(user, :admin_bank_payment_batch, company),
      do: :ok,
      else: {:error, "this batch was submitted to the bank; only an admin can void it"}
  end

  defp may_void(%Batch{status: "voided"}, _company, _user),
    do: {:error, "batch is already voided"}

  defp may_void(_batch, _company, _user),
    do: {:error, "this batch has a bank result; release single lines instead"}

  def release_line(line_id, reason, company, user),
    do: resolve_line(line_id, reason, company, user, :release)

  def return_line(line_id, reason, company, user),
    do: resolve_line(line_id, reason, company, user, :return)

  defp resolve_line(line_id, reason, company, user, kind) do
    reason = String.trim(reason || "")
    action = if kind == :release, do: :create_bank_payment_batch, else: :admin_bank_payment_batch

    with true <- can?(user, action, company) || :not_authorise,
         {%BatchLine{} = line, %Batch{} = batch} <-
           get_line(line_id, company) || {:error, "line not found"},
         :ok <- may_resolve(kind, line, batch),
         true <- reason != "" || {:error, "a reason is required"} do
      log_name =
        if kind == :release, do: :release_bank_payment_line, else: :return_bank_payment_line

      Repo.transaction(fn ->
        line =
          line
          |> BatchLine.resolve_changeset(%{
            status: "rejected",
            live: false,
            bank_reason: reason,
            released_by_id: user.id,
            released_at: now()
          })
          |> Repo.update!()

        batch = refresh_batch_status!(batch)

        Repo.insert!(
          Sys.log_changeset(
            log_name,
            batch,
            %{"payment_no" => line.payment_no, "reason" => reason},
            company,
            user
          )
        )

        line
      end)
    end
  end

  defp may_resolve(:release, %BatchLine{status: "pending"}, %Batch{status: s})
       when s in ["submitted", "partly_rejected"], do: :ok

  defp may_resolve(:release, _line, _batch),
    do: {:error, "only a pending line of a submitted batch can be released"}

  defp may_resolve(:return, %BatchLine{status: "paid"}, %Batch{status: s})
       when s in ["completed", "partly_rejected"], do: :ok

  defp may_resolve(:return, _line, _batch),
    do: {:error, "only a paid line of a completed batch can be marked returned"}

  defp get_line(line_id, company) do
    case Ecto.UUID.cast(line_id || "") do
      {:ok, uuid} ->
        from(l in BatchLine,
          join: b in Batch,
          on: b.id == l.batch_id,
          where: l.id == ^uuid and b.company_id == ^company.id,
          select: {l, b}
        )
        |> Repo.one()

      :error ->
        nil
    end
  end

  defp refresh_batch_status!(%Batch{} = batch) do
    statuses = Repo.all(from(l in BatchLine, where: l.batch_id == ^batch.id, select: l.status))

    status =
      cond do
        "pending" in statuses -> batch.status
        Enum.all?(statuses, &(&1 == "paid")) -> "completed"
        true -> "partly_rejected"
      end

    if status == batch.status,
      do: batch,
      else: batch |> Batch.status_changeset(status) |> Repo.update!()
  end

  # ── Paid outside file ──────────────────────────────

  defp get_payment(id, company) do
    case Ecto.UUID.cast(id || "") do
      {:ok, uuid} -> Repo.get_by(Payment, id: uuid, company_id: company.id)
      :error -> nil
    end
  end

  def dismiss_payment(payment_id, note, company, user) do
    with true <- can?(user, :create_bank_payment_batch, company) || :not_authorise,
         %Payment{} = p <- get_payment(payment_id, company) || {:error, "payment not found"},
         nil <- live_batch_filename(p.id) do
      Multi.new()
      |> Multi.insert(
        :dismiss_bank_payment,
        Dismissal.changeset(%Dismissal{}, %{
          company_id: company.id,
          payment_id: p.id,
          user_id: user.id,
          note: note
        })
      )
      |> Sys.insert_log_for(
        :dismiss_bank_payment,
        %{"payment_no" => p.payment_no, "note" => note || ""},
        company,
        user
      )
      |> Repo.transaction()
      |> case do
        {:ok, %{dismiss_bank_payment: d}} -> {:ok, d}
        {:error, _, cs, _} -> {:error, cs}
      end
    else
      filename when is_binary(filename) -> {:error, "this payment is in bank batch #{filename}"}
      other -> other
    end
  end

  def undismiss_payment(payment_id, company, user) do
    with true <- can?(user, :create_bank_payment_batch, company) || :not_authorise,
         %Payment{} = p <- get_payment(payment_id, company) || {:error, "payment not found"},
         %Dismissal{} = d <-
           Repo.get_by(Dismissal, payment_id: p.id) ||
             {:error, "payment is not marked paid outside file"} do
      Multi.new()
      |> Multi.delete(:undismiss_bank_payment, d)
      |> Sys.insert_log_for(
        :undismiss_bank_payment,
        %{"payment_no" => p.payment_no},
        company,
        user
      )
      |> Repo.transaction()
      |> case do
        {:ok, %{undismiss_bank_payment: d}} -> {:ok, d}
        {:error, _, cs, _} -> {:error, cs}
      end
    end
  end

  def list_dismissed(company) do
    from(d in Dismissal,
      join: p in Payment,
      on: p.id == d.payment_id,
      join: c in assoc(p, :contact),
      where: d.company_id == ^company.id,
      order_by: [desc: d.inserted_at],
      limit: 200,
      select: %{
        payment_id: p.id,
        payment_no: p.payment_no,
        payment_date: p.payment_date,
        contact_name: c.name,
        amount: p.funds_amount,
        note: d.note,
        inserted_at: d.inserted_at
      }
    )
    |> Repo.all()
  end

  # ── Bank result import ─────────────────────────────

  def import_result(text, company, user) when is_binary(text) do
    with true <- can?(user, :create_bank_payment_batch, company) || :not_authorise,
         {:ok, batch, parsed} <- find_result_batch(text, company) do
      apply_result(batch, parsed, company, user)
    end
  end

  defp find_result_batch(text, company) do
    from(b in Batch,
      where: b.company_id == ^company.id and b.status != "voided",
      order_by: [desc: b.inserted_at],
      limit: 200
    )
    |> Repo.all()
    |> Enum.find_value({:error, "no batch matches this result file"}, fn b ->
      with %{} = r <- b.spec["result"],
           {:ok, parsed} <- Result.parse(text, r),
           true <- Result.same_file?(parsed.filename, b.filename) do
        {:ok, b, parsed}
      else
        _ -> nil
      end
    end)
  end

  defp apply_result(batch, parsed, company, user) do
    Repo.transaction(fn ->
      batch = Repo.one!(from(b in Batch, where: b.id == ^batch.id, lock: "FOR UPDATE"))

      lines =
        Repo.all(from(l in BatchLine, where: l.batch_id == ^batch.id))
        |> Map.new(&{&1.record_no, &1})

      empty = %{
        paid: [],
        rejected: [],
        unmatched: [],
        mismatched: [],
        conflicts: [],
        seen: MapSet.new()
      }

      report =
        Enum.reduce(parsed.lines, empty, fn r, acc ->
          line = Map.get(lines, r.record_no)
          target = if r.success, do: "paid", else: "rejected"

          cond do
            is_nil(line) ->
              %{acc | unmatched: acc.unmatched ++ [r.record_id]}

            not Decimal.equal?(r.amount, line.amount) ->
              %{
                acc
                | mismatched:
                    acc.mismatched ++
                      ["#{line.payment_no}: bank #{r.amount}, file #{line.amount}"]
              }

            line.status == target ->
              %{acc | seen: MapSet.put(acc.seen, line.record_no)}

            line.status == "pending" ->
              attrs =
                if r.success,
                  do: %{status: "paid"},
                  else: %{status: "rejected", live: false, bank_reason: r.reason}

              line |> BatchLine.resolve_changeset(attrs) |> Repo.update!()
              key = if r.success, do: :paid, else: :rejected

              acc
              |> Map.update!(key, &(&1 ++ [line.payment_no]))
              |> Map.update!(:seen, &MapSet.put(&1, line.record_no))

            true ->
              %{
                acc
                | conflicts:
                    acc.conflicts ++
                      ["#{line.payment_no}: bank says #{target}, already #{line.status}"],
                  seen: MapSet.put(acc.seen, line.record_no)
              }
          end
        end)

      missing =
        for {no, l} <- Enum.sort_by(lines, &elem(&1, 0)),
            l.status == "pending",
            not MapSet.member?(report.seen, no),
            do: l.payment_no

      batch =
        batch
        |> Batch.result_changeset(%{
          result_imported_at: now(),
          result_filename: parsed.filename,
          submitted_at: batch.submitted_at || now(),
          submitted_by_id: batch.submitted_by_id || user.id
        })
        |> Repo.update!()
        |> refresh_batch_status!()

      Repo.insert!(
        Sys.log_changeset(
          :import_bank_payment_result,
          batch,
          %{
            "result_file" => parsed.filename,
            "paid" => "#{length(report.paid)}",
            "rejected" => "#{length(report.rejected)}"
          },
          company,
          user
        )
      )

      report |> Map.delete(:seen) |> Map.merge(%{batch: batch, missing: missing})
    end)
  end

  defp stringify(attrs), do: Map.new(attrs, fn {k, v} -> {to_string(k), v} end)
end
