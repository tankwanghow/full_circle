defmodule FullCircleWeb.StatutoryFileFormatLiveTest do
  use FullCircleWeb.ConnCase

  import Phoenix.LiveViewTest
  import FullCircle.SysFixtures
  import FullCircle.UserAccountsFixtures

  setup %{conn: conn} do
    admin = user_fixture()
    com = company_fixture(admin, %{})
    FullCircle.StatutoryConfig.seed_company!(com.id)
    %{conn: log_in_user(conn, admin), admin: admin, com: com}
  end

  test "index lists seeded file formats", %{conn: conn, com: com} do
    {:ok, _lv, html} = live(conn, ~p"/companies/#{com.id}/statutory_file_formats")
    assert html =~ "socso_txt"
    assert html =~ "pcb_cp39"
  end

  test "form saves a new version visible in index", %{conn: conn, com: com} do
    {:ok, lv, _html} = live(conn, ~p"/companies/#{com.id}/statutory_file_formats/new")

    spec = ~s|{"renderer":"text","line_ending":"\\r\\n","sections":[{"kind":"detail","source":"statutory_rows","fields":[{"expr":"name","width":5}]}]}|

    assert lv
           |> form("#object-form", %{
             "file_format" => %{
               "code" => "custom_txt",
               "name" => "Custom",
               "effective_from" => "2026-07-01",
               "renderer" => "text",
               "spec" => spec
             }
           })
           |> render_submit()
           |> then(fn _ ->
             {:ok, _lv, html} = live(conn, ~p"/companies/#{com.id}/statutory_file_formats")
             assert html =~ "custom_txt"
           end)
  end

  test "invalid spec shows validation error", %{conn: conn, com: com} do
    {:ok, lv, _html} = live(conn, ~p"/companies/#{com.id}/statutory_file_formats/new")

    html =
      lv
      |> form("#object-form", %{
        "file_format" => %{
          "code" => "bad_txt",
          "name" => "Bad",
          "effective_from" => "2026-07-01",
          "renderer" => "text",
          "spec" => ~s|{"renderer":"text","sections":[]}|
        }
      })
      |> render_submit()

    assert html =~ "sections"
  end
end