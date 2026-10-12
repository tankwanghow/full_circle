defmodule FullCircleWeb.BankSetupLiveTest do
  use FullCircleWeb.ConnCase

  import Phoenix.LiveViewTest
  import FullCircle.SysFixtures
  import FullCircle.UserAccountsFixtures
  import FullCircle.BankPaymentFixtures

  setup %{conn: conn} do
    admin = user_fixture()
    com = company_fixture(admin, %{})
    %{conn: log_in_user(conn, admin), admin: admin, com: com}
  end

  test "load a template and save it as a format", %{conn: conn, com: com} do
    {:ok, lv, _} = live(conn, ~p"/companies/#{com.id}/bank_file_formats/new")

    lv
    |> form("#format-form", %{"file_format" => %{"template" => "rhb_bulk_pay"}})
    |> render_change()

    assert lv |> element("#load-template") |> render_click() =~ "hash_part"

    lv |> form("#format-form") |> render_submit()
    {:ok, _, html} = live(conn, ~p"/companies/#{com.id}/bank_file_formats")
    assert html =~ "rhb_bulk_pay"
  end

  test "create a profile and warn about what it lacks", %{conn: conn, com: com, admin: admin} do
    install_template!(com, admin, "rhb_bulk_pay")
    bank = bank_gl_account_fixture(com, admin)
    {:ok, lv, _} = live(conn, ~p"/companies/#{com.id}/bank_payment_profiles/new")

    lv
    |> form("#profile-form", %{
      "profile" => %{
        "account_id" => bank.id,
        "format_code" => "rhb_bulk_pay",
        "our_account_no" => "21234500012345",
        "start_date" => "2026-10-01",
        "params_text" => "corporate_id=123456"
      }
    })
    |> render_submit()

    {path, flash} = assert_redirect(lv)
    assert path =~ "/bank_payment_profiles"
    assert flash["warn"] =~ "corporate_name"
  end

  test "a reserved param name is refused", %{conn: conn, com: com, admin: admin} do
    bank = bank_gl_account_fixture(com, admin)
    {:ok, lv, _} = live(conn, ~p"/companies/#{com.id}/bank_payment_profiles/new")

    html =
      lv
      |> form("#profile-form", %{
        "profile" => %{
          "account_id" => bank.id,
          "format_code" => "rhb_bulk_pay",
          "our_account_no" => "21234500012345",
          "start_date" => "2026-10-01",
          "params_text" => "bank_code=PBBEMYKL"
        }
      })
      |> render_submit()

    assert html =~ "bank_code is a built-in variable name"
  end

  test "managers cannot open setup", %{com: com, admin: admin} do
    mgr = user_fixture()
    FullCircle.Sys.allow_user_to_access(com, mgr, "manager", admin)
    conn = log_in_user(build_conn(), mgr)
    assert {:error, {:live_redirect, _}} = live(conn, ~p"/companies/#{com.id}/bank_file_formats")

    assert {:error, {:live_redirect, _}} =
             live(conn, ~p"/companies/#{com.id}/bank_payment_profiles")
  end
end
