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
end
