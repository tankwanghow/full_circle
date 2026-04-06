defmodule FullCircle.BankReconciliation.BankStatementLine do
  use FullCircle.Schema
  import Ecto.Changeset

  schema "bank_statement_lines" do
    field :statement_date, :date
    field :description, :string
    field :cheque_no, :string
    field :amount, :decimal
    field :reference, :string
    field :source_format, :string
    field :match_group_id, :binary_id

    belongs_to :account, FullCircle.Accounting.Account
    belongs_to :company, FullCircle.Sys.Company

    timestamps(updated_at: false, type: :utc_datetime)
  end

  def changeset(line, attrs) do
    line
    |> cast(attrs, [
      :statement_date,
      :description,
      :cheque_no,
      :amount,
      :reference,
      :source_format,
      :match_group_id,
      :account_id,
      :company_id
    ])
    |> validate_required([:statement_date, :amount, :source_format, :account_id, :company_id])
  end
end
