defmodule FullCircle.Product.GoodPriceHistory do
  use FullCircle.Schema
  import Ecto.Changeset

  schema "good_price_histories" do
    field(:side, :string)
    field(:doc_date, :date)
    field(:unit_price, :decimal)
    field(:quantity, :decimal)
    field(:discount, :decimal)
    field(:unit, :string)
    field(:good_name, :string)
    field(:source, :string)
    field(:source_doc_id, :integer)
    field(:source_line_id, :integer)

    belongs_to(:company, FullCircle.Sys.Company)
    belongs_to(:good, FullCircle.Product.Good)

    timestamps(type: :utc_datetime)
  end

  @sides ~w(sale purchase)
  @sources ~w(invoice cash_sale pur_invoice)

  def changeset(history, attrs) do
    history
    |> cast(attrs, [
      :company_id,
      :good_id,
      :side,
      :doc_date,
      :unit_price,
      :quantity,
      :discount,
      :unit,
      :good_name,
      :source,
      :source_doc_id,
      :source_line_id
    ])
    |> validate_required([
      :company_id,
      :good_id,
      :side,
      :doc_date,
      :unit_price,
      :quantity,
      :source
    ])
    |> validate_inclusion(:side, @sides)
    |> validate_inclusion(:source, @sources)
    |> foreign_key_constraint(:company_id)
    |> foreign_key_constraint(:good_id)
  end
end
