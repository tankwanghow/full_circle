defmodule FullCircle.ReceiveFunds.ReceivedCheque do
  use Ecto.Schema
  import Ecto.Changeset

  schema "received_cheques" do
    field :_persistent_id, :integer
    field :bank, :string
    field :due_date, :date
    field :state, :string
    field :city, :string
    field :chq_no, :string
    field :amount, :decimal, default: 0

    belongs_to :receipt, FullCircle.ReceiveFunds.Receipt
    # has_one :deposit
    # has_one :return_cheque_note

    field :delete, :boolean, virtual: true, default: false
  end

  @doc false
  def changeset(receipt, attrs) do
    receipt
    |> cast(attrs, [:_persistent_id, :bank, :due_date, :state, :city, :chq_no, :amount, :delete])
    |> validate_required([:bank, :due_date, :state, :city, :chq_no, :amount])
    |> validate_number(:amount, greater_than: 0)
  end
end
