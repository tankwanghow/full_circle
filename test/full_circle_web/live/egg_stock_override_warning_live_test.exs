defmodule FullCircleWeb.EggStockOverrideWarningLiveTest do
  @moduledoc """
  A document replaces a planned row's quantities wholesale, so a document that
  omits a grade silently zeroes it. These tests pin the warning that makes such
  an override visible on the Estimated tab, and its link to the document.
  """
  use FullCircleWeb.ConnCase
  import Ecto.Query
  import Phoenix.LiveViewTest
  import FullCircle.SysFixtures
  import FullCircle.UserAccountsFixtures
  import FullCircle.BillingFixtures

  alias FullCircle.EggStock

  setup %{conn: conn} do
    user = user_fixture()
    company = company_fixture(user, %{})
    contact = contact_fixture(company, user)

    {:ok, _} =
      EggStock.save_grades(company.id, [
        %{"name" => "AA", "nickname" => "AA", "position" => 0, "delete" => "false"},
        %{"name" => "A", "nickname" => "A", "position" => 1, "delete" => "false"}
      ])

    %{conn: log_in_user(conn, user), user: user, company: company, contact: contact}
  end

  # The board date drives the forecast window, so the sale must land inside it.
  defp board_and_sale_dates do
    board = Date.utc_today()
    {board, Date.add(board, 1)}
  end

  defp seed_book(company, user, contact, date, qty) do
    {:ok, _} =
      EggStock.save_dow_lines(
        company.id,
        :sales,
        Date.day_of_week(date),
        [
          %{
            "id" => "",
            "contact_id" => contact.id,
            "contact_name" => contact.name,
            "quantities" => %{"AA" => qty},
            "is_separator" => "false",
            "delete" => "false"
          }
        ],
        company,
        user
      )
  end

  defp one_tray_invoice(company, user, contact, date) do
    good = good_fixture(company, user, %{"name" => "AA"})
    sales_acct = FullCircle.Accounting.get_account_by_name("General Sales", company, user)

    sales_tc =
      FullCircle.Repo.one!(
        from tc in FullCircle.Accounting.TaxCode,
          where: tc.company_id == ^company.id and tc.code == "NoSTax"
      )

    attrs =
      contact
      |> invoice_attrs(good, sales_acct, sales_tc, quantity: "1", tax_rate: "0")
      |> Map.put("invoice_date", Date.to_string(date))
      |> Map.put("due_date", Date.to_string(Date.add(date, 30)))

    {:ok, %{create_invoice: invoice}} = FullCircle.Billing.create_invoice(attrs, company, user)
    invoice
  end

  defp estimated_tab(conn, company, board) do
    {:ok, lv, _html} =
      live(conn, ~p"/companies/#{company.id}/egg_stock/#{Date.to_iso8601(board)}")

    lv |> element("button[phx-value-tab='estimated']") |> render_click()
  end

  test "warns on the estimate row when a document disagrees with the book", %{
    conn: conn,
    company: company,
    user: user,
    contact: contact
  } do
    {board, sale_date} = board_and_sale_dates()
    seed_book(company, user, contact, sale_date, "700")
    invoice = one_tray_invoice(company, user, contact, sale_date)

    html = estimated_tab(conn, company, board)

    assert html =~ "planned 700, document 1"
    assert html =~ contact.name
    assert html =~ "hero-exclamation-triangle-solid"
    # the warning is actionable: it links straight to the document to correct
    assert html =~ "/companies/#{company.id}/Invoice/#{invoice.id}/edit"
  end

  test "no warning when the document matches the book", %{
    conn: conn,
    company: company,
    user: user,
    contact: contact
  } do
    {board, sale_date} = board_and_sale_dates()
    seed_book(company, user, contact, sale_date, "1")
    _invoice = one_tray_invoice(company, user, contact, sale_date)

    html = estimated_tab(conn, company, board)

    refute html =~ "hero-exclamation-triangle-solid"
    refute html =~ "document 1"
  end

  test "no warning when there is no document at all", %{
    conn: conn,
    company: company,
    user: user,
    contact: contact
  } do
    {board, sale_date} = board_and_sale_dates()
    seed_book(company, user, contact, sale_date, "700")

    html = estimated_tab(conn, company, board)

    refute html =~ "hero-exclamation-triangle-solid"
  end
end
