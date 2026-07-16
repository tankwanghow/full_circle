defmodule FullCircle.Trading.Location do
  use FullCircle.Schema
  import Ecto.Changeset
  use Gettext, backend: FullCircleWeb.Gettext

  @kinds ~w(port supplier_site customer_site own_warehouse other)

  schema "trading_locations" do
    field :name, :string
    field :kind, :string
    field :address_note, :string
    field :active, :boolean, default: true

    belongs_to :company, FullCircle.Sys.Company
    belongs_to :contact, FullCircle.Accounting.Contact

    timestamps(type: :utc_datetime)
  end

  def kinds, do: @kinds

  def changeset(location, attrs) do
    location
    |> cast(attrs, [:name, :kind, :address_note, :active, :company_id, :contact_id])
    |> validate_required([:name, :kind, :company_id])
    |> validate_inclusion(:kind, @kinds)
    |> foreign_key_constraint(:company_id)
    |> foreign_key_constraint(:contact_id)
  end
end
