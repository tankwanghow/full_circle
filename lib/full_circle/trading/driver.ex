defmodule FullCircle.Trading.Driver do
  use FullCircle.Schema
  import Ecto.Changeset

  schema "trading_drivers" do
    field :name, :string
    field :phone, :string
    field :active, :boolean, default: true

    belongs_to :company, FullCircle.Sys.Company
    belongs_to :contact, FullCircle.Accounting.Contact

    timestamps(type: :utc_datetime)
  end

  def changeset(driver, attrs) do
    driver
    |> cast(attrs, [:name, :phone, :active, :company_id, :contact_id])
    |> validate_required([:name, :company_id])
    |> foreign_key_constraint(:company_id)
    |> foreign_key_constraint(:contact_id)
  end
end
