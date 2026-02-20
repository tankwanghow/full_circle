defmodule FullCircleWeb.AccountLiveTest do
  use FullCircleWeb.ConnCase

  import Phoenix.LiveViewTest
  import FullCircle.SysFixtures
  import FullCircle.UserAccountsFixtures
  import FullCircle.AccountingFixtures

  setup %{conn: conn} do
    user = user_fixture()
    comp = company_fixture(user, %{})
    ac = account_fixture(%{name: "TESTACCOUNT"}, comp, user)
    %{conn: log_in_user(conn, user), user: user, comp: comp, ac: ac}
  end

  describe "Delete" do
    setup %{conn: conn, comp: comp, ac: ac} do
      {:ok, lv, html} = live(conn, ~p"/companies/#{comp.id}/accounts/#{ac.id}/edit")
      %{conn: conn, lv: lv, html: html, obj: ac}
    end

    test "default account", %{conn: conn, lv: lv, html: html} do
    end
  end

  describe "data value" do
    setup %{conn: conn, comp: comp, ac: ac} do
      {:ok, lv, html} = live(conn, ~p"/companies/#{comp.id}/accounts/#{ac.id}/edit")
      %{conn: conn, lv: lv, html: html, obj: ac}
    end

    test_input_value("account", "input", :text, "name")
    test_input_value("account", "select", :text, "account_type")
    test_input_value("account", "textarea", :text, "descriptions")
  end

  describe "data validation" do
    setup %{conn: conn, comp: comp} do
      {:ok, lv, html} = live(conn, ~p"/companies/#{comp.id}/accounts/new")
      %{conn: conn, lv: lv, html: html}
    end

    test_input_feedback("account", "name", "", "can't be blank")
    test_input_feedback("account", "account_type", "", "can't be blank")
    test_input_feedback("account", "name", "TESTACCOUNT", "has already been taken")
    test_input_feedback("account", "descriptions", "", "")
    test_input_feedback("account", "account_type", "not a type", "not in list")
  end

  describe "Edit" do
    setup %{conn: conn, comp: comp, ac: ac} do
      {:ok, lv, html} = live(conn, ~p"/companies/#{comp.id}/accounts/#{ac.id}/edit")
      %{conn: conn, lv: lv, html: html, comp: comp, ac: ac}
    end

    test "save valid account", %{conn: conn, lv: lv} do
      {:ok, _, html} =
        lv
        |> form("#account", account: valid_account_attributes(%{name: "kakak"}))
        |> render_submit()
        |> follow_redirect(conn)

      assert html =~ "kakak"
      assert html =~ "Account updated successfully"
    end

    test "save invalid account", %{lv: lv} do
      html =
        lv
        |> form("#account", account: %{name: ""})
        |> render_submit()

      assert html =~ "Failed"
      assert html =~ "Edit Account"
    end

    test "form layout", %{html: html} do
      assert html =~ "Edit Account"
      assert html =~ "Account Name\n</label>"
      assert html =~ "Account Type\n</label>"
      assert html =~ "Descriptions\n</label>"
    end
  end

  describe "New" do
    setup %{conn: conn, comp: comp} do
      {:ok, lv, html} = live(conn, ~p"/companies/#{comp.id}/accounts/new")
      %{conn: conn, lv: lv, html: html}
    end

    test "save valid account", %{conn: conn, lv: lv} do
      {:ok, _, html} =
        lv
        |> form("#account", account: valid_account_attributes(%{name: "kakak"}))
        |> render_submit()
        |> follow_redirect(conn)

      assert html =~ "kakak"
      assert html =~ "Account created successfully"
    end

    test "save invalid account", %{lv: lv} do
      html =
        lv
        |> form("#account", account: %{})
        |> render_submit()

      assert html =~ "Failed"
      assert html =~ "New Account"
    end

    test "form layout", %{html: html} do
      assert html =~ "New Account"
      assert html =~ "Account Name\n</label>"
      assert html =~ "Account Type\n</label>"
      assert html =~ "Descriptions\n</label>"
    end
  end

  describe "Index" do
    test "layout", %{conn: conn, comp: comp} do
      {:ok, _index_live, html} = live(conn, ~p"/companies/#{comp.id}/accounts")
      assert html =~ "Accounts Listing"
      assert LazyHTML.from_fragment(html) |> LazyHTML.query(~s|form input[name="search[terms]"]|) |> LazyHTML.to_tree() != []

      assert html =~ "Account Information"
    end

    test "account list", %{conn: conn, comp: comp} do
      {:ok, _index_live, html} = live(conn, ~p"/companies/#{comp.id}/accounts")
      text = LazyHTML.from_fragment(html) |> LazyHTML.query(~s|div#objects_list a|) |> LazyHTML.text()
      assert text =~ "General Purchases"
      assert text =~ "General Sales"
      assert text =~ "Account Payables"
      assert text =~ "Account Receivables"
      assert text =~ "Sales Tax Payable"
      assert text =~ "Purchase Tax Receivable"
      assert text =~ "TESTACCOUNT"
    end

    test "edit account", %{conn: conn, comp: comp, ac: ac} do
      {:ok, lv, _} = live(conn, ~p"/companies/#{comp.id}/accounts")

      {:ok, _lv, html} =
        lv
        |> element(~s|div#objects-#{ac.id} a|)
        |> render_click()
        |> follow_redirect(conn)

      assert html =~ "Edit Account"
    end

    test "add new account", %{conn: conn, comp: comp} do
      {:ok, lv, html} = live(conn, ~p"/companies/#{comp.id}/accounts")
      assert LazyHTML.from_fragment(html) |> LazyHTML.query(~s|a#new_account|) |> LazyHTML.to_tree() != []

      {:ok, _lv, html} = lv |> element("#new_account") |> render_click() |> follow_redirect(conn)

      assert html =~ "New Account"
    end
  end
end
