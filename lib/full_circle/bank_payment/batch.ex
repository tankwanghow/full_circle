defmodule FullCircle.BankPayment.Batch do
  use FullCircle.Schema
  import Ecto.Changeset

  schema "bank_payment_batches" do
    belongs_to :company, FullCircle.Sys.Company
    belongs_to :profile, FullCircle.BankPayment.Profile
    belongs_to :format, FullCircle.BankPayment.FileFormat
    field :spec, :map
    field :payment_date, :date
    field :filename_stem, :string
    field :filename, :string
    field :seq, :integer
    field :header, :map
    field :count, :integer
    field :total, :decimal
    field :status, :string, default: "exported"
    belongs_to :submitted_by, FullCircle.UserAccounts.User
    field :submitted_at, :utc_datetime
    field :result_imported_at, :utc_datetime
    field :result_filename, :string
    field :void_reason, :string
    belongs_to :voided_by, FullCircle.UserAccounts.User
    field :voided_at, :utc_datetime
    belongs_to :created_by, FullCircle.UserAccounts.User
    has_many :lines, FullCircle.BankPayment.BatchLine
    timestamps(type: :utc_datetime)
  end

  @fields [
    :company_id,
    :profile_id,
    :format_id,
    :spec,
    :payment_date,
    :filename_stem,
    :filename,
    :seq,
    :header,
    :count,
    :total,
    :created_by_id
  ]

  def changeset(batch, attrs) do
    batch
    |> cast(attrs, @fields)
    |> validate_required(@fields)
    |> unique_constraint(:filename, name: :bank_payment_batches_company_id_filename_index)
  end

  def submit_changeset(batch, attrs) do
    batch
    |> cast(attrs, [:submitted_by_id, :submitted_at])
    |> validate_required([:submitted_by_id, :submitted_at])
    |> put_change(:status, "submitted")
  end

  def result_changeset(batch, attrs) do
    cs =
      cast(batch, attrs, [:result_imported_at, :result_filename, :submitted_at, :submitted_by_id])

    if batch.status == "exported", do: put_change(cs, :status, "submitted"), else: cs
  end

  def void_changeset(batch, attrs) do
    batch
    |> cast(attrs, [:void_reason, :voided_by_id, :voided_at])
    |> validate_required([:void_reason, :voided_by_id, :voided_at])
    |> put_change(:status, "voided")
  end

  def status_changeset(batch, status), do: change(batch, status: status)
end
