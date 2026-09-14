defmodule FullCircleWeb.PunchIngestLogLiveTest do
  # async: false — this file drives real ingests, which write log JPEGs into the
  # shared `uploads_dir` (System.tmp_dir!() in test). ConnCase already defaults
  # to sync; stated explicitly so nobody makes it async later.
  use FullCircleWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import FullCircle.UserAccountsFixtures
  import FullCircle.SysFixtures
  import FullCircle.HRFixtures

  alias FullCircle.PunchGate

  setup %{conn: conn} do
    admin = user_fixture()
    company = company_fixture(admin, %{})
    emp = employee_fixture(%{name: "Ali Bin Abu"}, company, admin)
    {:ok, {device, _}} = PunchGate.create_device("Gate 1", company, admin)

    jpeg = Path.join(System.tmp_dir!(), "face-#{System.unique_integer([:positive])}.jpg")

    File.write!(
      jpeg,
      Base.decode64!(
        "/9j/4AAQSkZJRgABAQEASABIAAD/2wBDAP//////////////////////////////////////////////////////////////////////////////////////wgALCAABAAEBAREA/8QAFBABAAAAAAAAAAAAAAAAAAAAAP/aAAgBAQABPxA="
      )
    )

    photo = fn -> %Plug.Upload{path: jpeg, filename: "face.jpg", content_type: "image/jpeg"} end

    {:ok, _ta} =
      PunchGate.ingest_punch(device, %{
        "employee_id" => emp.id,
        "punched_at" => DateTime.utc_now() |> DateTime.truncate(:second),
        "client_id" => Ecto.UUID.generate(),
        "photo" => photo.()
      })

    {:error, :not_found} =
      PunchGate.ingest_punch(device, %{
        "employee_id" => "junk-badge",
        "punched_at" => DateTime.utc_now() |> DateTime.truncate(:second),
        "client_id" => Ecto.UUID.generate(),
        "photo" => photo.()
      })

    %{conn: log_in_user(conn, admin), company: company, admin: admin, emp: emp}
  end

  defp member_conn(company, role, admin) do
    user = user_fixture()
    {:ok, _} = FullCircle.Sys.allow_user_to_access(company, user, role, admin)
    build_conn() |> log_in_user(user)
  end

  test "admin sees today's rows", %{conn: conn, company: company} do
    {:ok, _lv, html} = live(conn, ~p"/companies/#{company.id}/punch_ingest_logs")

    assert html =~ "Punch Ingest Log"
    assert html =~ "Ali Bin Abu"
    assert html =~ "junk-badge"
  end

  test "a clerk is allowed in", %{company: company, admin: admin} do
    {:ok, _lv, html} =
      live(member_conn(company, "clerk", admin), ~p"/companies/#{company.id}/punch_ingest_logs")

    assert html =~ "Punch Ingest Log"
  end

  test "a cashier is bounced to the dashboard", %{company: company, admin: admin} do
    assert {:error, {:live_redirect, %{to: to}}} =
             live(
               member_conn(company, "cashier", admin),
               ~p"/companies/#{company.id}/punch_ingest_logs"
             )

    assert to == "/companies/#{company.id}/dashboard"
  end

  test "outcome filter narrows the list", %{conn: conn, company: company} do
    {:ok, _lv, html} =
      live(
        conn,
        ~p"/companies/#{company.id}/punch_ingest_logs?#{[search: %{outcome: "rejected"}]}"
      )

    assert html =~ "junk-badge"
    refute html =~ "Ali Bin Abu"
  end

  test "employee search finds the raw badge", %{conn: conn, company: company} do
    {:ok, _lv, html} =
      live(
        conn,
        ~p"/companies/#{company.id}/punch_ingest_logs?#{[search: %{emp_name: "junk"}]}"
      )

    assert html =~ "junk-badge"
    refute html =~ "Ali Bin Abu"
  end

  test "a day with no rows is empty", %{conn: conn, company: company} do
    d =
      DateTime.now!(company.timezone)
      |> DateTime.to_date()
      |> Date.add(-5)
      |> Date.to_iso8601()

    {:ok, _lv, html} =
      live(
        conn,
        ~p"/companies/#{company.id}/punch_ingest_logs?#{[search: %{sdate: d, edate: d}]}"
      )

    refute html =~ "Ali Bin Abu"
    refute html =~ "junk-badge"
  end
end
