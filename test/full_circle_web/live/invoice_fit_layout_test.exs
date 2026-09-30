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

    test "other documents keep their defaults (pilot is Invoice only)" do
      for page <- ~w(PurInvoice Receipt Payment) do
        assert page
               |> UserSetting.default_settings(Ecto.UUID.generate())
               |> Enum.all?(&(&1.value == "show")),
               "#{page} defaults changed"
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

    test "purchase invoices are untouched by the pilot", %{conn: conn, comp: comp} do
      {:ok, lv, _} = live(conn, ~p"/companies/#{comp.id}/PurInvoice/new")
      refute has_element?(lv, ".detail-fit")
    end
  end
end
