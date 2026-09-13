defmodule FullCircleWeb.PunchIngestLogPhotoControllerTest do
  use FullCircleWeb.ConnCase, async: false

  alias FullCircle.PunchGate
  alias FullCircle.PunchGate.PunchIngestLog
  alias FullCircle.Repo

  import FullCircle.UserAccountsFixtures
  import FullCircle.SysFixtures
  import FullCircle.HRFixtures

  setup %{conn: conn} do
    admin = user_fixture()
    company = company_fixture(admin, %{})
    emp = employee_fixture(%{}, company, admin)
    {:ok, {device, _}} = PunchGate.create_device("Gate 1", company, admin)

    jpeg = Path.join(System.tmp_dir!(), "face-#{System.unique_integer([:positive])}.jpg")

    File.write!(
      jpeg,
      Base.decode64!(
        "/9j/4AAQSkZJRgABAQEASABIAAD/2wBDAP//////////////////////////////////////////////////////////////////////////////////////wgALCAABAAEBAREA/8QAFBABAAAAAAAAAAAAAAAAAAAAAP/aAAgBAQABPxA="
      )
    )

    photo = %Plug.Upload{path: jpeg, filename: "face.jpg", content_type: "image/jpeg"}

    # An unknown badge always stores a log JPEG.
    {:error, :not_found} =
      PunchGate.ingest_punch(device, %{
        "employee_id" => Ecto.UUID.generate(),
        "punched_at" => DateTime.utc_now() |> DateTime.truncate(:second),
        "client_id" => Ecto.UUID.generate(),
        "photo" => photo
      })

    log = Repo.one(PunchIngestLog)
    assert log.photo_path

    %{
      conn: log_in_user(conn, admin) |> put_session(:current_company, company),
      company: company,
      admin: admin,
      emp: emp,
      log: log
    }
  end

  defp member(company, role, admin) do
    user = user_fixture()
    {:ok, _} = FullCircle.Sys.allow_user_to_access(company, user, role, admin)
    user
  end

  # ctx.conn carries put_session(:current_company, company) for the SAME company
  # as the URL — the production path, and the one where set_active_company/2
  # assigns nothing. Do not drop that line to make a test pass.
  test "200 JPEG for an admin whose session already holds this company", ctx do
    conn = get(ctx.conn, ~p"/companies/#{ctx.company.id}/punch_ingest_logs/#{ctx.log.id}/photo")
    assert conn.status == 200
    assert get_resp_header(conn, "content-type") |> hd() =~ "image/jpeg"
  end

  test "200 for a clerk with no company in the session", %{
    company: company,
    admin: admin,
    log: log
  } do
    conn =
      build_conn()
      |> log_in_user(member(company, "clerk", admin))
      |> get(~p"/companies/#{company.id}/punch_ingest_logs/#{log.id}/photo")

    assert conn.status == 200
  end

  test "200 for a clerk whose session already holds this company", %{
    company: company,
    admin: admin,
    log: log
  } do
    conn =
      build_conn()
      |> log_in_user(member(company, "clerk", admin))
      |> put_session(:current_company, company)
      |> get(~p"/companies/#{company.id}/punch_ingest_logs/#{log.id}/photo")

    assert conn.status == 200
  end

  # A stale session is the only way past the plug: it skips its membership check
  # whenever the session company matches the URL, so access revoked after login
  # reaches the controller. That is the gap this 404 closes. (A non-member with
  # no such session is redirected by the plug with a 302 and never gets here.)
  test "404 for a stale session whose user is no longer a member", %{company: company, log: log} do
    conn =
      build_conn()
      |> log_in_user(user_fixture())
      |> put_session(:current_company, company)
      |> get(~p"/companies/#{company.id}/punch_ingest_logs/#{log.id}/photo")

    assert conn.status == 404
  end

  test "403 for a logged-in cashier, never an HTML redirect", %{
    company: company,
    admin: admin,
    log: log
  } do
    conn =
      build_conn()
      |> log_in_user(member(company, "cashier", admin))
      |> get(~p"/companies/#{company.id}/punch_ingest_logs/#{log.id}/photo")

    assert conn.status == 403
    refute conn.resp_body =~ "<html"
  end

  test "302 to login when logged out", %{company: company, log: log} do
    conn = build_conn() |> get(~p"/companies/#{company.id}/punch_ingest_logs/#{log.id}/photo")
    assert conn.status == 302
  end

  test "404 for a log id that is not in this company", ctx do
    other_admin = user_fixture()
    other = company_fixture(other_admin, %{})
    {:ok, _} = FullCircle.Sys.allow_user_to_access(other, ctx.admin, "admin", other_admin)

    conn = get(ctx.conn, ~p"/companies/#{other.id}/punch_ingest_logs/#{ctx.log.id}/photo")
    assert conn.status == 404
  end

  test "404 when the file is gone", ctx do
    Path.join(Application.get_env(:full_circle, :uploads_dir), ctx.log.photo_path) |> File.rm!()

    conn = get(ctx.conn, ~p"/companies/#{ctx.company.id}/punch_ingest_logs/#{ctx.log.id}/photo")
    assert conn.status == 404
  end

  test "404 when the row has no photo_path", ctx do
    log = ctx.log |> Ecto.Changeset.change(%{photo_path: nil}) |> Repo.update!()

    conn = get(ctx.conn, ~p"/companies/#{ctx.company.id}/punch_ingest_logs/#{log.id}/photo")
    assert conn.status == 404
  end
end
