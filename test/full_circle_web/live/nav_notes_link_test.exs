defmodule FullCircleWeb.NavNotesLinkTest do
  use FullCircleWeb.ConnCase
  import Phoenix.LiveViewTest
  import FullCircle.SysFixtures
  import FullCircle.UserAccountsFixtures
  import FullCircle.NotesFixtures

  setup do
    admin = user_fixture()
    company = company_fixture(admin, %{})
    %{admin: admin, company: company}
  end

  test "nav bar links to the Notes index; the dashboard no longer has the button", %{
    conn: conn,
    admin: admin,
    company: company
  } do
    {:ok, lv, html} = live(log_in_user(conn, admin), ~p"/companies/#{company.id}/dashboard")

    assert html =~
             ~r{<a href="/companies/#{company.id}/notes"[^>]*id="full_circle_notes"}

    # Only the nav link remains — none inside the dashboard LiveView
    refute has_element?(lv, ~s{a[href="/companies/#{company.id}/notes"]})
  end

  test "roles without :view_notes get no nav link", %{admin: admin, company: company} do
    guest = user_with_role(company, admin, "guest")

    {:ok, _lv, html} =
      live(log_in_user(build_conn(), guest), ~p"/companies/#{company.id}/dashboard")

    refute html =~ ~s{id="full_circle_notes"}
  end
end
