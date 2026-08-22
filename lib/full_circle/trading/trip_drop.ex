defmodule FullCircle.Trading.TripDrop do
  use FullCircle.Schema
  import Ecto.Changeset

  schema "trading_trip_drops" do
    field :planned, :decimal
    field :actual, :decimal
    field :location_note, :string
    field :variance_note, :string
    # Delivery / unload order: 1 = first unload (often reverse of load order)
    field :seq, :integer, default: 0

    field :location_name, :string, virtual: true
    field :sales_title, :string, virtual: true
    field :supply_title, :string, virtual: true
    field :good_name, :string, virtual: true
    # Display only — qty fields use Good.unit
    field :good_unit, :string, virtual: true
    # Typeahead to add a worker to trip_drop_employees (cleared after add)
    field :crew_add_name, :string, virtual: true
    # true once user edits this line's crew — blocks fill-down from earlier lines
    field :crew_locked, :boolean, virtual: true, default: false
    # Customer contact for location typeahead filter (from sales)
    field :party_contact_id, :binary_id, virtual: true
    field :delete, :boolean, virtual: true, default: false

    belongs_to :trip, FullCircle.Trading.Trip
    belongs_to :good, FullCircle.Product.Good
    belongs_to :sales_position, FullCircle.Trading.SalesPosition
    belongs_to :supply_position, FullCircle.Trading.SupplyPosition
    belongs_to :location, FullCircle.Trading.Location
    belongs_to :invoice, FullCircle.Billing.Invoice
    # Phase C: transport agent PurInvoice matched to this haul line (drop + origin)
    belongs_to :transport_pur_invoice, FullCircle.Billing.PurInvoice

    # Admin settlement waivers (set via Settlement.exempt_settlement_lines only,
    # never cast from forms). nil exempt_at = not waived. Two sets because a
    # drop carries two billable streams: customer invoice and transport bill.
    field :invoice_exempt_at, :utc_datetime
    field :invoice_exempt_reason, :string
    belongs_to :invoice_exempt_by, FullCircle.UserAccounts.User

    field :transport_exempt_at, :utc_datetime
    field :transport_exempt_reason, :string
    belongs_to :transport_exempt_by, FullCircle.UserAccounts.User

    has_many :trip_drop_employees, FullCircle.Trading.TripDropEmployee,
      on_replace: :delete,
      on_delete: :delete_all

    has_many :employees, through: [:trip_drop_employees, :employee]

    timestamps(type: :utc_datetime)
  end

  def changeset(drop, attrs) do
    drop
    |> cast(
      blank_to_nil(attrs, [
        "sales_position_id",
        "supply_position_id",
        "location_id",
        "invoice_id",
        "transport_pur_invoice_id",
        "good_id",
        "party_contact_id"
      ]),
      [
        :planned,
        :actual,
        :location_note,
        :variance_note,
        :seq,
        :trip_id,
        :good_id,
        :sales_position_id,
        :supply_position_id,
        :location_id,
        :invoice_id,
        :transport_pur_invoice_id,
        :location_name,
        :sales_title,
        :supply_title,
        :good_name,
        :good_unit,
        :crew_add_name,
        :crew_locked,
        :party_contact_id,
        :delete
      ]
    )
    |> cast_assoc(:trip_drop_employees, with: &FullCircle.Trading.TripDropEmployee.changeset/2)
    |> validate_required([:location_id, :good_id])
    |> validate_number(:planned, greater_than_or_equal_to: 0)
    |> validate_number(:actual, greater_than_or_equal_to: 0)
    |> foreign_key_constraint(:trip_id)
    |> foreign_key_constraint(:good_id)
    |> foreign_key_constraint(:sales_position_id)
    |> foreign_key_constraint(:supply_position_id)
    |> foreign_key_constraint(:location_id)
    |> foreign_key_constraint(:invoice_id)
    |> foreign_key_constraint(:transport_pur_invoice_id)
    |> maybe_mark_for_deletion()
  end

  defp blank_to_nil(attrs, keys) when is_map(attrs) do
    Enum.reduce(keys, attrs, fn key, acc ->
      atom = String.to_atom(key)

      cond do
        Map.has_key?(acc, key) and acc[key] in ["", nil] -> Map.put(acc, key, nil)
        Map.has_key?(acc, atom) and acc[atom] in ["", nil] -> Map.put(acc, atom, nil)
        true -> acc
      end
    end)
  end

  defp maybe_mark_for_deletion(%{data: %{id: nil}} = cs), do: cs

  defp maybe_mark_for_deletion(cs) do
    if get_change(cs, :delete) do
      %{cs | action: :delete}
    else
      cs
    end
  end
end
