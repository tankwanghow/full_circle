defmodule FullCircle.Cheque.Deposit do
  use FullCircle.Schema
  import Ecto.Changeset
  import FullCircle.Helpers
  use Gettext, backend: FullCircleWeb.Gettext

  schema "deposits" do
    field :deposit_no, :string
    field :deposit_date, :date
    belongs_to :bank, FullCircle.Accounting.Account, foreign_key: :bank_id
    belongs_to :funds_from, FullCircle.Accounting.Account, foreign_key: :funds_from_id
    field :funds_amount, :decimal, default: 0
    belongs_to :company, FullCircle.Sys.Company

    has_many :cheques, FullCircle.ReceiveFund.ReceivedCheque, on_replace: :nilify

    field :bank_name, :string, virtual: true
    field :funds_from_name, :string, virtual: true
    field :cheques_amount, :decimal, virtual: true, default: 0

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(cs, attrs) do
    cs
    |> cast(attrs, [
      :company_id,
      :deposit_no,
      :deposit_date,
      :bank_name,
      :bank_id,
      :funds_from_name,
      :funds_from_id,
      :funds_amount
    ])
    |> validate_required([:company_id, :deposit_no, :deposit_date, :bank_name])
    |> validate_funds_from_name()
    |> validate_id(:bank_name, :bank_id)
    |> validate_id(:funds_from_name, :funds_from_id)
    |> put_assoc_cheques(attrs)
    |> validate_date(:deposit_date, days_before: 60)
    |> validate_date(:deposit_date, days_after: 4)
    |> validate_deposit_date()
    |> compute_fields()
  end

  def compute_fields(cs) do
    cs |> sum_field_to(:cheques, :amount, :cheques_amount) |> validate_deposit_amount()
  end

  defp validate_deposit_amount(cs) do
    fa = fetch_field!(cs, :funds_amount)
    ca = fetch_field!(cs, :cheques_amount)

    if Decimal.add(fa, ca) |> Decimal.eq?(0) do
      add_unique_error(cs, :cheques_amount, gettext("deposit amount zero"))
    else
      clear_error(cs, :cheques_amount)
    end
  end

  defp validate_funds_from_name(changeset) do
    if fetch_field!(changeset, :funds_amount) |> Decimal.gt?(0) do
      validate_required(changeset, :funds_from_name)
    else
      changeset
    end
  end

  defp put_assoc_cheques(cs, attrs) do
    chqs_attrs = attrs["cheques"] || %{}

    chqs_param =
      chqs_attrs
      |> Enum.map(fn {_, v} ->
        if !is_nil(v) and (v["delete"] == "false" or v["delete"] == "") do
          FullCircle.Repo.get!(FullCircle.ReceiveFund.ReceivedCheque, v["id"])
        else
          nil
        end
      end)
      |> Enum.reject(fn x -> is_nil(x) end)

    if(chqs_attrs != %{}, do: put_assoc(cs, :cheques, chqs_param), else: cs)
  end

  defp validate_deposit_date(cs) do
    if get_change(cs, :cheques) do
      d_date = fetch_field!(cs, :deposit_date)

      if cs.changes.cheques
         |> Enum.any?(fn c -> Timex.compare(d_date, c.data.due_date) == -1 end) do
        add_unique_error(cs, :deposit_date, gettext("cheque due date error"))
      else
        cs
      end
    else
      cs
    end
  end
end
