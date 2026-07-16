defmodule FullCircle.Trading.Balances do
  @moduledoc """
  Qty balances for supply/sales positions.

  Until Trip tables exist, loaded/delivered are always 0.
  Task 6 will query completed trip load/drop actuals.
  """

  alias FullCircle.Trading.SupplyPosition

  @zero Decimal.new(0)

  def supply_loaded(%SupplyPosition{}), do: @zero
  def supply_loaded(_id), do: @zero

  def supply_remaining(%SupplyPosition{} = s) do
    qty = s.quantity || @zero
    Decimal.sub(qty, supply_loaded(s))
  end

  def soft_held_for_supply(_supply_id), do: @zero

  def sales_delivered(_sales_position_id), do: @zero

  def sales_undelivered(%{quantity: qty}) when not is_nil(qty) do
    Decimal.sub(qty, @zero)
  end

  def sales_undelivered(_), do: @zero
end
