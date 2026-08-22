defmodule FullCircleWeb.ReportLive.GoodSnPTest do
  use FullCircleWeb.ConnCase
  import Phoenix.LiveViewTest
  import FullCircle.SysFixtures
  import FullCircle.UserAccountsFixtures
  import FullCircle.BillingFixtures
  import FullCircle.ReceiveFundFixtures
  import FullCircle.BillPayFixtures

  setup %{conn: conn} do
    user = user_fixture()
    company = company_fixture(user, %{})
    %{conn: log_in_user(conn, user), user: user, company: company}
  end

  test "sales type lists invoice and cash receipt lines", %{
    conn: conn,
    company: company,
    user: user
  } do
    invoice = invoice_fixture(company, user)
    receipt = receipt_fixture(company, user)

    {:ok, lv, _html} =
      live(conn, ~p"/companies/#{company.id}/good_snp?search[type]=sales")

    html = render_async(lv)
    assert html =~ "Customer"
    assert html =~ invoice.invoice_no
    assert html =~ receipt.receipt_no
  end

  test "purchases type lists pur invoice and cash payment lines", %{
    conn: conn,
    company: company,
    user: user
  } do
    pur_invoice = pur_invoice_fixture(company, user)
    payment = payment_fixture(company, user)

    {:ok, lv, _html} =
      live(conn, ~p"/companies/#{company.id}/good_snp?search[type]=purchases")

    html = render_async(lv)
    assert html =~ "Vendor"
    assert html =~ pur_invoice.pur_invoice_no
    assert html =~ payment.payment_no
    refute html =~ "Customer"
  end

  test "legacy /good_sales route renders the combined page defaulting to sales", %{
    conn: conn,
    company: company,
    user: user
  } do
    invoice = invoice_fixture(company, user)

    {:ok, lv, _html} = live(conn, ~p"/companies/#{company.id}/good_sales")

    html = render_async(lv)
    assert html =~ "Customer"
    assert html =~ invoice.invoice_no
  end
end
