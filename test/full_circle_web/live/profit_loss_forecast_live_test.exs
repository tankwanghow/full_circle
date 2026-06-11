defmodule FullCircleWeb.ProfitLossForecastLiveTest do
  use FullCircleWeb.ConnCase

  import Phoenix.LiveViewTest
  import FullCircle.SysFixtures
  import FullCircle.UserAccountsFixtures

  setup %{conn: conn} do
    user = user_fixture()
    company = company_fixture(user, %{})
    %{conn: log_in_user(conn, user), user: user, company: company}
  end

  describe "Profit & Loss Forecast LiveView" do
    test "renders the form with the heading", %{conn: conn, company: company} do
      {:ok, _lv, html} = live(conn, ~p"/companies/#{company.id}/profit_loss_forecast")
      assert html =~ "Profit &amp; Loss Forecast" or html =~ "Profit & Loss Forecast"
    end

    test "with query params renders the category table (Net Profit row)", %{conn: conn, company: company} do
      {:ok, lv, _html} =
        live(conn, ~p"/companies/#{company.id}/profit_loss_forecast?search[fy_year]=2026&search[granularity]=monthly")

      html = render_async(lv)
      assert html =~ "Net Profit"
      assert html =~ "Gross Margin"
    end

    test "tax rows hidden at rate 0, shown after setting a rate", %{conn: conn, company: company} do
      {:ok, lv, html} = live(conn, ~p"/companies/#{company.id}/profit_loss_forecast")
      refute html =~ "Net Profit After Tax"

      lv |> element("button", "Trailing") |> render_click()

      lv
      |> form("form[phx-submit=save_settings]")
      |> render_submit(%{"tax_rate" => "24", "trailing" => %{}})

      html2 = render_async(lv)
      assert html2 =~ "Net Profit After Tax"
      assert html2 =~ "Estimated Tax"
    end
  end
end
