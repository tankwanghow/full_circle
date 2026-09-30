defmodule FullCircleWeb.InvoiceFitLayoutTest do
  use FullCircleWeb.ConnCase

  import Phoenix.LiveViewTest
  import FullCircle.SysFixtures
  import FullCircle.UserAccountsFixtures
  import FullCircle.BillingFixtures

  alias FullCircle.Sys.UserSetting

  describe "invoice column defaults for new users" do
    test "Account, Tax Rate and Discount start hidden; amounts stay shown" do
      values =
        UserSetting.default_settings("Invoice", Ecto.UUID.generate())
        |> Map.new(&{&1.code, &1.value})

      assert values["account-col"] == "hide"
      assert values["taxrate-col"] == "hide"
      assert values["discount-col"] == "hide"
      assert values["goodamt-col"] == "show"
      assert values["taxamt-col"] == "show"
    end

    test "Purchase Invoice hides the same three; Receipt and Payment keep Account" do
      defaults = fn page ->
        page
        |> UserSetting.default_settings(Ecto.UUID.generate())
        |> Map.new(&{&1.code, &1.value})
      end

      assert %{"account-col" => "hide", "taxrate-col" => "hide", "discount-col" => "hide"} =
               defaults.("PurInvoice")

      # Receipts and payments often post a line straight to an account, so the
      # Account column stays; only Tax Rate and Discount start hidden.
      for page <- ~w(Receipt Payment) do
        assert %{"account-col" => "show", "taxrate-col" => "hide", "discount-col" => "hide"} =
                 defaults.(page)
      end
    end
  end

  describe "invoice form sizes to its columns" do
    setup %{conn: conn} do
      admin = user_fixture()
      comp = company_fixture(admin, %{})
      inv = invoice_fixture(comp, admin)
      %{conn: log_in_user(conn, admin), comp: comp, inv: inv}
    end

    test "the card fits its content and the detail table opts in to fit widths",
         %{conn: conn, comp: comp, inv: inv} do
      {:ok, lv, _} = live(conn, ~p"/companies/#{comp.id}/Invoice/#{inv.id}/edit")
      assert has_element?(lv, "div.w-fit > p", "Edit Invoice")
      assert has_element?(lv, "#invoice_details.detail-fit")
      # New user: hidden-by-default columns are rendered hidden, not removed,
      # so their values still submit.
      assert has_element?(lv, "#invoice_details .detail-account-col.hidden")
      refute has_element?(lv, "#invoice_details .detail-amt-col.hidden")
    end

    for {path, details} <- [
          {"PurInvoice", "pur_invoice_details"},
          {"Receipt", "receipt-details"},
          {"Payment", "payment-details"},
          {"CreditNote", "credit-note-details"},
          {"DebitNote", "debit-note-details"}
        ] do
      test "#{path} card fits its columns", %{conn: conn, comp: comp} do
        {:ok, lv, _} = live(conn, "/companies/#{comp.id}/#{unquote(path)}/new")
        assert has_element?(lv, "div.w-fit > p")
        assert has_element?(lv, "##{unquote(details)}.detail-fit")
      end
    end

    # Tab panels inside a fit card are hidden with tab-hidden (invisible, zero
    # height) rather than display:none, so they still size the card and it does
    # not jump in width when the user switches tabs.
    for {path, panels} <- [
          {"Receipt", ~w(receipt-cheques receipt-details match-trans)},
          {"Payment", ~w(payment-details match-trans)},
          {"CreditNote", ~w(credit-note-details match-trans)},
          {"DebitNote", ~w(debit-note-details match-trans)}
        ] do
      test "#{path} tabs hide panels with tab-hidden, not display:none", %{conn: conn, comp: comp} do
        {:ok, lv, html} = live(conn, "/companies/#{comp.id}/#{unquote(path)}/new")
        doc = LazyHTML.from_document(html)

        for id <- unquote(panels) do
          assert has_element?(lv, "##{id}")
          refute doc |> LazyHTML.query("##{id}.hidden") |> Enum.any?(), "##{id} uses .hidden"
        end

        # The tab buttons switch panels by toggling tab-hidden.
        assert has_element?(lv, ~s([phx-click*="tab-hidden"]))
      end
    end
  end
end
