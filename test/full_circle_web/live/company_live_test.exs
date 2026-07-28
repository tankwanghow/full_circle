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

    #   assert LazyHTML.from_fragment(html) |> LazyHTML.query("div#company-#{comp.id}") |> LazyHTML.to_tree() == []
    #   assert LazyHTML.from_fragment(html) |> LazyHTML.query("div#company-#{comp1.id}") |> LazyHTML.to_tree() != []
    #   assert LazyHTML.from_fragment(html) |> LazyHTML.query("div#company-#{comp2.id}") |> LazyHTML.to_tree() != []
    # end

    # test "active company", %{conn: conn, comp1: comp1} do
    #   conn = conn |> put_session(:current_company, comp1)
    #   {:ok, lv, html} = live(conn, ~p"/edit_company/#{comp1.id}")
    #   assert LazyHTML.from_fragment(html) |> LazyHTML.query("#active-company") |> LazyHTML.text() =~ comp1.name

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
      parsed = LazyHTML.from_fragment(html)

      assert LazyHTML.query(parsed, ~s|div#company-#{comp.id} a.set-active|) |> LazyHTML.to_tree() ==
               []

      assert LazyHTML.query(parsed, ~s|div#company-#{comp1.id} a.set-active|)
             |> LazyHTML.to_tree() != []

      assert LazyHTML.query(parsed, ~s|div#company-#{comp2.id} a.set-active|)
             |> LazyHTML.to_tree() != []

      conn = conn |> put_session(:current_company, comp1)
      {:ok, _lv, html} = live(conn, ~p"/companies")
      parsed = LazyHTML.from_fragment(html)

      assert LazyHTML.query(parsed, ~s|div#company-#{comp.id} a.set-active|) |> LazyHTML.to_tree() !=
               []

      assert LazyHTML.query(parsed, ~s|div#company-#{comp1.id} a.set-active|)
             |> LazyHTML.to_tree() == []

      assert LazyHTML.query(parsed, ~s|div#company-#{comp2.id} a.set-active|)
             |> LazyHTML.to_tree() != []
    end

    test "click active company", %{conn: conn, comp1: comp1, comp2: comp2} do
      {:ok, lv, _html} = live(conn, ~p"/companies")

      {:ok, _lv, html} =
        lv
        |> element(~s|div#company-#{comp2.id} a.set-active|)
        |> render_click()
        |> follow_redirect(conn)

      assert LazyHTML.from_fragment(html) |> LazyHTML.query("#active-company") |> LazyHTML.text() =~
               comp2.name

      {:ok, lv, _html} = live(conn, ~p"/companies")

      {:ok, _lv, html} =
        lv
        |> element(~s|div#company-#{comp1.id} a.set-active|)
        |> render_click()
        |> follow_redirect(conn)

      assert LazyHTML.from_fragment(html) |> LazyHTML.query("#active-company") |> LazyHTML.text() =~
               comp1.name
    end

    test "mark default company", %{conn: conn, comp1: comp1, comp2: comp2} do
      {:ok, lv, _html} = live(conn, ~p"/companies")

      html =
        lv
        |> element(~s|div#company-#{comp2.id} a.set-default|)
        |> render_click()

      parsed = LazyHTML.from_fragment(html)

      assert LazyHTML.query(parsed, ~s|div#company-#{comp2.id} a.set-default|)
             |> LazyHTML.to_tree() == []

      assert LazyHTML.query(parsed, ~s|div#company-#{comp1.id} a.set-default|)
             |> LazyHTML.to_tree() != []

      html =
        lv
        |> element(~s|div#company-#{comp1.id} a.set-default|)
        |> render_click()

      parsed = LazyHTML.from_fragment(html)

      assert LazyHTML.query(parsed, ~s|div#company-#{comp1.id} a.set-default|)
             |> LazyHTML.to_tree() == []

      assert LazyHTML.query(parsed, ~s|div#company-#{comp2.id} a.set-default|)
             |> LazyHTML.to_tree() != []
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

    # The closing_day select is populated from the *saved* month on mount, so
    # moving from a short month to a long one has to widen the option list
    # before the new day can be submitted. Deterministic stand-in for a flake
    # that only appeared when the random fixture happened to roll February.
    test "save valid company after widening closing_month", %{
      conn: conn,
      user: user,
      comp1: comp1
    } do
      feb_co = company_fixture(user, %{name: "febco", closing_month: 2, closing_day: 28})
      # Keep the edited company inactive — editing the *active* company submits
      # through trigger_action instead of a LiveView redirect.
      conn = conn |> put_session(:current_company, comp1)
      {:ok, lv, _html} = live(conn, ~p"/edit_company/#{feb_co.id}")

      attrs =
        valid_company_attributes(%{name: "janco", closing_month: 1, closing_day: 30})

      {:ok, _, html} =
        lv
        |> announce_closing_month(attrs)
        |> form("#company", company: attrs)
        |> render_submit()
        |> follow_redirect(conn)

      assert html =~ "janco"
    end

    # The other half of the closing-day rule: the select alone cannot hold the
    # line, because narrowing the month strands the chosen day outside the new
    # option list. Left alone the browser silently falls back to day 1.
    test "narrowing the closing month pulls an out-of-range day back into range", %{
      conn: conn,
      user: user,
      comp1: comp1
    } do
      jan_co = company_fixture(user, %{name: "janco30", closing_month: 1, closing_day: 30})
      conn = conn |> put_session(:current_company, comp1)
      {:ok, lv, _html} = live(conn, ~p"/edit_company/#{jan_co.id}")

      html =
        lv
        |> element("#company")
        |> render_change(%{
          "_target" => ["company", "closing_month"],
          "company" => %{"closing_month" => "2"}
        })

      doc = LazyHTML.from_fragment(html)
      options = doc |> LazyHTML.query("#company_closing_day option") |> LazyHTML.attribute("value")

      assert "28" in options
      refute "29" in options
      refute "30" in options

      selected =
        doc
        |> LazyHTML.query("#company_closing_day option[selected]")
        |> LazyHTML.attribute("value")

      assert selected == ["28"], "expected the day to clamp to 28, got #{inspect(selected)}"
    end

    test "save valid company", %{conn: conn, comp: comp, comp1: comp1} do
      conn = conn |> put_session(:current_company, comp1)
      {:ok, lv, _html} = live(conn, ~p"/edit_company/#{comp.id}")

      attrs = valid_company_attributes(%{name: "kakak"})

      {:ok, _, html} =
        lv
        |> announce_closing_month(attrs)
        |> form("#company", company: attrs)
        |> render_submit()
        |> follow_redirect(conn)

      assert html =~ "kakak"
      assert html =~ "Company Listing"
    end

    test "save active valid company", %{conn: conn, comp: comp} do
      conn = conn |> put_session(:current_company, comp)
      {:ok, lv, html} = live(conn, ~p"/edit_company/#{comp.id}")

      assert LazyHTML.from_fragment(html) |> LazyHTML.query("#active-company") |> LazyHTML.text() =~
               comp.name

      attrs = valid_company_attributes(%{name: "kakak"})

      form =
        lv
        |> announce_closing_month(attrs)
        |> form("#company", company: attrs)

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
      attrs = valid_company_attributes(%{name: "kakak"})

      {:ok, _, html} =
        lv
        |> announce_closing_month(attrs)
        |> form("#company", company: attrs)
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

  # Fix A (announcing the month) is only sufficient because the fixture never
  # hands back a day the resulting month cannot offer. Pinned directly rather
  # than left to seed roulette: the original flake needed February *and* a day
  # above 28, roughly 1 run in 180, which no practical seed sweep will surface.
  test "valid_company_attributes never yields a day the closing_day select rejects" do
    days_offered = %{
      1 => 31,
      2 => 28,
      3 => 31,
      4 => 30,
      5 => 31,
      6 => 30,
      7 => 31,
      8 => 31,
      9 => 30,
      10 => 31,
      11 => 30,
      12 => 31
    }

    for _ <- 1..2000 do
      attrs = valid_company_attributes()

      assert attrs.closing_day >= 1
      assert attrs.closing_day <= days_offered[attrs.closing_month],
             "month #{attrs.closing_month} offers 1..#{days_offered[attrs.closing_month]}, " <>
               "fixture produced day #{attrs.closing_day}"
    end
  end

  # The closing_day options are rebuilt only by the validate clause whose
  # _target is closing_month, so a test that moves month and day in one
  # submission would be checked against the previous month's option list. A
  # browser never does that — it fires change on the month first. Do the same.
  defp announce_closing_month(lv, attrs) do
    lv
    |> element("#company")
    |> render_change(%{
      "_target" => ["company", "closing_month"],
      "company" => %{"closing_month" => "#{attrs.closing_month}"}
    })

    lv
  end
end
