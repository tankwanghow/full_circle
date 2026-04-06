defmodule FullCircle.BankReconciliation.BankStatementBalance do
  use FullCircle.Schema
  import Ecto.Changeset

  schema "bank_statement_balances" do
    field :from_date, :date
    field :to_date, :date
    field :opening_balance, :decimal
    field :closing_balance, :decimal
    field :report_snapshot, :map
    field :finalized_at, :utc_datetime

    belongs_to :account, FullCircle.Accounting.Account
    belongs_to :company, FullCircle.Sys.Company

    timestamps(type: :utc_datetime)
  end

  def changeset(balance, attrs) do
    balance
    |> cast(attrs, [:from_date, :to_date, :opening_balance, :closing_balance, :report_snapshot, :finalized_at, :account_id, :company_id])
    |> validate_required([:from_date, :to_date, :account_id, :company_id])
    |> unique_constraint([:account_id, :company_id, :from_date, :to_date])
  end
end
