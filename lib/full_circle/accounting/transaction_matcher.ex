defmodule FullCircle.Accounting.TransactionMatcher do
  use FullCircle.Schema
  import Ecto.Changeset

  schema "transaction_matchers" do
    field :_persistent_id, :integer
    field :doc_date, :date
    field :doc_id, :binary_id
    field :doc_type, :string
    field :match_amount, :decimal, default: 0

    belongs_to :transaction, FullCircle.Accounting.Transaction

    field :delete, :boolean, virtual: true, default: false
    field :account_id, :binary_id, virtual: true
    field :t_doc_type, :string, virtual: true
    field :t_doc_date, :date, virtual: true
    field :t_doc_no, :string, virtual: true
    field :t_doc_id, :string, virtual: true
    field :amount, :decimal, virtual: true
    field :balance, :decimal, virtual: true
    field :particulars, :string, virtual: true
    field :all_matched_amount, :decimal, virtual: true
    field :old_data, :boolean, virtual: true
  end

  @doc false
  def changeset(transaction_matcher, attrs) do
    transaction_matcher
    |> cast(attrs, [
      :_persistent_id,
      :match_amount,
      :account_id,
      :transaction_id,
      :doc_date,
      :doc_type,
      :doc_id,
      :t_doc_no,
      :t_doc_type,
      :t_doc_date,
      :t_doc_id,
      :amount,
      :balance,
      :particulars,
      :all_matched_amount,
      :delete
    ])
    |> validate_required([:transaction_id, :doc_type, :doc_date])
    |> validate_number(:match_amount, not_equal_to: 0)
    |> maybe_mark_for_deletion()
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

  defp maybe_mark_for_deletion(%{data: %{id: nil}} = changeset), do: changeset

  defp maybe_mark_for_deletion(changeset) do
    if get_change(changeset, :delete) do
      %{changeset | action: :delete}
    else
      changeset
    end
  end
end
