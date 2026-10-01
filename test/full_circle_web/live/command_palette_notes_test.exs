defmodule FullCircleWeb.CommandPaletteNotesTest do
  use FullCircleWeb.ConnCase
  import Phoenix.LiveViewTest
  import FullCircle.SysFixtures
  import FullCircle.UserAccountsFixtures
  import FullCircle.NotesFixtures

  setup %{conn: conn} do
    user = user_fixture()
    company = company_fixture(user, %{})
    %{conn: log_in_user(conn, user), user: user, company: company}
  end

  defp open_and_search(lv, terms) do
    lv |> element("#command-palette") |> render_hook("open", %{})
    lv |> form("#command-palette form", %{"terms" => terms}) |> render_change()
  end

  test "note prefix lists notes under a Notes section and opens the note", %{
    conn: conn,
    user: user,
    company: company
  } do
    note = note_fixture(company, user, %{"body" => "weighbridge calibration due"})

    {:ok, lv, _} = live(conn, ~p"/companies/#{company.id}/dashboard")
    html = open_and_search(lv, "note weighbridge")

    assert html =~ "Notes"
    assert html =~ "weighbridge calibration due"
    assert html =~ "Search notes for “weighbridge”"

    lv |> element("#command-palette-hit-0") |> render_click()
    assert_redirect(lv, ~p"/companies/#{company.id}/notes/#{note.id}")
  end

  test "ordinary search offers the Notes page search as its last row", %{
    conn: conn,
    company: company
  } do
    {:ok, lv, _} = live(conn, ~p"/companies/#{company.id}/dashboard")
    html = open_and_search(lv, "swee lee")

    assert html =~ "Search notes for “swee lee”"
  end
end
