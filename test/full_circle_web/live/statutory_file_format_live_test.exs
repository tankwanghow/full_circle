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

    spec =
      ~s|{"renderer":"text","line_ending":"\\r\\n","sections":[{"kind":"detail","source":"statutory_rows","fields":[{"expr":"name","width":5}]}]}|

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

  @epf_header_spec ~s|{"renderer":"text","delimiter":",","sections":[| <>
                     ~s|{"kind":"header","fields":[{"expr":"\\"Member No\\""},{"expr":"\\"Name\\""}]},| <>
                     ~s|{"kind":"detail","source":"statutory_rows","filter":"epf_employee > 0",| <>
                     ~s|"fields":[{"expr":"epf_no"},{"expr":"name"}]}]}|

  test "preview renders the unsaved spec, header only for a month without pay slips",
       %{conn: conn, com: com} do
    {:ok, lv, _html} =
      live(conn, ~p"/companies/#{com.id}/statutory_file_formats/new?code=epf_form_a")

    lv
    |> form("#object-form", %{
      "file_format" => %{"spec" => @epf_header_spec, "pay_month" => "1", "pay_year" => "2001"}
    })
    |> render_change()

    html = lv |> element("button", "Preview") |> render_click()

    refute html =~ "unknown identifier"
    assert html =~ "Member No,Name"
  end

  test "saving over an existing version asks to confirm, replace updates in place", %{
    conn: conn,
    com: com,
    admin: admin
  } do
    spec = fn width ->
      %{
        "renderer" => "text",
        "sections" => [
          %{
            "kind" => "detail",
            "source" => "statutory_rows",
            "fields" => [%{"expr" => "name", "width" => width}]
          }
        ]
      }
    end

    {:ok, _} =
      FullCircle.StatutoryConfig.save_file_format(
        %{code: "fix_txt", name: "Fix", effective_from: ~D[2026-06-01], spec: spec.(5)},
        com,
        admin
      )

    {:ok, lv, _html} = live(conn, ~p"/companies/#{com.id}/statutory_file_formats/new")

    html =
      lv
      |> form("#object-form", %{
        "file_format" => %{
          "code" => "fix_txt",
          "name" => "Fix",
          "effective_from" => "2026-06-01",
          "renderer" => "text",
          "spec" => Jason.encode!(spec.(9))
        }
      })
      |> render_submit()

    assert html =~ "already exists"

    {:ok, _lv, html} =
      lv
      |> element("#replace-version")
      |> render_click()
      |> follow_redirect(conn)

    assert html =~ "File format version replaced."

    assert %{spec: %{"sections" => [%{"fields" => [%{"width" => 9}]}]}} =
             FullCircle.StatutoryConfig.effective_file_format(com.id, "fix_txt", ~D[2026-06-30])

    assert [_only_one] =
             FullCircle.StatutoryConfig.list_versions(:file_format, com.id)
             |> Enum.filter(&(&1.code == "fix_txt"))
  end
end
