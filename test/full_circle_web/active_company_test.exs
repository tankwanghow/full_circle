defmodule FullCircleWeb.ActiveCompanyTest do
  use FullCircleWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import FullCircle.SysFixtures

  alias FullCircle.Sys
  import FullCircle.UserAccountsFixtures

  setup %{conn: conn} do
    user = user_fixture()
    not_admin = user_fixture()
    comp = company_fixture(user, %{name: "haha0"})
    FullCircle.Sys.allow_user_to_access(comp, not_admin, "clerk", user)
    %{conn: log_in_user(conn, user), user: user, comp: comp, not_admin: not_admin}
  end

  describe "active company" do
    test "store active company to session", %{conn: conn, comp: comp} do
      {:ok, _lv, html} = live(conn, "/companies")
      assert html =~ comp.name
      assert html =~ "Company Listing"
    end

    test "show company name", %{conn: conn, comp: comp} do
      {:ok, _lv, html} = live(conn, ~p"/companies/#{comp.id}/dashboard")
      assert html =~ comp.name
      assert html =~ ~r{id="full_circle_dashboard"[^>]*>[^<]*Home\s*</a>}
      refute html =~ "Dashboard"
    end

    test "show users list menu", %{conn: conn, comp: comp} do
      {:ok, _lv, html} = live(conn, ~p"/companies/#{comp.id}/dashboard")
      assert html =~ comp.name
      assert html =~ "Home"
      assert html =~ "Users"
    end

    test "don't show users list in menu", %{conn: conn, comp: comp, not_admin: not_admin} do
      conn = log_in_user(conn, not_admin)
      {:ok, _lv, html} = live(conn, ~p"/companies/#{comp.id}/dashboard")
      assert html =~ comp.name
      assert html =~ "Home"
      refute html =~ "Users"
    end

    test "not authorise company", %{conn: conn} do
      comp1 = company_fixture(user_fixture(), %{name: "Tan How"})

      assert {:error, {:redirect, %{to: "/"}}} =
               result = live(conn, ~p"/companies/#{comp1.id}/dashboard")

      {:ok, conn} = follow_redirect(result, conn)
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Not Authorise."
    end
  end

  describe "authorisation" do
    # The session is SIGNED, not encrypted, and the signing key was public for
    # a long time. So a session naming a company must never be taken as proof
    # that the user may open it — re-check CompanyUser on every request.
    test "a session naming a company the user cannot access is refused", %{conn: conn} do
      other = company_fixture(user_fixture(), %{name: "Someone Elses Sdn Bhd"})

      conn =
        conn
        |> Plug.Test.init_test_session(%{})
        |> put_session(:current_company_id, other.id)
        |> put_session(:current_role, "admin")
        |> get(~p"/companies/#{other.id}/dashboard")

      assert redirected_to(conn) == "/"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Not Authorise."
    end

    test "a disabled user is refused, matching user_company/2", %{
      conn: conn,
      comp: comp,
      not_admin: not_admin,
      user: user
    } do
      # change_user_role_in/4 also revokes the user's tokens, so disable first
      # and sign in afterwards.
      Sys.change_user_role_in(comp, not_admin.id, "disable", user)

      conn =
        conn
        |> log_in_user(not_admin)
        |> Plug.Test.init_test_session(%{})
        |> put_session(:current_company_id, comp.id)
        |> get(~p"/companies/#{comp.id}/dashboard")

      assert redirected_to(conn) == "/"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Not Authorise."
    end

    test "the role in the session cannot outrank the role in the database", %{
      conn: conn,
      comp: comp,
      not_admin: not_admin
    } do
      conn =
        conn
        |> log_in_user(not_admin)
        |> Plug.Test.init_test_session(%{})
        |> put_session(:current_company_id, comp.id)
        |> put_session(:current_role, "admin")
        |> get(~p"/companies/#{comp.id}/dashboard")

      assert get_session(conn, "current_role") == "clerk"
      refute html_response(conn, 200) =~ "Administrator Functions"
    end
  end

  describe "session payload" do
    # The session is a signed cookie: Plug hard-caps it at 4096 bytes and nginx
    # refuses a response header block over its 4k proxy_buffer_size with a 502.
    # Putting the whole Company struct in it made the cookie grow with
    # `companies.settings`, which the forecast exclusion lists fill with account
    # UUIDs. Only the company id belongs in the session.
    test "session cookie does not grow with company settings", %{conn: conn, comp: comp} do
      Sys.update_company_settings(
        comp,
        "cash_forecast_exclude_accounts",
        for(_ <- 1..8, do: Ecto.UUID.generate())
      )

      Sys.update_company_settings(
        comp,
        "pl_forecast_exclude_accounts",
        for(_ <- 1..8, do: Ecto.UUID.generate())
      )

      Sys.update_company_settings(comp, "llm", %{
        "llm-provider" => "anthropic",
        "llm-endpoint" => "https://api.anthropic.com/v1/messages",
        "llm-model" => "claude-sonnet-5",
        "llm-api-key" => String.duplicate("k", 108)
      })

      conn = get(conn, ~p"/companies/#{comp.id}/dashboard")
      assert html_response(conn, 200) =~ comp.name

      cookie =
        conn
        |> get_resp_header("set-cookie")
        |> Enum.find(&String.starts_with?(&1, "_full_circle_key="))

      assert byte_size(cookie) < 1024,
             "session cookie is #{byte_size(cookie)} bytes - it carries company.settings"
    end

    # Every production session in flight at deploy time holds the old struct.
    test "a session written by the previous release is honoured, then shrunk", %{
      conn: conn,
      comp: comp
    } do
      Sys.update_company_settings(
        comp,
        "pl_forecast_exclude_accounts",
        for(_ <- 1..8, do: Ecto.UUID.generate())
      )

      comp = Sys.get_company!(comp.id)

      conn = conn |> Plug.Test.init_test_session(%{}) |> put_session(:current_company, comp)

      # Honoured: a page with no :company_id in the path still knows the company.
      conn = get(conn, ~p"/companies")
      assert html_response(conn, 200) =~ comp.name

      # Shrunk: the next company-scoped request replaces the struct with the id.
      conn = get(conn, ~p"/companies/#{comp.id}/dashboard")
      assert html_response(conn, 200) =~ comp.name
      assert get_session(conn, "current_company") == nil
      assert get_session(conn, "current_company_id") == comp.id
    end

    test "current_company is read fresh, not from a session snapshot", %{conn: conn, comp: comp} do
      conn = get(conn, ~p"/companies/#{comp.id}/dashboard")
      assert html_response(conn, 200) =~ comp.name

      {:ok, renamed} =
        comp
        |> Ecto.Changeset.change(%{name: "Renamed After Session Started"})
        |> FullCircle.Repo.update()

      conn = get(conn, ~p"/companies/#{comp.id}/dashboard")
      assert html_response(conn, 200) =~ renamed.name
    end
  end
end
