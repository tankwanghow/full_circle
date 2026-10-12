defmodule FullCircle.BankPayment.Profile do
  use FullCircle.Schema
  import Ecto.Changeset
  use Gettext, backend: FullCircleWeb.Gettext

  alias FullCircle.Accounting.Account

  schema "bank_payment_profiles" do
    belongs_to :company, FullCircle.Sys.Company
    belongs_to :account, Account
    field :format_code, :string
    field :our_account_no, :string
    field :start_date, :date
    field :params, :map, default: %{}
    field :account_name, :string, virtual: true
    timestamps(type: :utc_datetime)
  end

  def changeset(profile, attrs) do
    profile
    |> cast(attrs, [:company_id, :account_id, :format_code, :our_account_no, :start_date, :params])
    |> validate_required([:company_id, :account_id, :format_code, :our_account_no, :start_date])
    |> update_change(:our_account_no, &(&1 && String.replace(&1, ~r/\D/, "")))
    |> validate_params()
    |> validate_bank_account()
    |> unique_constraint(:account_id,
      name: :bank_payment_profiles_company_id_account_id_index,
      message: gettext("already has a bank payment profile")
    )
  end

  # A param named like a row variable would replace that value on every line.
  defp validate_params(cs) do
    reserved = FullCircle.BankPayment.reserved_variables()

    (get_field(cs, :params) || %{})
    |> Map.keys()
    |> Enum.reduce(cs, fn k, acc ->
      cond do
        k in reserved ->
          add_error(acc, :params, gettext("%{key} is a built-in variable name", key: k))

        not (is_binary(k) and k =~ ~r/\A[a-z_][a-z0-9_]*\z/) ->
          add_error(acc, :params, gettext("%{key} is not a valid name", key: inspect(k)))

        true ->
          acc
      end
    end)
  end

  defp validate_bank_account(cs) do
    case {get_field(cs, :account_id), get_field(cs, :company_id)} do
      {nil, _} ->
        cs

      {id, cid} ->
        case FullCircle.Repo.get_by(Account, id: id, company_id: cid) do
          %Account{account_type: "Bank"} -> cs
          _ -> add_error(cs, :account_id, gettext("must be a Bank account of this company"))
        end
    end
  end

  @doc "`key=value` per line → map. Blank lines and `#` comments are ignored."
  def parse_params(text) when is_binary(text) do
    text
    |> String.split(~r/\r?\n/)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
    |> Enum.flat_map(fn line ->
      case String.split(line, "=", parts: 2) do
        [k, v] -> [{String.trim(k), String.trim(v)}]
        _ -> []
      end
    end)
    |> Map.new()
  end

  def parse_params(_), do: %{}

  def params_text(nil), do: ""

  def params_text(params) when is_map(params),
    do: params |> Enum.sort() |> Enum.map_join("\n", fn {k, v} -> "#{k}=#{v}" end)
end
