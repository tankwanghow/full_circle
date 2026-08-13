defmodule FullCircle.PeriodLockTest do
  use FullCircle.DataCase

  alias FullCircle.Sys
  alias FullCircle.Sys.Company

  import FullCircle.SysFixtures
  import FullCircle.UserAccountsFixtures

  defp company_today(company) do
    case DateTime.now(company.timezone || "Etc/UTC") do
      {:ok, dt} -> DateTime.to_date(dt)
      _ -> Date.utc_today()
    end
  end

  describe "period cutoff storage" do
    setup do
      admin = user_fixture()
      company = company_fixture(admin, %{})
      %{admin: admin, company: company}
    end

    test "no cutoff by default", %{company: company} do
      assert Sys.period_closed_through(company) == nil
    end

    test "an admin can close a period", %{company: company, admin: admin} do
      assert {:ok, company} = Sys.close_period_through(company, ~D[2025-12-31], admin)
      assert Sys.period_closed_through(company) == ~D[2025-12-31]
    end

    test "a non-admin cannot close a period", %{company: company, admin: admin} do
      clerk = user_fixture()
      {:ok, _} = Sys.allow_user_to_access(company, clerk, "clerk", admin)

      assert :not_authorise = Sys.close_period_through(company, ~D[2025-12-31], clerk)
      assert Sys.period_closed_through(company) == nil
    end

    test "a future date is rejected", %{company: company, admin: admin} do
      future = Date.add(company_today(company), 1)
      assert {:error, :future_date} = Sys.close_period_through(company, future, admin)
      assert Sys.period_closed_through(company) == nil
    end

    test "nil clears the cutoff", %{company: company, admin: admin} do
      {:ok, company} = Sys.close_period_through(company, ~D[2025-12-31], admin)
      assert {:ok, company} = Sys.close_period_through(company, nil, admin)
      assert Sys.period_closed_through(company) == nil
    end

    test "closing and reopening are both logged", %{company: company, admin: admin} do
      {:ok, company} = Sys.close_period_through(company, ~D[2025-12-31], admin)
      {:ok, company} = Sys.close_period_through(company, ~D[2025-06-30], admin)

      logs =
        Repo.all(
          from l in FullCircle.Sys.Log,
            where: l.company_id == ^company.id and l.action == "close_period"
        )

      assert length(logs) == 2
      assert Enum.any?(logs, &(&1.delta =~ "2025-12-31"))
      assert Enum.any?(logs, &(&1.delta =~ "2025-06-30"))
    end

    test "a malformed stored value reads as no cutoff", %{company: company} do
      {:ok, _} = Sys.update_company_settings(company, "period", %{"closed_through" => "rubbish"})
      assert Sys.period_closed_through(company) == nil
    end

    test "reads the cutoff from the database, not the in-memory struct", %{
      company: company,
      admin: admin
    } do
      {:ok, _} = Sys.close_period_through(company, ~D[2025-12-31], admin)
      stale = %{company | settings: %{}}
      assert Sys.period_closed_through(stale) == ~D[2025-12-31]
    end
  end

  describe "assert_period_open/2" do
    setup do
      admin = user_fixture()
      company = company_fixture(admin, %{})
      {:ok, company} = Sys.close_period_through(company, ~D[2025-12-31], admin)
      %{admin: admin, company: company}
    end

    test "a date on the cutoff is closed", %{company: company} do
      assert {:error, :period_closed} =
               FullCircle.Accounting.assert_period_open([~D[2025-12-31]], company)
    end

    test "a date before the cutoff is closed", %{company: company} do
      assert {:error, :period_closed} =
               FullCircle.Accounting.assert_period_open([~D[2025-11-04]], company)
    end

    test "the day after the cutoff is open", %{company: company} do
      assert :ok = FullCircle.Accounting.assert_period_open([~D[2026-01-01]], company)
    end

    test "any closed date in the list closes the write", %{company: company} do
      assert {:error, :period_closed} =
               FullCircle.Accounting.assert_period_open([~D[2026-01-01], ~D[2025-11-04]], company)
    end

    test "nils are ignored", %{company: company} do
      assert :ok = FullCircle.Accounting.assert_period_open([nil], company)
      assert :ok = FullCircle.Accounting.assert_period_open([], company)
    end

    test "no cutoff means everything is open", %{admin: admin} do
      open_company = company_fixture(admin, %{})
      assert :ok = FullCircle.Accounting.assert_period_open([~D[2019-01-01]], open_company)
    end
  end

  describe "map_period_closed/1" do
    test "collapses the Multi 4-tuple" do
      assert {:error, :period_closed} =
               FullCircle.Accounting.map_period_closed(
                 {:error, :assert_period_open, :period_closed, %{}}
               )
    end

    test "passes other results through" do
      assert {:ok, :x} = FullCircle.Accounting.map_period_closed({:ok, :x})
      assert :not_authorise = FullCircle.Accounting.map_period_closed(:not_authorise)
    end
  end
end
