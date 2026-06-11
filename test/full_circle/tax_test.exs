defmodule FullCircle.TaxSchemaTest do
  use ExUnit.Case, async: true
  alias FullCircle.Tax.InstalmentPlan

  defp chg(attrs), do: InstalmentPlan.changeset(%InstalmentPlan{}, attrs)

  describe "changeset/2" do
    test "requires company_id and fy_year" do
      refute chg(%{}).valid?
      cs = chg(%{})
      assert %{company_id: _, fy_year: _} = Ecto.Changeset.traverse_errors(cs, & &1)
    end

    test "valid with the minimum fields" do
      cs = chg(%{company_id: Ecto.UUID.generate(), fy_year: 2026})
      assert cs.valid?
    end

    test "rejects negative tolerance and out-of-range estimate_month" do
      refute chg(%{company_id: Ecto.UUID.generate(), fy_year: 2026, tolerance_pct: -1}).valid?
      refute chg(%{company_id: Ecto.UUID.generate(), fy_year: 2026, estimate_month: 0}).valid?
      refute chg(%{company_id: Ecto.UUID.generate(), fy_year: 2026, estimate_month: 13}).valid?
    end

    test "accepts a paid_overrides map" do
      cs = chg(%{company_id: Ecto.UUID.generate(), fy_year: 2026, paid_overrides: %{"3" => "100.00"}})
      assert cs.valid?
      assert Ecto.Changeset.get_field(cs, :paid_overrides) == %{"3" => "100.00"}
    end
  end
end
