defmodule FullCircle.Trading.BoardAggregationTest do
  @moduledoc """
  `position_board` / `sales_board` compute their totals with GROUP BY queries over
  the whole row set. These tests pin both halves of that contract: the aggregated
  numbers must equal the per-position functions, and the query count must not grow
  with the number of rows.
  """
  use FullCircle.DataCase, async: false

  alias FullCircle.Trading
  alias FullCircle.Trading.Balances

  import FullCircle.TradingFixtures
  import FullCircle.BillingFixtures

  setup do
    trading_setup()
  end

  defp count_queries(fun) do
    ref = make_ref()
    parent = self()
    handler = "board-agg-#{inspect(ref)}"

    :telemetry.attach(
      handler,
      [:full_circle, :repo, :query],
      fn _event, _measure, _meta, _cfg -> send(parent, {:query, ref}) end,
      nil
    )

    result = fun.()
    :telemetry.detach(handler)
    {result, drain(ref, 0)}
  end

  defp drain(ref, n) do
    receive do
      {:query, ^ref} -> drain(ref, n + 1)
    after
      0 -> n
    end
  end

  # Supplies + sales with a mix of soft holds, completed trips and open trips, so
  # loaded / remaining / soft_held / in_transit are all non-zero somewhere.
  defp seed_board(company, admin, n) do
    good = good_fixture(company, admin)
    port = location_fixture(company, admin, %{"kind" => "port"})
    wh = location_fixture(company, admin, %{"kind" => "own_warehouse"})
    cust = contact_fixture(company, admin)

    supplies =
      for i <- 1..n do
        supply_position_fixture(company, admin, %{
          "good_id" => good.id,
          "quantity" => "#{100 + i}",
          "status" => "open"
        })
      end

    # Keep the sales this batch created — a later batch uses a different good,
    # and pairing a drop with a mismatched sales position fails validation.
    sales_rows =
      for {s, i} <- Enum.with_index(supplies) do
        sales_position_fixture(company, admin, %{
          "good_id" => good.id,
          "customer_id" => cust.id,
          "quantity" => "#{10 + i}",
          "status" => "open",
          # every other sale soft-holds its supply
          "preferred_supply_id" => if(rem(i, 2) == 0, do: s.id, else: nil)
        })
      end

    for {s, i} <- Enum.with_index(supplies), i < div(n, 2) do
      sale = Enum.at(sales_rows, i)

      {:ok, t} =
        Trading.create_trip(
          %{
            "date" => "2026-07-07",
            "transport_mode" => "company_own",
            "vehicle_number" => "AGG#{i}",
            "loads" => [
              %{
                "planned" => "5",
                "actual" => "5",
                "good_id" => good.id,
                "location_id" => port.id,
                "supply_position_id" => s.id
              }
            ],
            "drops" => [
              %{
                "planned" => "5",
                "actual" => "5",
                "good_id" => good.id,
                "location_id" => wh.id,
                "sales_position_id" => sale && sale.id
              }
            ]
          },
          company,
          admin
        )

      # Complete half of them; the rest stay draft so they count as in-transit
      if rem(i, 2) == 0, do: {:ok, _, _} = Trading.complete_trip(t, company, admin)
    end
  end

  test "aggregated board values equal the per-position functions", %{
    admin: admin,
    company: company
  } do
    seed_board(company, admin, 8)

    for row <- Trading.position_board(company, admin) do
      s = row.supply
      assert Decimal.eq?(row.loaded, Balances.supply_loaded(s)), "loaded #{s.title}"
      assert Decimal.eq?(row.remaining, Balances.supply_remaining(s)), "remaining #{s.title}"

      assert Decimal.eq?(row.soft_held, Balances.soft_held_for_supply(s.id)),
             "soft_held #{s.title}"

      assert Decimal.eq?(row.in_transit, Balances.supply_in_transit(s)), "in_transit #{s.title}"
    end

    for row <- Trading.sales_board(company, admin) do
      s = row.sales
      assert Decimal.eq?(row.delivered, Balances.sales_delivered(s)), "delivered #{s.title}"

      assert Decimal.eq?(row.undelivered, Balances.sales_undelivered(s)),
             "undelivered #{s.title}"

      assert Decimal.eq?(row.in_transit, Balances.sales_in_transit(s)), "in_transit #{s.title}"
    end
  end

  test "board query count does not grow with row count", %{admin: admin, company: company} do
    seed_board(company, admin, 4)
    {small_board, small_q} = count_queries(fn -> Trading.position_board(company, admin) end)
    {small_sales, small_sq} = count_queries(fn -> Trading.sales_board(company, admin) end)

    seed_board(company, admin, 20)
    {big_board, big_q} = count_queries(fn -> Trading.position_board(company, admin) end)
    {big_sales, big_sq} = count_queries(fn -> Trading.sales_board(company, admin) end)

    # Row counts really did grow
    assert length(big_board) > length(small_board)
    assert length(big_sales) > length(small_sales)

    # ...but the query counts did not (this is the N+1 regression guard)
    assert big_q == small_q, "position_board went #{small_q} -> #{big_q} queries"
    assert big_sq == small_sq, "sales_board went #{small_sq} -> #{big_sq} queries"
  end
end
