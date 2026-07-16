defmodule FullCircle.Trading.Location do
  use FullCircle.Schema
  import Ecto.Changeset
  use Gettext, backend: FullCircleWeb.Gettext

  @kinds ~w(port supplier_site customer_site own_warehouse other)

  schema "trading_locations" do
    field :name, :string
    field :kind, :string
    field :address_note, :string
    # Optional GPS coordinates (WGS84). Google Maps link is derived, not stored.
    field :latitude, :decimal
    field :longitude, :decimal
    field :active, :boolean, default: true

    belongs_to :company, FullCircle.Sys.Company
    belongs_to :contact, FullCircle.Accounting.Contact

    timestamps(type: :utc_datetime)
  end

  def kinds, do: @kinds

  def changeset(location, attrs) do
    location
    |> cast(attrs, [
      :name,
      :kind,
      :address_note,
      :latitude,
      :longitude,
      :active,
      :company_id,
      :contact_id
    ])
    |> validate_required([:name, :kind, :company_id])
    |> validate_inclusion(:kind, @kinds)
    |> validate_number(:latitude, greater_than_or_equal_to: -90, less_than_or_equal_to: 90)
    |> validate_number(:longitude, greater_than_or_equal_to: -180, less_than_or_equal_to: 180)
    |> validate_gps_pair()
    |> foreign_key_constraint(:company_id)
    |> foreign_key_constraint(:contact_id)
  end

  @doc """
  Google Maps URL for this GPS point, or nil if coordinates are incomplete.
  """
  def google_maps_url(%__MODULE__{} = loc), do: google_maps_url(loc.latitude, loc.longitude)

  def google_maps_url(lat, lng)
      when not is_nil(lat) and not is_nil(lng) do
    "https://www.google.com/maps?q=#{Decimal.to_string(to_decimal(lat))},#{Decimal.to_string(to_decimal(lng))}"
  end

  def google_maps_url(_, _), do: nil

  @doc """
  Human-readable "lat, lng" for display, or nil.
  """
  def gps_label(%__MODULE__{} = loc), do: gps_label(loc.latitude, loc.longitude)

  def gps_label(lat, lng) when not is_nil(lat) and not is_nil(lng) do
    "#{Decimal.to_string(to_decimal(lat))}, #{Decimal.to_string(to_decimal(lng))}"
  end

  def gps_label(_, _), do: nil

  defp validate_gps_pair(changeset) do
    lat = get_field(changeset, :latitude)
    lng = get_field(changeset, :longitude)

    cond do
      is_nil(lat) and is_nil(lng) ->
        changeset

      not is_nil(lat) and not is_nil(lng) ->
        changeset

      is_nil(lat) ->
        add_error(changeset, :latitude, "required when longitude is set")

      true ->
        add_error(changeset, :longitude, "required when latitude is set")
    end
  end

  defp to_decimal(%Decimal{} = d), do: d
  defp to_decimal(n) when is_float(n), do: Decimal.from_float(n)
  defp to_decimal(n) when is_integer(n), do: Decimal.new(n)
  defp to_decimal(n) when is_binary(n), do: Decimal.new(n)
end
