defmodule FullCircle.ReceiveFunds.ReceiptTransactionMatcher do
  use Ecto.Schema
  import Ecto.Changeset

  schema "receipt_transaction_matchers" do
    field :_persistent_id, :integer
    field :amount, :decimal, default: 0

    belongs_to :receipt, FullCircle.ReceiveFunds.Receipt
    belongs_to :transaction, FullCircle.Accounting.Transaction

    field :delete, :boolean, virtual: true, default: false
  end

  @doc false
  def changeset(receipt, attrs) do
    receipt
    |> cast(attrs, [:_persistent_id, :amount, :transaction_id])
    |> validate_required([:amount, :transaction_id])
    |> validate_number(:amount, greater_than: 0)
  end
end
