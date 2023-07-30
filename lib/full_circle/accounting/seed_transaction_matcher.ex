defmodule FullCircle.Accounting.SeedTransactionMatcher do
  use FullCircle.Schema
  import Ecto.Changeset

  schema "seed_transaction_matchers" do
    field :m_doc_type, :string
    field :m_doc_id, :integer
    field :n_doc_type, :string
    field :n_doc_id, :integer
    field :match_amount, :decimal, default: 0

    belongs_to(:transaction, FullCircle.Accounting.Transaction)
  end

  @doc false
  def changeset(seed, attrs) do
    seed
    |> cast(attrs, [:m_doc_type, :m_doc_id, :n_doc_type, :n_doc_id, :match_amount, :transaction_id])
    |> validate_required([
      :m_doc_type,
      :m_doc_id,
      :n_doc_type,
      :n_doc_id,
      :match_amount,
      :transaction_id
    ])
  end
end
