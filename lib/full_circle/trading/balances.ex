defmodule FullCircle.Trading.Balances do
  @moduledoc """
  Qty balances for supply/sales positions and own-warehouse locations.

  Loaded / delivered / on-hand only count **completed** trips.
  Soft holds sum undelivered qty on active sales (draft/open/hold) with a preferred
  supply — they do **not** lock remaining.

  **In transit** (draft + planned trips) uses `coalesce(actual_mt, planned_mt)` so
  desks can show goods already committed on open trips without moving physical stock.
  """

  import Ecto.Query, warn: false

  alias FullCircle.Repo
  alias FullCircle.Trading.{SupplyPosition, SalesPosition, Trip, TripLoad, TripDrop, Location}

  @zero Decimal.new(0)
  # Not yet completed — goods may be on the road
  @open_trip_statuses ~w(draft planned)

  def open_trip_statuses, do: @open_trip_statuses

  def supply_loaded(%SupplyPosition{id: id}), do: supply_loaded(id)

  def supply_loaded(supply_id) when is_binary(supply_id) do
    from(l in TripLoad,
      join: t in Trip,
      on: t.id == l.trip_id,
      where: t.status == "completed" and l.supply_position_id == ^supply_id,
      select: coalesce(sum(l.actual_mt), 0)
    )
    |> Repo.one()
    |> to_decimal()
  end

  def supply_loaded(_), do: @zero

  def supply_remaining(%SupplyPosition{} = s) do
    qty = s.quantity || @zero
    Decimal.sub(qty, supply_loaded(s))
  end

  def sales_delivered(%SalesPosition{id: id}), do: sales_delivered(id)

  def sales_delivered(sales_id) when is_binary(sales_id) do
    from(d in TripDrop,
      join: t in Trip,
      on: t.id == d.trip_id,
      where: t.status == "completed" and d.sales_position_id == ^sales_id,
      select: coalesce(sum(d.actual_mt), 0)
    )
    |> Repo.one()
    |> to_decimal()
  end

  def sales_delivered(_), do: @zero

  def sales_undelivered(%SalesPosition{} = s) do
    qty = s.quantity || @zero
    Decimal.sub(qty, sales_delivered(s))
  end

  def sales_undelivered(%{quantity: qty, id: id}) when not is_nil(qty) do
    Decimal.sub(qty, sales_delivered(id))
  end

  def sales_undelivered(%{quantity: qty}) when not is_nil(qty) do
    Decimal.sub(qty, @zero)
  end

  def sales_undelivered(_), do: @zero

  @doc """
  MT loaded on draft/planned trips for this supply (not yet completed).
  """
  def supply_in_transit(%SupplyPosition{id: id}), do: supply_in_transit(id)

  def supply_in_transit(supply_id) when is_binary(supply_id) do
    from(l in TripLoad,
      join: t in Trip,
      on: t.id == l.trip_id,
      where: t.status in ^@open_trip_statuses and l.supply_position_id == ^supply_id,
      select: coalesce(sum(fragment("coalesce(?, ?)", l.actual_mt, l.planned_mt)), 0)
    )
    |> Repo.one()
    |> to_decimal()
  end

  def supply_in_transit(_), do: @zero

  @doc """
  MT on draft/planned trip drops targeting this sales position.
  """
  def sales_in_transit(%SalesPosition{id: id}), do: sales_in_transit(id)

  def sales_in_transit(sales_id) when is_binary(sales_id) do
    from(d in TripDrop,
      join: t in Trip,
      on: t.id == d.trip_id,
      where: t.status in ^@open_trip_statuses and d.sales_position_id == ^sales_id,
      select: coalesce(sum(fragment("coalesce(?, ?)", d.actual_mt, d.planned_mt)), 0)
    )
    |> Repo.one()
    |> to_decimal()
  end

  def sales_in_transit(_), do: @zero

  @doc """
  Soft hold against a supply: sum of undelivered qty on active sales
  (draft/open/hold) that name this supply as preferred.
  Does **not** reduce supply remaining.
  """
  def soft_held_for_supply(supply_id) when is_binary(supply_id) do
    active = FullCircle.Trading.SalesPosition.active_statuses()

    from(s in SalesPosition,
      where: s.preferred_supply_id == ^supply_id and s.status in ^active
    )
    |> Repo.all()
    |> Enum.reduce(@zero, fn sales, acc ->
      Decimal.add(acc, sales_undelivered(sales))
    end)
  end

  def soft_held_for_supply(_), do: @zero

  @doc """
  Own-warehouse stock: completed drops into the location minus completed loads out.
  Only meaningful for locations with kind `own_warehouse`.
  """
  def own_warehouse_qty(%Location{id: id, kind: "own_warehouse"}), do: own_warehouse_qty(id)
  def own_warehouse_qty(%Location{}), do: @zero

  def own_warehouse_qty(location_id) when is_binary(location_id) do
    Decimal.sub(own_warehouse_inbound(location_id), own_warehouse_outbound(location_id))
  end

  def own_warehouse_qty(_), do: @zero

  def own_warehouse_inbound(location_id) when is_binary(location_id) do
    from(d in TripDrop,
      join: t in Trip,
      on: t.id == d.trip_id,
      where: t.status == "completed" and d.location_id == ^location_id,
      select: coalesce(sum(d.actual_mt), 0)
    )
    |> Repo.one()
    |> to_decimal()
  end

  def own_warehouse_inbound(_), do: @zero

  def own_warehouse_outbound(location_id) when is_binary(location_id) do
    from(l in TripLoad,
      join: t in Trip,
      on: t.id == l.trip_id,
      where: t.status == "completed" and l.location_id == ^location_id,
      select: coalesce(sum(l.actual_mt), 0)
    )
    |> Repo.one()
    |> to_decimal()
  end

  def own_warehouse_outbound(_), do: @zero

  @doc """
  Completed drop-in qty at a location, grouped by trip good_id.
  Returns `%{good_id => Decimal}`.
  """
  def own_warehouse_inbound_by_good(location_id) when is_binary(location_id) do
    from(d in TripDrop,
      join: t in Trip,
      on: t.id == d.trip_id,
      where: t.status == "completed" and d.location_id == ^location_id,
      group_by: d.good_id,
      select: {d.good_id, coalesce(sum(d.actual_mt), 0)}
    )
    |> Repo.all()
    |> Map.new(fn {id, qty} -> {id, to_decimal(qty)} end)
  end

  def own_warehouse_inbound_by_good(_), do: %{}

  @doc """
  Completed load-out qty at a location, grouped by load good_id.
  Returns `%{good_id => Decimal}`.
  """
  def own_warehouse_outbound_by_good(location_id) when is_binary(location_id) do
    from(l in TripLoad,
      join: t in Trip,
      on: t.id == l.trip_id,
      where: t.status == "completed" and l.location_id == ^location_id,
      group_by: l.good_id,
      select: {l.good_id, coalesce(sum(l.actual_mt), 0)}
    )
    |> Repo.all()
    |> Map.new(fn {id, qty} -> {id, to_decimal(qty)} end)
  end

  def own_warehouse_outbound_by_good(_), do: %{}

  @doc """
  Draft/planned drops into a location, grouped by drop good_id (incoming / in transit in).
  Returns `%{good_id => Decimal}`.
  """
  def own_warehouse_incoming_by_good(location_id) when is_binary(location_id) do
    from(d in TripDrop,
      join: t in Trip,
      on: t.id == d.trip_id,
      where: t.status in ^@open_trip_statuses and d.location_id == ^location_id,
      group_by: d.good_id,
      select: {d.good_id, coalesce(sum(fragment("coalesce(?, ?)", d.actual_mt, d.planned_mt)), 0)}
    )
    |> Repo.all()
    |> Map.new(fn {id, qty} -> {id, to_decimal(qty)} end)
  end

  def own_warehouse_incoming_by_good(_), do: %{}

  @doc """
  Draft/planned loads out of a location, grouped by load good_id (outgoing / in transit out).
  Returns `%{good_id => Decimal}`.
  """
  def own_warehouse_outgoing_by_good(location_id) when is_binary(location_id) do
    from(l in TripLoad,
      join: t in Trip,
      on: t.id == l.trip_id,
      where: t.status in ^@open_trip_statuses and l.location_id == ^location_id,
      group_by: l.good_id,
      select: {l.good_id, coalesce(sum(fragment("coalesce(?, ?)", l.actual_mt, l.planned_mt)), 0)}
    )
    |> Repo.all()
    |> Map.new(fn {id, qty} -> {id, to_decimal(qty)} end)
  end

  def own_warehouse_outgoing_by_good(_), do: %{}

  defp to_decimal(%Decimal{} = d), do: d
  defp to_decimal(n) when is_integer(n), do: Decimal.new(n)
  defp to_decimal(n) when is_float(n), do: Decimal.from_float(n)
  defp to_decimal(nil), do: @zero
  defp to_decimal(other), do: Decimal.new("#{other}")
end
