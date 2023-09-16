defmodule FullCircle.DebCre.CreditNoteDetail do
  use FullCircle.Schema
  import Ecto.Changeset
  import FullCircle.Helpers

  schema "credit_note_details" do
    field :descriptions, :string
    field :quantity, :decimal, default: 0
    field :unit_price, :decimal, default: 0
    field :tax_rate, :decimal, default: 0
    field :_persistent_id, :integer

    belongs_to :credit_note, FullCircle.DebCre.CreditNote
    belongs_to :account, FullCircle.Accounting.Account
    belongs_to :tax_code, FullCircle.Accounting.TaxCode

    field :account_name, :string, virtual: true
    field :tax_code_name, :string, virtual: true
    field :desc_amount, :decimal, virtual: true, default: 0
    field :tax_amount, :decimal, virtual: true, default: 0
    field :line_amount, :decimal, virtual: true, default: 0
    field :delete, :boolean, virtual: true, default: false
  end

  def changeset(invoice_details, attrs) do
    invoice_details
    |> cast(attrs, [
      :_persistent_id,
      :quantity,
      :unit_price,
      :descriptions,
      :account_name,
      :tax_code_name,
      :tax_rate,
      :account_id,
      :tax_code_id,
      :delete
    ])
    |> validate_required([
      :descriptions,
      :quantity,
      :unit_price,
      :tax_rate,
      :account_name,
      :tax_code_name
    ])
    |> validate_id(:tax_code_name, :tax_code_id)
    |> validate_id(:account_name, :account_id)
    |> validate_number(:quantity, greater_than: 0)
    |> compute_fields()
    |> maybe_mark_for_deletion()
  end

  defp compute_fields(changeset) do
    price = fetch_field!(changeset, :unit_price)
    rate = fetch_field!(changeset, :tax_rate)
    qty = fetch_field!(changeset, :quantity)

    desc_amount = Decimal.mult(qty, price) |> Decimal.round(2)
    tax_amount = Decimal.mult(desc_amount, rate) |> Decimal.round(2)
    line_amount = Decimal.add(desc_amount, tax_amount)

    changeset
    |> put_change(:tax_amount, tax_amount)
    |> put_change(:desc_amount, desc_amount)
    |> put_change(:line_amount, line_amount)
    |> put_change(:quantity, qty)
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
