defmodule FullCircle.Trading.Balances do
  @moduledoc """
  Qty balances for supply/sales positions.

  Until Trip tables exist, loaded/delivered are always 0.
  Task 6 will query completed trip load/drop actuals.
  Soft holds sum undelivered qty on draft/open sales with a preferred supply.
  """

  import Ecto.Query, warn: false

  alias FullCircle.Repo
  alias FullCircle.Trading.{SupplyPosition, SalesPosition}

  @zero Decimal.new(0)

  def supply_loaded(%SupplyPosition{}), do: @zero
  def supply_loaded(_id), do: @zero

  def supply_remaining(%SupplyPosition{} = s) do
    qty = s.quantity || @zero
    Decimal.sub(qty, supply_loaded(s))
  end

  def sales_delivered(%SalesPosition{}), do: @zero
  def sales_delivered(_id), do: @zero

  def sales_undelivered(%SalesPosition{} = s) do
    qty = s.quantity || @zero
    Decimal.sub(qty, sales_delivered(s))
  end

  def sales_undelivered(%{quantity: qty}) when not is_nil(qty) do
    Decimal.sub(qty, @zero)
  end

  def sales_undelivered(_), do: @zero

  @doc """
  Soft hold against a supply: sum of undelivered qty on draft/open sales
  that name this supply as preferred. Does **not** reduce supply remaining.
  """
  def soft_held_for_supply(supply_id) when is_binary(supply_id) do
    # Until trips exist, undelivered == quantity for every sales position.
    from(s in SalesPosition,
      where: s.preferred_supply_id == ^supply_id and s.status in ["draft", "open"],
      select: coalesce(sum(s.quantity), 0)
    )
    |> Repo.one()
    |> to_decimal()
  end

  def soft_held_for_supply(_), do: @zero

  defp to_decimal(%Decimal{} = d), do: d
  defp to_decimal(n) when is_integer(n), do: Decimal.new(n)
  defp to_decimal(n) when is_float(n), do: Decimal.from_float(n)
  defp to_decimal(nil), do: @zero
  defp to_decimal(other), do: Decimal.new("#{other}")
end
