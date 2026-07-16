defmodule FullCircle.Trading.SupplyPosition do
  use FullCircle.Schema
  import Ecto.Changeset

  @statuses ~w(open closed)

  schema "trading_supply_positions" do
    field :title, :string
    field :reference_no, :string
    field :vessel_name, :string
    field :period, :string
    field :quantity, :decimal
    field :unit, :string
    field :unit_price, :decimal
    field :status, :string, default: "open"
    field :notes, :string

    field :supplier_name, :string, virtual: true
    field :good_name, :string, virtual: true

    belongs_to :company, FullCircle.Sys.Company
    belongs_to :supplier, FullCircle.Accounting.Contact
    belongs_to :good, FullCircle.Product.Good

    timestamps(type: :utc_datetime)
  end

  def statuses, do: @statuses

  def changeset(position, attrs) do
    position
    |> cast(attrs, [
      :title,
      :reference_no,
      :vessel_name,
      :period,
      :quantity,
      :unit,
      :unit_price,
      :status,
      :notes,
      :company_id,
      :supplier_id,
      :good_id,
      :supplier_name,
      :good_name
    ])
    |> validate_required([:quantity, :company_id, :supplier_id, :good_id, :status])
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:quantity, greater_than: 0)
    |> foreign_key_constraint(:company_id)
    |> foreign_key_constraint(:supplier_id)
    |> foreign_key_constraint(:good_id)
  end
end

