defmodule FullCircleWeb.StatementPrintLiveTest do
  @moduledoc """
  The printed statement's detail window. The index form always emits `days`,
  empty when the box is blank, so the empty case is the common path.

  Assertions about the Period line are scoped to the `.statement-info` element:
  the word also appears in the stylesheet, so a whole-page substring match
  passes vacuously.
  """
  use FullCircleWeb.ConnCase

  import Phoenix.LiveViewTest
  import FullCircle.SysFixtures
  import FullCircle.UserAccountsFixtures
  import FullCircle.BillingFixtures

  alias FullCircle.Accounting.Transaction
  alias FullCircle.Repo

  @tdate "2026-09-21"

  setup %{conn: conn} do
    user = user_fixture()
    company = company_fixture(user, %{closing_month: 12, closing_day: 31})
    contact = contact_fixture(company, user)
    account = FullCircle.Accounting.get_account_by_name("General Sales", company, user)

    txn!(company, contact, account, ~D[2026-03-10], 100)
    txn!(company, contact, account, ~D[2026-06-15], 200)
    txn!(company, contact, account, ~D[2026-09-05], 300)

    %{conn: log_in_user(conn, user), user: user, company: company, contact: contact}
  end

  defp txn!(com, contact, account, date, amount) do
    Repo.insert!(%Transaction{
      doc_type: "Invoice",
      doc_no: "INV#{System.unique_integer([:positive])}",
      doc_date: date,
      particulars: "sale",
      amount: Decimal.new("#{amount}"),
      company_id: com.id,
      contact_id: contact.id,
      account_id: account.id
    })
  end

  defp print(conn, company, contact, days) do
    {:ok, _lv, html} =
      live(
        conn,
        "/companies/#{company.id}/Statement/print_multi" <>
          "?tdate=#{@tdate}&days=#{days}&ids=#{contact.id}&c1=30&c2=60&c3=90&c4=120"
      )

    html
  end

  defp statement_info(html) do
    info =
      html
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("div.statement-info")

    assert Enum.count(info) >= 1, "expected a statement-info block on the sheet"
    info
  end

  defp info_text(html), do: html |> statement_info() |> LazyHTML.text()

  defp doc_info_cells(html) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("div.txn div.doc_info")
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))
  end

  defp info_classes(html) do
    html |> statement_info() |> LazyHTML.attribute("class") |> Enum.join(" ")
  end

  test "days reaches further back than the contact's last trading month", %{
    conn: conn,
    company: company,
    contact: contact
  } do
    html = print(conn, company, contact, 120)

    # 2026-09-21 less 120 days is 2026-05-24, so the June sale is on the sheet.
    # Transaction rows print the raw Date, so ISO — the Period line uses format_date.
    assert html =~ "2026-06-15"
    assert info_text(html) =~ "Period:"
    assert info_text(html) =~ "24-05-2026 - 21-09-2026"
  end

  test "a blank days box keeps the per-contact month and prints no period", %{
    conn: conn,
    company: company,
    contact: contact
  } do
    html = print(conn, company, contact, "")

    # start of the month of the last transaction, so June is not on the sheet
    refute html =~ "2026-06-15"
    refute info_text(html) =~ "Period:"
  end

  test "days is capped at a year, however large the param", %{
    conn: conn,
    company: company,
    contact: contact
  } do
    # The cap is server side because the print URL is reachable directly, where
    # the input's max attribute means nothing.
    assert info_text(print(conn, company, contact, 365)) =~ "21-09-2025 - 21-09-2026"
    assert info_text(print(conn, company, contact, 9999)) =~ "21-09-2025 - 21-09-2026"
  end

  test "a non-numeric days param is ignored rather than crashing", %{
    conn: conn,
    company: company,
    contact: contact
  } do
    html = print(conn, company, contact, "abc")

    refute html =~ "2026-06-15"
    refute info_text(html) =~ "Period:"
  end

  test "the period line is marked so the floated header keeps its height", %{
    conn: conn,
    company: company,
    contact: contact
  } do
    # The info block floats inside a fixed 40mm header. with-period buys back
    # the 5mm the extra line costs; without it the float overhangs and squashes
    # the transaction column labels.
    assert info_classes(print(conn, company, contact, 120)) =~ "with-period"
    refute info_classes(print(conn, company, contact, "")) =~ "with-period"
  end

  test "the transaction column shows the document number without its type", %{
    conn: conn,
    company: company,
    contact: contact
  } do
    cells = doc_info_cells(print(conn, company, contact, 120))

    # the header cell plus one per transaction
    assert Enum.count(cells) > 1
    assert Enum.any?(cells, &String.starts_with?(&1, "INV"))
    refute Enum.any?(cells, &String.contains?(&1, "Invoice"))
  end
end
