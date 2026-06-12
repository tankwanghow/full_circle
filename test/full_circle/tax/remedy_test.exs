defmodule FullCircle.Tax.RemedyTest do
  use ExUnit.Case, async: true
  alias FullCircle.Tax.Remedy

  defp d(n), do: Decimal.new("#{n}")

  describe "estimate_position/3" do
    test ":under when estimate below floor and forecast above ceiling" do
      assert Remedy.estimate_position(d("6005257.3344"), d(3825000), d(30)) == :under
    end

    test ":over when forecast below estimate but not under" do
      assert Remedy.estimate_position(d(400000), d(500000), d(30)) == :over
    end

    test ":within when estimate near forecast" do
      assert Remedy.estimate_position(d(100000), d(90000), d(30)) == :within
    end
  end

  describe "penalty_analysis/4" do
    test "Kim Poh FY2025 under-estimation figures" do
      a =
        Remedy.penalty_analysis(
          d("6005257.3344"),
          d(3825000),
          d(30),
          d(24)
        )

      assert a.position == :under
      assert Decimal.equal?(a.penalty, d("103275.73"))
      assert Decimal.equal?(a.director_fee_needed, d("4303155.54"))
      assert Decimal.equal?(a.excess_tax, d("1032757.33"))
      assert Decimal.equal?(a.penalty_ceiling, d(4972500))
    end

    test "no penalty when within tolerance" do
      a = Remedy.penalty_analysis(d(130000), d(100000), d(30), d(24))
      assert a.position == :within
      assert Decimal.equal?(a.penalty, d(0))
    end
  end

  describe "under_remedy_comparison/5" do
    test "Kim Poh: 1 director — penalty is cheaper" do
      a = Remedy.penalty_analysis(d("6005257.3344"), d(3825000), d(30), d(24))
      c = Remedy.under_remedy_comparison(a, d(24), 1, d(0))

      assert c.recommendation == :pay_penalty
      assert Decimal.compare(c.delta, d(0)) == :gt
      assert Decimal.equal?(c.pay_penalty.total, d("6108533.06"))
    end

    test "3 directors — director fee can be cheaper" do
      a = Remedy.penalty_analysis(d("6005257.3344"), d(3825000), d(30), d(24))
      c = Remedy.under_remedy_comparison(a, d(24), 3, d(0))
      assert c.recommendation == :director_fee
    end

    test "existing income raises personal tax" do
      a = Remedy.penalty_analysis(d("6005257.3344"), d(3825000), d(30), d(24))
      c0 = Remedy.under_remedy_comparison(a, d(24), 1, d(0))
      c1 = Remedy.under_remedy_comparison(a, d(24), 1, d(360000))
      assert Decimal.compare(c1.director_fee.personal_tax, c0.director_fee.personal_tax) == :gt
    end
  end

  describe "over_analysis/4" do
    test "computes overpayment and expected refund" do
      a = Remedy.over_analysis(d(400000), d(500000), d(30), d(480000))

      assert a.position == :over
      assert Decimal.equal?(a.overpayment_tax, d(100000))
      assert Decimal.equal?(a.expected_refund, d(80000))
      assert Decimal.equal?(a.suggested_revised_estimate, d("307692.31"))
    end

    test "headroom_tax before crossing into penalty zone" do
      a = Remedy.over_analysis(d(400000), d(500000), d(30), d(500000))
      assert Decimal.equal?(a.headroom_tax, d(250000))
    end
  end

  describe "over_remedy_comparison/1" do
    test "suggests revising the estimate down" do
      a = Remedy.over_analysis(d(400000), d(500000), d(30), d(500000))
      c = Remedy.over_remedy_comparison(a)

      assert c.recommendation == :revise_estimate
      assert Decimal.equal?(c.revised_estimate, d("307692.31"))
      assert Decimal.equal?(c.overpayment_tax, d(100000))
      assert Decimal.equal?(c.expected_refund, d(100000))
    end
  end
end