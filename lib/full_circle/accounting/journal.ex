defmodule FullCircle.Accounting.Journal do
  use FullCircle.Schema
  import Ecto.Changeset
  import FullCircle.Helpers
  use Gettext, backend: FullCircleWeb.Gettext

  schema "journals" do
    field(:journal_date, :date)
    field(:journal_no, :string)

    belongs_to :company, FullCircle.Sys.Company

    has_many :transactions, FullCircle.Accounting.Transaction,
      where: [doc_type: "Journal"],
      on_replace: :delete,
      foreign_key: :doc_id,
      references: :id

    field :journal_balance, :decimal, virtual: true, default: Decimal.new("0")
    field :transaction_count, :decimal, virtual: true, default: 0

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(journal, attrs) do
    journal
    |> cast(attrs, [
      :journal_no,
      :journal_date,
      :company_id
    ])
    |> fill_today(:journal_date)
    |> validate_required([
      :journal_no,
      :journal_date,
      :company_id
    ])
    |> cast_assoc(:transactions,
      with: &FullCircle.Accounting.Transaction.journal_entry_changeset/2
    )
    |> compute_balance()
  end

  def compute_struct_balance(inval) do
    inval
    |> sum_struct_field_to(:transactions, :amount, :journal_balance)
  end

  def compute_balance(changeset) do
    changeset =
      changeset
      |> sum_field_to(:transactions, :amount, :journal_balance)
      |> sum_field_to(:transactions, :count, :transaction_count)

    cond do
      Decimal.eq?(fetch_field!(changeset, :transaction_count), 0) ->
        add_unique_error(changeset, :journal_balance, gettext("need entries"))

      true ->
        changeset
    end
  end
end
