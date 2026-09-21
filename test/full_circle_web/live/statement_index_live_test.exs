defmodule FullCircleWeb.StatementIndexLiveTest do
  @moduledoc """
  The Contacts Balance search form.
  """
  use FullCircleWeb.ConnCase

  import Phoenix.LiveViewTest
  import FullCircle.SysFixtures
  import FullCircle.UserAccountsFixtures

  setup %{conn: conn} do
    user = user_fixture()
    company = company_fixture(user, %{closing_month: 12, closing_day: 31})
    %{conn: log_in_user(conn, user), user: user, company: company}
  end

  defp debtor_fixture(company, user) do
    contact = FullCircle.BillingFixtures.contact_fixture(company, user)
    account = FullCircle.Accounting.get_account_by_name("General Sales", company, user)

    FullCircle.Repo.insert!(%FullCircle.Accounting.Transaction{
      doc_type: "Invoice",
      doc_no: "INV#{System.unique_integer([:positive])}",
      doc_date: Date.add(Date.utc_today(), -3),
      particulars: "sale",
      amount: Decimal.new("500"),
      company_id: company.id,
      contact_id: contact.id,
      account_id: account.id
    })

    contact
  end

  test "ticking a row on a freshly loaded page renders the print link", %{
    conn: conn,
    company: company,
    user: user
  } do
    contact = debtor_fixture(company, user)

    # No query params: handle_params falls back to its own default To date.
    {:ok, lv, _html} = live(conn, ~p"/companies/#{company.id}/debtor_statement")

    html = render_click(lv, "check_click", %{"object-id" => contact.id, "value" => "on"})

    assert html =~ "Statement/print_multi"
    assert html =~ "tdate=#{Date.to_iso8601(Date.utc_today())}"
  end
end
