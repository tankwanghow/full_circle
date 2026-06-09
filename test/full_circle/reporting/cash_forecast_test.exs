defmodule FullCircle.Reporting.CashForecastTest do
  use ExUnit.Case, async: true
  alias FullCircle.Reporting.CashForecast

  defp d(n), do: Decimal.new("#{n}")

  describe "build_forecast/3 roll-forward" do
    test "buckets events into weeks and rolls balance forward" do
      start = ~D[2026-06-08]  # a Monday

      events = [
        %{date: ~D[2026-06-10], in: d(1000), out: d(0), kind: :known},   # week 1
        %{date: ~D[2026-06-12], in: d(0), out: d(400), kind: :known},    # week 1
        %{date: ~D[2026-06-16], in: d(0), out: d(700), kind: :known}     # week 2
      ]

      res =
        CashForecast.build_forecast(
          %{opening: d(5000), baseline_in: d(0), baseline_out: d(0), events: events},
          start,
          weeks_count: 13, buffer_weeks: 2
        )

      [w1, w2 | _] = res.weeks
      assert w1.opening == d(5000)
      assert w1.known_in == d(1000)
      assert w1.known_out == d(400)
      assert w1.closing == d(5600)            # 5000 + 1000 - 400
      assert w2.opening == d(5600)
      assert w2.known_out == d(700)
      assert w2.closing == d(4900)            # 5600 - 700
      assert length(res.weeks) == 13
    end
  end
end
