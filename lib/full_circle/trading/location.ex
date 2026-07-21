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
    # Form typeahead for linked supplier/customer contact (1 contact → many sites)
    field :contact_name, :string, virtual: true

    belongs_to :company, FullCircle.Sys.Company
    belongs_to :contact, FullCircle.Accounting.Contact

    timestamps(type: :utc_datetime)
  end

  def kinds, do: @kinds

  def changeset(location, attrs) do
    location
    |> cast(blank_to_nil(attrs, ["contact_id"]), [
      :name,
      :kind,
      :address_note,
      :latitude,
      :longitude,
      :active,
      :company_id,
      :contact_id,
      :contact_name
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

  def google_maps_url(lat, lng) do
    with {:ok, lat_d} <- parse_coord(lat),
         {:ok, lng_d} <- parse_coord(lng) do
      "https://www.google.com/maps?q=#{Decimal.to_string(lat_d)},#{Decimal.to_string(lng_d)}"
    else
      _ -> nil
    end
  end

  @doc """
  Human-readable "lat, lng" for display, or nil.
  """
  def gps_label(%__MODULE__{} = loc), do: gps_label(loc.latitude, loc.longitude)

  def gps_label(lat, lng) do
    with {:ok, lat_d} <- parse_coord(lat),
         {:ok, lng_d} <- parse_coord(lng) do
      "#{Decimal.to_string(lat_d)}, #{Decimal.to_string(lng_d)}"
    else
      _ -> nil
    end
  end

  defp parse_coord(nil), do: :error
  defp parse_coord(""), do: :error
  defp parse_coord(%Decimal{} = d), do: {:ok, d}

  defp parse_coord(n) when is_float(n), do: {:ok, Decimal.from_float(n)}
  defp parse_coord(n) when is_integer(n), do: {:ok, Decimal.new(n)}

  defp parse_coord(n) when is_binary(n) do
    case String.trim(n) do
      "" ->
        :error

      s ->
        case Decimal.parse(s) do
          {d, ""} -> {:ok, d}
          _ -> :error
        end
    end
  end

  defp parse_coord(_), do: :error

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
end
