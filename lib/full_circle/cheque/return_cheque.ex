defmodule FullCircle.Cheque.ReturnCheque do
  use FullCircle.Schema
  import Ecto.Changeset
  import FullCircle.Helpers

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
    |> validate_date(:return_date, days_after: 0)
    |> validate_date(:return_date, days_before: 60)
    |> put_cheque_assoc(attrs)
  end

  defp put_cheque_assoc(cs, attrs) do
    chq_attrs = attrs["cheque"] || %{}

    if chq_attrs != %{} and chq_attrs["id"] != "" do
      put_assoc(
        cs,
        :cheque,
        FullCircle.Repo.get!(FullCircle.ReceiveFund.ReceivedCheque, chq_attrs["id"])
      )
    else
      cs
    end
  end
end
