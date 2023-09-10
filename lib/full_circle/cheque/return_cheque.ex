defmodule FullCircle.Cheque.ReturnCheque do
  use FullCircle.Schema
  import Ecto.Changeset
  import FullCircle.Helpers
  import FullCircleWeb.Gettext

  schema "return_cheques" do
    field :return_no, :string
    field :return_date, :date
    field :return_reason, :string

    belongs_to :return_from_bank, FullCircle.Accounting.Account
    belongs_to :cheque_owner, FullCircle.Accounting.Contact

    belongs_to :company, FullCircle.Sys.Company

    has_one :cheque, FullCircle.ReceiveFund.ReceivedCheque, on_replace: :nilify

    field :return_from_bank_name, :string, virtual: true
    field :cheque_owner_name, :string, virtual: true
    field :cheque_no, :string, virtual: true
    field :cheque_due_date, :date, virtual: true
    field :cheque_amount, :decimal, virtual: true

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(rtn, attrs) do
    rtn
    |> cast(attrs, [
      :company_id,
      :return_no,
      :return_date,
      :return_reason,
      :return_from_bank_name,
      :return_from_bank_id,
      :cheque_owner_name,
      :cheque_owner_id,
      :cheque_no,
      :cheque_due_date,
      :cheque_amount
    ])
    |> validate_required([
      :company_id,
      :return_no,
      :return_date,
      :return_reason,
      :cheque_owner_name,
      :cheque_no,
      :cheque_due_date,
      :cheque_amount
    ])
    |> validate_id(:return_from_bank_name, :return_from_bank_id)
    |> validate_id(:cheque_owner_name, :cheque_owner_id)
    |> validate_return_date()
    |> put_cheque_assoc(attrs)
  end

  defp put_cheque_assoc(cs, attrs) do
    chq_attrs = attrs["cheque"] || %{}

    if chq_attrs != %{} do
      put_assoc(
        cs,
        :cheque,
        FullCircle.Repo.get!(FullCircle.ReceiveFund.ReceivedCheque, chq_attrs["id"])
      )
    else
      cs
    end
  end

  defp validate_return_date(cs) do
    r_date = fetch_field!(cs, :return_date) || Timex.today()
    d_date = fetch_field!(cs, :cheque_due_date) || Timex.today()
    diff = Timex.diff(r_date, d_date, :days)

    cond do
      diff < 0 ->
        add_error(cs, :return_date, "#{gettext("later than")} #{d_date}")

      diff > 60 ->
        add_error(cs, :return_date, "#{gettext("earlier than")} #{Timex.shift(d_date, days: 45)}")

      true ->
        cs
    end
  end
end
