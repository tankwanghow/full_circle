defmodule FullCircleWeb.TaxCodeLiveTest do
  use FullCircleWeb.ConnCase

  import Phoenix.LiveViewTest
  import FullCircle.SysFixtures
  import FullCircle.UserAccountsFixtures
  import FullCircle.BillingFixtures

  setup %{conn: conn} do
    user = user_fixture()
    comp = company_fixture(user, %{})
    tc = sales_tax_code_fixture(comp, user, %{"code" => "TESTTAX", "descriptions" => "test desc"})
    %{conn: log_in_user(conn, user), user: user, comp: comp, tc: tc}
  end

  describe "data value" do
    setup %{conn: conn, comp: comp, tc: tc} do
      {:ok, lv, html} = live(conn, ~p"/companies/#{comp.id}/tax_codes/#{tc.id}/edit")
      %{conn: conn, lv: lv, html: html, obj: tc}
    end

    test_input_value("tax_code", "input", :text, "code")
    test_input_value("tax_code", "select", :text, "tax_type")
    test_input_value("tax_code", "textarea", :text, "descriptions")
  end

  describe "data validation" do
    setup %{conn: conn, comp: comp} do
      {:ok, lv, html} = live(conn, ~p"/companies/#{comp.id}/tax_codes/new")
      %{conn: conn, lv: lv, html: html}
    end

    test "code can't be blank", %{lv: lv} do
      html =
        lv
        |> element("#object-form")
        |> render_change(%{tax_code: %{code: ""}})

      text = html |> LazyHTML.from_fragment() |> LazyHTML.query(~s|p.text-rose-600|) |> LazyHTML.text()
      assert text =~ "can't be blank"
    end

    test "tax_type can't be blank", %{lv: lv} do
      html =
        lv
        |> element("#object-form")
        |> render_change(%{tax_code: %{tax_type: ""}})

      text = html |> LazyHTML.from_fragment() |> LazyHTML.query(~s|p.text-rose-600|) |> LazyHTML.text()
      assert text =~ "can't be blank"
    end
  end

  describe "Edit" do
    setup %{conn: conn, comp: comp, tc: tc} do
      {:ok, lv, html} = live(conn, ~p"/companies/#{comp.id}/tax_codes/#{tc.id}/edit")
      %{conn: conn, lv: lv, html: html, comp: comp, tc: tc}
    end

    test "save valid tax_code", %{conn: conn, lv: lv, tc: tc} do
      {:ok, _, html} =
        lv
        |> form("#object-form",
          tax_code: %{
            code: "UpdatedTC",
            tax_type: "Sales",
            rate: "0.08",
            account_name: "Sales Tax Payable",
            account_id: tc.account_id
          }
        )
        |> render_submit()
        |> follow_redirect(conn)

      assert html =~ "UpdatedTC"
      assert html =~ "TaxCode updated successfully"
    end

    test "save invalid tax_code", %{lv: lv} do
      html =
        lv
        |> form("#object-form", tax_code: %{code: ""})
        |> render_submit()

      assert html =~ "Failed"
      assert html =~ "Edit TaxCode"
    end

    test "form layout", %{html: html} do
      assert html =~ "Edit TaxCode"
      assert html =~ "Code\n</label>"
      assert html =~ "TaxCode Type\n</label>"
      assert html =~ "Rate (6% = 0.06, 10% = 0.1)\n</label>"
      assert html =~ "Account\n</label>"
      assert html =~ "Descriptions\n</label>"
    end
  end

  describe "New" do
    setup %{conn: conn, comp: comp, tc: tc} do
      {:ok, lv, html} = live(conn, ~p"/companies/#{comp.id}/tax_codes/new")
      %{conn: conn, lv: lv, html: html, tc: tc}
    end

    test "save valid tax_code", %{conn: conn, lv: lv} do
      # First trigger the autocomplete to set the account_id
      lv
      |> element("#object-form")
      |> render_change(%{
        _target: ["tax_code", "account_name"],
        tax_code: %{
          code: "NewTC",
          tax_type: "Sales",
          rate: "0.10",
          account_name: "Sales Tax Payable"
        }
      })

      {:ok, _, html} =
        lv
        |> form("#object-form",
          tax_code: %{
            code: "NewTC",
            tax_type: "Sales",
            rate: "0.10",
            account_name: "Sales Tax Payable"
          }
        )
        |> render_submit()
        |> follow_redirect(conn)

      assert html =~ "NewTC"
      assert html =~ "TaxCode created successfully"
    end

    test "save invalid tax_code", %{lv: lv} do
      html =
        lv
        |> form("#object-form", tax_code: %{})
        |> render_submit()

      assert html =~ "Failed"
      assert html =~ "New TaxCode"
    end

    test "form layout", %{html: html} do
      assert html =~ "New TaxCode"
      assert html =~ "Code\n</label>"
      assert html =~ "TaxCode Type\n</label>"
      assert html =~ "Rate (6% = 0.06, 10% = 0.1)\n</label>"
      assert html =~ "Account\n</label>"
      assert html =~ "Descriptions\n</label>"
    end
  end

  describe "Index" do
    test "layout", %{conn: conn, comp: comp} do
      {:ok, _lv, html} = live(conn, ~p"/companies/#{comp.id}/tax_codes")
      assert html =~ "TaxCode Listing"

      assert LazyHTML.from_fragment(html)
             |> LazyHTML.query(~s|form input[name="search[terms]"]|)
             |> LazyHTML.to_tree() != []

      assert html =~ "TaxCode Information"
    end

    test "tax_code list", %{conn: conn, comp: comp} do
      {:ok, _lv, html} = live(conn, ~p"/companies/#{comp.id}/tax_codes")
      text = LazyHTML.from_fragment(html) |> LazyHTML.query(~s|div#objects_list|) |> LazyHTML.text()
      assert text =~ "TESTTAX"
    end

    test "add new tax_code", %{conn: conn, comp: comp} do
      {:ok, lv, html} = live(conn, ~p"/companies/#{comp.id}/tax_codes")

      assert LazyHTML.from_fragment(html)
             |> LazyHTML.query(~s|a#new_object|)
             |> LazyHTML.to_tree() != []

      {:ok, _lv, html} = lv |> element("#new_object") |> render_click() |> follow_redirect(conn)
      assert html =~ "New TaxCode"
    end
  end
end
