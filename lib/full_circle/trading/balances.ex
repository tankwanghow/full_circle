defmodule FullCircle.Trading.Balances do
  @moduledoc """
  Qty balances for supply/sales positions and own-warehouse locations.

  Loaded / delivered / on-hand only count **completed** trips.
  Soft holds sum undelivered qty on active sales (draft/open/hold) with a preferred
  supply — they do **not** lock remaining.

  **In transit** (draft + planned trips) uses `coalesce(actual, planned)` so
  desks can show goods already committed on open trips without moving physical stock.
  """

  import Ecto.Query, warn: false

  alias FullCircle.Repo
  alias FullCircle.Trading.{SupplyPosition, SalesPosition, Trip, TripLoad, TripDrop, Location}

  @zero Decimal.new(0)
  # Not yet completed — goods may be on the road
  @open_trip_statuses ~w(draft planned)

  def open_trip_statuses, do: @open_trip_statuses

  # --- Batch (board) variants -------------------------------------------------
  #
  # The per-position functions below each run their own query. Rendering a board
  # one row at a time therefore costs O(rows) round-trips. These `*_by_ids/1`
  # helpers answer the same questions for a whole id set in **one** GROUP BY
  # query and return `%{id => Decimal}` (missing id ⇒ absent, treat as zero).

  @doc "Completed loaded qty per supply id."
  def supply_loaded_by_ids(supply_ids) when is_list(supply_ids) do
    sum_by_ids(
      from(l in TripLoad,
        join: t in Trip,
        on: t.id == l.trip_id,
        where: t.status == "completed" and l.supply_position_id in ^supply_ids,
        group_by: l.supply_position_id,
        select: {l.supply_position_id, coalesce(sum(l.actual), 0)}
      ),
      supply_ids
    )
  end

  @doc "Draft/planned (in-transit) qty per supply id, using coalesce(actual, planned)."
  def supply_in_transit_by_ids(supply_ids) when is_list(supply_ids) do
    sum_by_ids(
      from(l in TripLoad,
        join: t in Trip,
        on: t.id == l.trip_id,
        where: t.status in ^@open_trip_statuses and l.supply_position_id in ^supply_ids,
        group_by: l.supply_position_id,
        select:
          {l.supply_position_id,
           coalesce(sum(fragment("coalesce(?, ?)", l.actual, l.planned)), 0)}
      ),
      supply_ids
    )
  end

  @doc "Completed delivered qty per sales id."
  def sales_delivered_by_ids(sales_ids) when is_list(sales_ids) do
    sum_by_ids(
      from(d in TripDrop,
        join: t in Trip,
        on: t.id == d.trip_id,
        where: t.status == "completed" and d.sales_position_id in ^sales_ids,
        group_by: d.sales_position_id,
        select: {d.sales_position_id, coalesce(sum(d.actual), 0)}
      ),
      sales_ids
    )
  end

  @doc "Draft/planned (in-transit) qty per sales id, using coalesce(actual, planned)."
  def sales_in_transit_by_ids(sales_ids) when is_list(sales_ids) do
    sum_by_ids(
      from(d in TripDrop,
        join: t in Trip,
        on: t.id == d.trip_id,
        where: t.status in ^@open_trip_statuses and d.sales_position_id in ^sales_ids,
        group_by: d.sales_position_id,
        select:
          {d.sales_position_id, coalesce(sum(fragment("coalesce(?, ?)", d.actual, d.planned)), 0)}
      ),
      sales_ids
    )
  end

  @doc """
  Soft hold per supply id: undelivered qty on active sales naming that supply as
  preferred. Two queries total (active sales, then their delivered totals) rather
  than one per sales row.
  """
  def soft_held_by_ids([]), do: %{}

  def soft_held_by_ids(supply_ids) when is_list(supply_ids) do
    active = SalesPosition.active_statuses()

    sales =
      from(s in SalesPosition,
        where: s.preferred_supply_id in ^supply_ids and s.status in ^active,
        select: {s.id, s.preferred_supply_id, s.quantity}
      )
      |> Repo.all()

    delivered = sales_delivered_by_ids(Enum.map(sales, fn {id, _sup, _q} -> id end))

    Enum.reduce(sales, %{}, fn {id, supply_id, qty}, acc ->
      undelivered = Decimal.sub(to_decimal(qty), Map.get(delivered, id, @zero))
      Map.update(acc, supply_id, undelivered, &Decimal.add(&1, undelivered))
    end)
  end

  defp sum_by_ids(_query, []), do: %{}

  defp sum_by_ids(query, _ids) do
    query
    |> Repo.all()
    |> Map.new(fn {id, total} -> {id, to_decimal(total)} end)
  end

  def supply_loaded(%SupplyPosition{id: id}), do: supply_loaded(id)

  def supply_loaded(supply_id) when is_binary(supply_id) do
    from(l in TripLoad,
      join: t in Trip,
      on: t.id == l.trip_id,
      where: t.status == "completed" and l.supply_position_id == ^supply_id,
      select: coalesce(sum(l.actual), 0)
    )
    |> Repo.one()
    |> to_decimal()
  end

  def supply_loaded(_), do: @zero

  def supply_remaining(%SupplyPosition{} = s), do: supply_remaining(s, supply_loaded(s))

  @doc """
  Remaining against an already-computed `loaded`. Use this when the caller has
  just called `supply_loaded/1` — the arity-1 form would re-run that query.
  """
  def supply_remaining(%SupplyPosition{} = s, loaded) do
    qty = s.quantity || @zero
    Decimal.sub(qty, to_decimal(loaded))
  end

  def sales_delivered(%SalesPosition{id: id}), do: sales_delivered(id)

  def sales_delivered(sales_id) when is_binary(sales_id) do
    from(d in TripDrop,
      join: t in Trip,
      on: t.id == d.trip_id,
      where: t.status == "completed" and d.sales_position_id == ^sales_id,
      select: coalesce(sum(d.actual), 0)
    )
    |> Repo.one()
    |> to_decimal()
  end

  def sales_delivered(_), do: @zero

  def sales_undelivered(%SalesPosition{} = s), do: sales_undelivered(s, sales_delivered(s))

  def sales_undelivered(%{quantity: qty, id: id} = s) when not is_nil(qty),
    do: sales_undelivered(s, sales_delivered(id))

  def sales_undelivered(%{quantity: qty}) when not is_nil(qty) do
    Decimal.sub(qty, @zero)
  end

  def sales_undelivered(_), do: @zero

  @doc """
  Undelivered against an already-computed `delivered`. Use this when the caller
  has just called `sales_delivered/1` — the arity-1 form would re-run that query.
  """
  def sales_undelivered(%{quantity: qty}, delivered) do
    Decimal.sub(qty || @zero, to_decimal(delivered))
  end

  @doc """
  MT loaded on draft/planned trips for this supply (not yet completed).
  """
  def supply_in_transit(%SupplyPosition{id: id}), do: supply_in_transit(id)

  def supply_in_transit(supply_id) when is_binary(supply_id) do
    from(l in TripLoad,
      join: t in Trip,
      on: t.id == l.trip_id,
      where: t.status in ^@open_trip_statuses and l.supply_position_id == ^supply_id,
      select: coalesce(sum(fragment("coalesce(?, ?)", l.actual, l.planned)), 0)
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
      select: coalesce(sum(fragment("coalesce(?, ?)", d.actual, d.planned)), 0)
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
      select: coalesce(sum(d.actual), 0)
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
      select: coalesce(sum(l.actual), 0)
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
      select: {d.good_id, coalesce(sum(d.actual), 0)}
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
      select: {l.good_id, coalesce(sum(l.actual), 0)}
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
      select: {d.good_id, coalesce(sum(fragment("coalesce(?, ?)", d.actual, d.planned)), 0)}
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
      select: {l.good_id, coalesce(sum(fragment("coalesce(?, ?)", l.actual, l.planned)), 0)}
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
