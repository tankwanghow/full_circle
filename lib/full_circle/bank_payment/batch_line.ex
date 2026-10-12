defmodule FullCircle.BankPayment.BatchLine do
  use FullCircle.Schema
  import Ecto.Changeset

  # Snapshot of what went into the file, so a re-download is byte-identical.
  schema "bank_payment_batch_lines" do
    belongs_to :batch, FullCircle.BankPayment.Batch
    belongs_to :payment, FullCircle.BillPay.Payment
    field :record_no, :integer
    field :status, :string, default: "pending"
    field :live, :boolean, default: true
    field :bank_reason, :string
    belongs_to :released_by, FullCircle.UserAccounts.User
    field :released_at, :utc_datetime
    field :payment_no, :string
    field :doc_date, :date
    field :amount, :decimal
    field :bank_code, :string
    field :bank_account_no, :string
    field :bank_account_name, :string
    field :contact_name, :string
    field :email, :string
    field :reg_no, :string
    field :descriptions, :string
    field :advice, {:array, :map}, default: []
  end

  @required [
    :batch_id,
    :payment_id,
    :record_no,
    :payment_no,
    :doc_date,
    :amount,
    :bank_code,
    :bank_account_no,
    :bank_account_name,
    :contact_name
  ]

  def changeset(line, attrs) do
    line
    |> cast(attrs, @required ++ [:email, :reg_no, :descriptions, :advice])
    |> validate_required(@required)
    |> unique_constraint(:payment_id, name: :bank_payment_batch_lines_one_live_per_payment)
  end

  def resolve_changeset(line, attrs),
    do: cast(line, attrs, [:status, :live, :bank_reason, :released_by_id, :released_at])
end
