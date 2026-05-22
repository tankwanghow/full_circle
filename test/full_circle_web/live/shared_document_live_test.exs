defmodule FullCircleWeb.SharedDocumentLiveTest do
  use FullCircleWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import FullCircle.BillingFixtures
  import FullCircle.SysFixtures

  alias FullCircleWeb.SharedDocument

  setup do
    user = FullCircle.UserAccountsFixtures.user_fixture()
    company = company_fixture(user, %{})
    invoice = invoice_fixture(company, user)
    %{user: user, company: company, invoice: invoice}
  end

  test "a valid token renders the invoice print page without login", %{
    conn: conn,
    user: user,
    company: company,
    invoice: invoice
  } do
    token = SharedDocument.sign("Invoice", invoice.id, company.id, user.id)

    {:ok, _view, html} =
      live(conn, ~p"/shared/Invoice/#{invoice.id}/print?pre_print=false&token=#{token}")

    assert html =~ invoice.invoice_no
    # the Email button element must not appear on the customer's shared view
    refute html =~ ~s(id="email-btn")
  end

  test "an invalid token redirects to the expired page", %{conn: conn, invoice: invoice} do
    assert {:error, {:redirect, %{to: "/shared/expired"}}} =
             live(conn, ~p"/shared/Invoice/#{invoice.id}/print?pre_print=false&token=bad")
  end

  test "a token for a different document is rejected", %{
    conn: conn,
    user: user,
    company: company,
    invoice: invoice
  } do
    token = SharedDocument.sign("Invoice", Ecto.UUID.generate(), company.id, user.id)

    assert {:error, {:redirect, %{to: "/shared/expired"}}} =
             live(conn, ~p"/shared/Invoice/#{invoice.id}/print?pre_print=false&token=#{token}")
  end
end
