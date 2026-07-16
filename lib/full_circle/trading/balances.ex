defmodule FullCircle.Trading.Balances do
  @moduledoc """
  Qty balances for supply/sales positions and own-warehouse locations.

  Loaded / delivered only count **completed** trips.
  Soft holds sum undelivered qty on active sales (draft/open/hold) with a preferred
  supply — they do **not** reduce supply remaining.
  """

  import Ecto.Query, warn: false

  alias FullCircle.Repo
  alias FullCircle.Trading.{SupplyPosition, SalesPosition, Trip, TripLoad, TripDrop, Location}

  @zero Decimal.new(0)

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
    inbound =
      from(d in TripDrop,
        join: t in Trip,
        on: t.id == d.trip_id,
        where: t.status == "completed" and d.location_id == ^location_id,
        select: coalesce(sum(d.actual_mt), 0)
      )
      |> Repo.one()
      |> to_decimal()

    outbound =
      from(l in TripLoad,
        join: t in Trip,
        on: t.id == l.trip_id,
        where: t.status == "completed" and l.location_id == ^location_id,
        select: coalesce(sum(l.actual_mt), 0)
      )
      |> Repo.one()
      |> to_decimal()

    Decimal.sub(inbound, outbound)
  end

  def own_warehouse_qty(_), do: @zero

  defp to_decimal(%Decimal{} = d), do: d
  defp to_decimal(n) when is_integer(n), do: Decimal.new(n)
  defp to_decimal(n) when is_float(n), do: Decimal.from_float(n)
  defp to_decimal(nil), do: @zero
  defp to_decimal(other), do: Decimal.new("#{other}")
end
