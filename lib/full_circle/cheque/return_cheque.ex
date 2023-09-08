defmodule FullCircle.Cheque.ReturnCheque do
  use FullCircle.Schema
  import Ecto.Changeset
  import FullCircle.Helpers
  import FullCircleWeb.Gettext

  schema "return_cheques" do
    field :return_cheque_no, :string
    field :return_date, :string
    field :return_reason, :string

    belongs_to :bank, FullCircle.Accounting.Account
    belongs_to :company, FullCircle.Sys.Company

    has_many :cheques, FullCircle.ReceiveFund.ReceivedCheque

    field :bank_name, :string, virtual: true

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(account, attrs) do
    account
    |> cast(attrs, [:company_id, :deposit_no, :deposit_date, :bank_name])
    |> validate_required([:company_id, :deposit_no, :deposit_date, :bank_name])
    |> validate_id(:bank_name, :bank_id)
    |> cast_assoc(:received_cheques)
  end
end
