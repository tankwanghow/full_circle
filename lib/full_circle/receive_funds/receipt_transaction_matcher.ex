defmodule FullCircle.ReceiveFund.ReceiptTransactionMatcher do
  use FullCircle.Schema
  import Ecto.Changeset

  schema "receipt_transaction_matchers" do
    field :_persistent_id, :integer
    field :match_amount, :decimal, default: 0

    belongs_to :receipt, FullCircle.ReceiveFund.Receipt
    belongs_to :transaction, FullCircle.Accounting.Transaction

    field :delete, :boolean, virtual: true, default: false
    field :doc_type, :string, virtual: true
    field :doc_date, :date, virtual: true
    field :doc_no, :string, virtual: true
    field :amount, :decimal, virtual: true
    field :other_match_amount, :decimal, virtual: true
  end

  @doc false
  def changeset(receipt, attrs) do
    receipt
    |> cast(attrs, [:_persistent_id, :match_amount, :transaction_id])
    |> validate_required([:transaction_id])

    # |> compute_balance()
  end

  # defp compute_fields(changeset) do
  #   amount = fetch_field!(changeset, :amount)
  #   balance = fetch_field!(changeset, :balance)
  #   match_amt = fetch_field!(changeset, :match_amount)

  #   bal =

  #   good_amount = Decimal.mult(qty, price) |> Decimal.add(disc) |> Decimal.round(2)
  #   tax_amount = Decimal.mult(good_amount, rate) |> Decimal.round(2)
  #   amount = Decimal.add(good_amount, tax_amount)

  #   changeset
  #   |> put_change(:good_amount, good_amount)
  #   |> put_change(:tax_amount, tax_amount)
  #   |> put_change(:amount, amount)
  #   |> put_change(:quantity, qty)
  # end
end
