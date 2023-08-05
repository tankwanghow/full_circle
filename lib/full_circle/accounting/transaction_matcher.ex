defmodule FullCircle.Accounting.TransactionMatcher do
  use FullCircle.Schema
  import Ecto.Changeset

  schema "transaction_matchers" do
    field :_persistent_id, :integer
    field :entity, :string
    field :entity_id, :binary_id
    field :match_amount, :decimal, default: 0

    belongs_to :transaction, FullCircle.Accounting.Transaction

    field :delete, :boolean, virtual: true, default: false
    field :doc_type, :string, virtual: true
    field :doc_date, :date, virtual: true
    field :doc_no, :string, virtual: true
    field :amount, :decimal, virtual: true
    field :balance, :decimal, virtual: true
    field :particulars, :string, virtual: true
    field :all_matched_amount, :decimal, virtual: true
  end

  @doc false
  def changeset(transaction_matcher, attrs) do
    transaction_matcher
    |> cast(attrs, [
      :_persistent_id,
      :match_amount,
      :transaction_id,
      :entity,
      :entity_id,
      :doc_no,
      :doc_type,
      :doc_date,
      :amount,
      :balance,
      :particulars,
      :all_matched_amount
    ])
    |> validate_required([:transaction_id, :entity])
    |> compute_balance()
  end

  defp compute_balance(changeset) do
    amt = (fetch_field!(changeset, :amount) || Decimal.from_float(0.0)) |> Decimal.to_float()

    all_match_amt =
      (fetch_field!(changeset, :all_matched_amount) || Decimal.from_float(0.0))
      |> Decimal.to_float()

    match_amt =
      (fetch_field!(changeset, :match_amount) || Decimal.from_float(0.0)) |> Decimal.to_float()

    balance = amt + all_match_amt + match_amt

    changeset
    |> put_change(:balance, balance |> Decimal.from_float() |> Decimal.round(2))
  end
end
