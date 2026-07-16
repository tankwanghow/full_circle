defmodule FullCircleWeb.StatutoryBundleLiveTest do
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

  test "valid bundle upload shows diff rows and Apply persists", %{conn: conn, com: com} do
    bundle = FullCircle.StatutoryConfig.template_bundle()

    bundle =
      put_in(
        bundle,
        ["calcs"],
        bundle["calcs"] ++
          [
            %{
              "code" => "hrdf_levy",
              "name" => "HRDF Levy",
              "effective_from" => "2026-01-01",
              "script" => "result = 1"
            }
          ]
      )

    {:ok, lv, _html} = live(conn, ~p"/companies/#{com.id}/statutory_bundle/import")

    upload =
      file_input(lv, "#bundle-upload-form", :bundle, [
        %{name: "bundle.json", content: Jason.encode!(bundle), type: "application/json"}
      ])

    html = render_upload(upload, "bundle.json")
    assert html =~ "hrdf_levy"
    assert html =~ "new"

    before = length(FullCircle.StatutoryConfig.calc_codes(com.id))

    html = render_click(lv, "apply")
    assert html =~ "Imported" or html =~ "Back to Calcs"
    assert length(FullCircle.StatutoryConfig.calc_codes(com.id)) == before + 1
  end

  test "invalid bundle with cycle shows error and no Apply", %{conn: conn, com: com} do
    bundle = FullCircle.StatutoryConfig.template_bundle()

    bundle =
      put_in(
        bundle,
        ["calcs"],
        [
          %{
            "code" => "cycle_a",
            "name" => "A",
            "effective_from" => "2026-01-01",
            "script" => ~s|result = calc("cycle_b")|
          },
          %{
            "code" => "cycle_b",
            "name" => "B",
            "effective_from" => "2026-01-01",
            "script" => ~s|result = calc("cycle_a")|
          }
        ]
      )

    {:ok, lv, _html} = live(conn, ~p"/companies/#{com.id}/statutory_bundle/import")

    upload =
      file_input(lv, "#bundle-upload-form", :bundle, [
        %{name: "bad.json", content: Jason.encode!(bundle), type: "application/json"}
      ])

    html = render_upload(upload, "bad.json")
    assert html =~ "cycle"
    refute html =~ "Apply"
  end

  test "unchanged template bundle shows all unchanged and Apply disabled", %{conn: conn, com: com} do
    bundle = FullCircle.StatutoryConfig.template_bundle()
    {:ok, lv, _html} = live(conn, ~p"/companies/#{com.id}/statutory_bundle/import")

    upload =
      file_input(lv, "#bundle-upload-form", :bundle, [
        %{name: "same.json", content: Jason.encode!(bundle), type: "application/json"}
      ])

    html = render_upload(upload, "same.json")
    assert html =~ "unchanged"

    assert has_element?(lv, "button[disabled]", "Apply")
  end
end
