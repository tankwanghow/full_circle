defmodule FullCircleWeb.CompanyLiveTest do
  use FullCircleWeb.ConnCase

  import Phoenix.LiveViewTest
  import FullCircle.SysFixtures
  import FullCircle.UserAccountsFixtures

  setup %{conn: conn} do
    user = user_fixture()
    comp = company_fixture(user, %{name: "already used company name"})
    company_fixture(user_fixture(), %{name: "already by other user company name"})
    %{conn: log_in_user(conn, user), user: user, comp: comp}
  end

  describe "Delete" do
    # setup %{conn: conn, comp: comp, user: user} do
    #   comp1 = company_fixture(user, %{})
    #   comp2 = company_fixture(user, %{})
    #   {:ok, lv, html} = live(conn, ~p"/edit_company/#{comp.id}")
    #   %{conn: conn, lv: lv, comp: comp, comp1: comp1, comp2: comp2, html: html}
    # end

    # test "not active company", %{conn: conn, comp: comp, comp1: comp1, comp2: comp2, lv: lv} do
    #   conn = conn |> put_session(:current_company, comp1)

    #   {:ok, _lv, html} =
    #     lv |> element("#delete-company-modal-confirm") |> render_click() |> follow_redirect(conn)

    #   assert Floki.find(html, "div#company-#{comp.id}") == []
    #   assert Floki.find(html, "div#company-#{comp1.id}") != []
    #   assert Floki.find(html, "div#company-#{comp2.id}") != []
    # end

    # test "active company", %{conn: conn, comp1: comp1} do
    #   conn = conn |> put_session(:current_company, comp1)
    #   {:ok, lv, html} = live(conn, ~p"/edit_company/#{comp1.id}")
    #   assert Floki.find(html, "#active-company") |> Floki.text() =~ comp1.name

    #   {:ok, conn} =
    #     lv |> element("#delete-company-modal-confirm") |> render_click() |> follow_redirect(conn)

    #   assert get_session(conn, :current_company) == nil
    # end
  end

  describe "Index" do
    setup %{conn: conn, comp: comp, user: user} do
      comp1 = company_fixture(user, %{})
      comp2 = company_fixture(user, %{})
      %{conn: conn, comp: comp, comp1: comp1, comp2: comp2}
    end

    test "lists all companies", %{conn: conn, comp: comp, comp1: comp1, comp2: comp2} do
      {:ok, _lv, html} = live(conn, ~p"/companies")
      assert html =~ "Company Listing"
      assert html =~ comp.name
      assert html =~ comp1.name
      assert html =~ comp2.name
    end

    test "mark active company", %{conn: conn, comp: comp, comp1: comp1, comp2: comp2} do
      conn = conn |> put_session(:current_company, comp)
      {:ok, _lv, html} = live(conn, ~p"/companies")
      assert Floki.find(html, ~s|div#company-#{comp.id}} a.set-active|) == []
      assert Floki.find(html, ~s|div#company-#{comp1.id}} a.set-active|) != []
      assert Floki.find(html, ~s|div#company-#{comp2.id}} a.set-active|) != []
      conn = conn |> put_session(:current_company, comp1)
      {:ok, _lv, html} = live(conn, ~p"/companies")
      assert Floki.find(html, ~s|div#company-#{comp.id}} a.set-active|) != []
      assert Floki.find(html, ~s|div#company-#{comp1.id}} a.set-active|) == []
      assert Floki.find(html, ~s|div#company-#{comp2.id}} a.set-active|) != []
    end

    test "click active company", %{conn: conn, comp1: comp1, comp2: comp2} do
      {:ok, lv, _html} = live(conn, ~p"/companies")

      {:ok, _lv, html} =
        lv
        |> element(~s|div#company-#{comp2.id}} a.set-active|)
        |> render_click()
        |> follow_redirect(conn)

      assert Floki.find(html, "#active-company") |> Floki.text() =~ comp2.name
      {:ok, lv, _html} = live(conn, ~p"/companies")

      {:ok, _lv, html} =
        lv
        |> element(~s|div#company-#{comp1.id}} a.set-active|)
        |> render_click()
        |> follow_redirect(conn)

      assert Floki.find(html, "#active-company") |> Floki.text() =~ comp1.name
    end

    test "mark default company", %{conn: conn, comp1: comp1, comp2: comp2} do
      {:ok, lv, _html} = live(conn, ~p"/companies")

      html =
        lv
        |> element(~s|div#company-#{comp2.id}} a.set-default|)
        |> render_click()

      assert Floki.find(html, ~s|div#company-#{comp2.id}} a.set-default|) == []
      assert Floki.find(html, ~s|div#company-#{comp1.id}} a.set-default|) != []

      html =
        lv
        |> element(~s|div#company-#{comp1.id}} a.set-default|)
        |> render_click()

      assert Floki.find(html, ~s|div#company-#{comp1.id}} a.set-default|) == []
      assert Floki.find(html, ~s|div#company-#{comp2.id}} a.set-default|) != []
    end
  end

  describe "data value" do
    setup %{conn: conn, comp: comp} do
      {:ok, lv, html} = live(conn, ~p"/edit_company/#{comp.id}")
      %{conn: conn, lv: lv, html: html, obj: comp}
    end

    test_input_value("company", "input", :text, "city")
    test_input_value("company", "input", :text, "state")
    test_input_value("company", "input", :text, "country")
    test_input_value("company", "input", :text, "zipcode")
    test_input_value("company", "input", :text, "timezone")
    test_input_value("company", "select", :number, "closing_day")
    test_input_value("company", "select", :number, "closing_month")
    test_input_value("company", "input", :text, "name")
    test_input_value("company", "input", :text, "address1")
    test_input_value("company", "input", :text, "address2")
    test_input_value("company", "input", :text, "descriptions")
  end

  describe "data validation" do
    setup %{conn: conn} do
      {:ok, lv, html} = live(conn, ~p"/companies/new")
      %{conn: conn, lv: lv, html: html}
    end

    test_input_feedback("company", "city", "", "")
    test_input_feedback("company", "state", "", "")
    test_input_feedback("company", "country", "", "can't be blank")
    test_input_feedback("company", "zipcode", "", "")
    test_input_feedback("company", "timezone", "", "can't be blank")
    test_input_feedback("company", "closing_day", "", "can't be blank")
    test_input_feedback("company", "closing_month", "", "can't be blank")
    test_input_feedback("company", "name", "", "can't be blank")
    test_input_feedback("company", "name", "already used company name", "has already been taken")
    test_input_feedback("company", "name", "already by other user company name", "")
    test_input_feedback("company", "address1", "", "")
    test_input_feedback("company", "address2", "", "")
    test_input_feedback("company", "descriptions", "", "")
    test_input_feedback("company", "country", "not a country", "not in list")
    test_input_feedback("company", "timezone", "not a timezone", "not in list")
    test_input_feedback("company", "closing_day", "0", "must between 1 to 31")
    test_input_feedback("company", "closing_month", "0", "must between 1 to 12")
    test_input_feedback("company", "closing_day", "32", "must between 1 to 31")
    test_input_feedback("company", "closing_month", "14", "must between 1 to 12")
  end

  describe "Edit" do
    setup %{conn: conn, comp: comp, user: user} do
      comp1 = company_fixture(user, %{name: "comp1"})
      comp2 = company_fixture(user, %{name: "comp2"})
      {:ok, lv, html} = live(conn, ~p"/edit_company/#{comp2.id}")
      %{conn: conn, lv: lv, html: html, comp: comp, comp1: comp1, comp2: comp2}
    end

    test "save valid company", %{conn: conn, comp: comp, comp1: comp1} do
      conn = conn |> put_session(:current_company, comp1)
      {:ok, lv, _html} = live(conn, ~p"/edit_company/#{comp.id}")
      {:ok, _, html} =
        lv
        |> form("#company", company: valid_company_attributes(%{name: "kakak"}))
        |> render_submit()
        |> follow_redirect(conn)

      assert html =~ "kakak"
      assert html =~ "Company Listing"
    end

    test "save active valid company", %{conn: conn, comp: comp} do
      conn = conn |> put_session(:current_company, comp)
      {:ok, lv, html} = live(conn, ~p"/edit_company/#{comp.id}")
      assert html |> Floki.find("#active-company") |> Floki.text() =~ comp.name

      form =
        lv
        |> form("#company", company: valid_company_attributes(%{name: "kakak"}))

      render_submit(form)
      conn = follow_trigger_action(form, conn)
      assert redirected_to(conn) == ~p"/companies"
      assert get_session(conn, :current_company).name == "kakak"
    end

    test "save invalid company", %{lv: lv} do
      html =
        lv
        |> form("#company", company: %{name: ""})
        |> render_submit()

      assert html =~ "Failed to Update Company"
      assert html =~ "Editing Company"
    end

    test "form layout", %{html: html} do
      assert html =~ "Editing Company"
      assert html =~ "Name\n</label>"
      assert html =~ "Address Line 1\n</label>"
      assert html =~ "Address Line 2\n</label>"
      assert html =~ "City\n</label>"
      assert html =~ "State\n</label>"
      assert html =~ "Postal Code\n</label>"
      assert html =~ "Country\n</label>"
      assert html =~ "Tel\n</label>"
      assert html =~ "Fax\n</label>"
      assert html =~ "Email\n</label>"
      assert html =~ "Time Zone\n</label>"
      assert html =~ "Closing Day\n</label>"
      assert html =~ "Closing Month\n</label>"
      assert html =~ "Descriptions\n</label>"
    end
  end

  describe "New" do
    setup %{conn: conn} do
      {:ok, lv, html} = live(conn, ~p"/companies/new")
      %{conn: conn, lv: lv, html: html}
    end

    test "save valid company", %{conn: conn, lv: lv} do
      {:ok, _, html} =
        lv
        |> form("#company", company: valid_company_attributes(%{name: "kakak"}))
        |> render_submit()
        |> follow_redirect(conn)

      assert html =~ "kakak"
      assert html =~ "Company Listing"
    end

    test "save invalid company", %{lv: lv} do
      html =
        lv
        |> form("#company", company: %{})
        |> render_submit()

      assert html =~ "Failed to Create Company"
      assert html =~ "Creating Company"
    end

    test "form layout", %{html: html} do
      assert html =~ "Creating Company"
      assert html =~ "Name\n</label>"
      assert html =~ "Address Line 1\n</label>"
      assert html =~ "Address Line 2\n</label>"
      assert html =~ "City\n</label>"
      assert html =~ "State\n</label>"
      assert html =~ "Postal Code\n</label>"
      assert html =~ "Country\n</label>"
      assert html =~ "Tel\n</label>"
      assert html =~ "Fax\n</label>"
      assert html =~ "Email\n</label>"
      assert html =~ "Time Zone\n</label>"
      assert html =~ "Closing Day\n</label>"
      assert html =~ "Closing Month\n</label>"
      assert html =~ "Descriptions\n</label>"
    end
  end
end
