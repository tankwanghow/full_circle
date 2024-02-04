defmodule FullCircle.DebCre.CreditNote do
  use FullCircle.Schema
  import Ecto.Changeset
  import FullCircle.Helpers
  import FullCircleWeb.Gettext

  schema "credit_notes" do
    field :note_no, :string
    field :note_date, :date

    belongs_to :company, FullCircle.Sys.Company
    belongs_to :contact, FullCircle.Accounting.Contact

    has_many :credit_note_details, FullCircle.DebCre.CreditNoteDetail, on_replace: :delete

    has_many :transaction_matchers, FullCircle.Accounting.TransactionMatcher,
      where: [doc_type: "CreditNote"],
      on_replace: :delete,
      foreign_key: :doc_id,
      references: :id

    field :contact_name, :string, virtual: true
    field :note_desc_amount, :decimal, virtual: true, default: 0
    field :note_amount, :decimal, virtual: true, default: 0
    field :note_tax_amount, :decimal, virtual: true, default: 0
    field :note_balance, :decimal, virtual: true, default: 0
    field :matched_amount, :decimal, virtual: true, default: 0
    field :sum_qty, :decimal, virtual: true, default: 0

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(note, attrs) do
    note
    |> cast(attrs, [
      :note_date,
      :company_id,
      :contact_id,
      :contact_name,
      :note_no
    ])
    |> fill_today(:note_date)
    |> validate_required([
      :note_date,
      :company_id,
      :contact_name,
      :note_no
    ])
    |> validate_date(:note_date, days_before: 60)
    |> validate_date(:note_date, days_after: 3)
    |> validate_id(:contact_name, :contact_id)
    |> unsafe_validate_unique([:note_no, :company_id], FullCircle.Repo,
      message: gettext("note no already in company")
    )
    |> cast_assoc(:credit_note_details)
    |> cast_assoc(:transaction_matchers)
    |> compute_balance()
  end

  def compute_balance(cs) do
    cs =
      cs
      |> compute_fields()
      |> compute_match_transactions_amount()

    pos = fetch_field!(cs, :note_amount)
    neg = fetch_field!(cs, :matched_amount)
    bal = Decimal.add(pos, neg)

    cs =
      cs
      |> cast(%{"note_balance" => bal}, [:note_balance])

    if(Decimal.eq?(neg, 0),
      do: cs,
      else: validate_number(cs, :note_balance, equal_to: Decimal.new("0.00"))
    )
  end

  def compute_match_transactions_amount(changeset) do
    changeset |> sum_field_to(:transaction_matchers, :match_amount, :matched_amount)
  end

  def compute_struct_fields(inval) do
    inval
    |> sum_struct_field_to(:transaction_matchers, :match_amount, :matched_amount)
    |> sum_struct_field_to(:credit_note_details, :desc_amount, :note_desc_amount)
    |> sum_struct_field_to(:credit_note_details, :tax_amount, :note_tax_amount)
    |> sum_struct_field_to(:credit_note_details, :line_amount, :note_amount)
  end

  def compute_fields(changeset) do
    changeset =
      changeset
      |> sum_field_to(:credit_note_details, :desc_amount, :note_desc_amount)
      |> sum_field_to(:credit_note_details, :tax_amount, :note_tax_amount)
      |> sum_field_to(:credit_note_details, :line_amount, :note_amount)
      |> sum_field_to(:credit_note_details, :quantity, :sum_qty)

    cond do
      Decimal.lt?(fetch_field!(changeset, :note_amount), 0) ->
        add_unique_error(changeset, :note_amount, gettext("must be +ve"))

      Decimal.eq?(fetch_field!(changeset, :sum_qty), 0) ->
        add_unique_error(changeset, :note_amount, gettext("need detail"))

      true ->
        changeset
    end
  end
end
