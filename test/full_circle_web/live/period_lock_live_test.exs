defmodule FullCircleWeb.PeriodLockLiveTest do
  use FullCircleWeb.ConnCase

  import Phoenix.LiveViewTest
  import FullCircle.BillingFixtures

  alias FullCircle.Sys

  test "a GL-affecting save into a closed period flashes the cutoff", %{conn: conn} do
    %{admin: admin, company: company} = billing_setup()
    invoice = invoice_fixture(company, admin)
    {:ok, _} = Sys.close_period_through(company, Date.utc_today(), admin)

    conn = log_in_user(conn, admin)

    {:ok, view, _html} =
      live(conn, ~p"/companies/#{company.id}/Invoice/#{invoice.id}/edit")

    html =
      view
      |> form("#object-form",
        invoice: %{
          invoice_details: %{"0" => %{unit_price: "99.00", package_qty: "10"}}
        }
      )
      |> render_submit()

    assert html =~ "Accounting period is closed"
  end

  test "an admin sees the period cutoff control", %{conn: conn} do
    %{admin: admin, company: company} = billing_setup()

    # /edit_company/:id is outside the company-scoped pipeline, so
    # set_active_company never writes current_role. Seed it as a live session would.
    conn = conn |> log_in_user(admin) |> put_session(:current_role, "admin")

    {:ok, _view, html} = live(conn, ~p"/edit_company/#{company.id}")

    assert html =~ "Close Accounting Period"
  end

  test "a clerk does not see the period cutoff control", %{conn: conn} do
    %{admin: admin, company: company} = billing_setup()
    clerk = FullCircle.UserAccountsFixtures.user_fixture()
    {:ok, _} = Sys.allow_user_to_access(company, clerk, "clerk", admin)

    conn = conn |> log_in_user(clerk) |> put_session(:current_role, "clerk")

    {:ok, _view, html} = live(conn, ~p"/edit_company/#{company.id}")

    refute html =~ "Close Accounting Period"
  end

  test "an admin can set the cutoff from the form", %{conn: conn} do
    %{admin: admin, company: company} = billing_setup()
    conn = conn |> log_in_user(admin) |> put_session(:current_role, "admin")

    {:ok, view, _html} = live(conn, ~p"/edit_company/#{company.id}")

    view
    |> form("#period-lock-form", period: %{closed_through: "2025-12-31"})
    |> render_submit()

    company = FullCircle.Sys.get_company!(company.id)
    assert Sys.period_closed_through(company) == ~D[2025-12-31]
  end
end
