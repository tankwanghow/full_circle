defmodule FullCircleWeb.PunchAttendanceControllerTest do
  use FullCircleWeb.ConnCase, async: false

  alias FullCircle.PunchGate
  import FullCircle.UserAccountsFixtures
  import FullCircle.SysFixtures
  import FullCircle.HRFixtures

  setup %{conn: conn} do
    admin = user_fixture()
    company = company_fixture(admin, %{})
    emp = employee_fixture(%{}, company, admin)
    {:ok, {device, plain}} = PunchGate.create_device("Gate 1", company, admin)
    %{conn: conn, admin: admin, company: company, emp: emp, device: device, token: plain}
  end

  defp jpeg_upload do
    path = Path.join(System.tmp_dir!(), "face-#{System.unique_integer()}.jpg")

    File.write!(
      path,
      Base.decode64!(
        "/9j/4AAQSkZJRgABAQEASABIAAD/2wBDAP//////////////////////////////////////////////////////////////////////////////////////wgALCAABAAEBAREA/8QAFBABAAAAAAAAAAAAAAAAAAAAAP/aAAgBAQABPxA="
      )
    )

    %Plug.Upload{path: path, filename: "face.jpg", content_type: "image/jpeg"}
  end

  defp auth(conn, token), do: put_req_header(conn, "authorization", "Bearer #{token}")

  test "201 creates punch", %{conn: conn, token: token, emp: emp} do
    conn =
      conn
      |> auth(token)
      |> post(~p"/api/punch/attendances", %{
        "employee_id" => emp.id,
        "punched_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
        "client_id" => Ecto.UUID.generate(),
        "photo" => jpeg_upload()
      })

    assert %{"id" => id, "employee_name" => name, "flag" => "1_IN_1"} = json_response(conn, 201)
    assert name == emp.name

    assert [log] = FullCircle.Repo.all(FullCircle.PunchGate.PunchIngestLog)
    assert log.outcome == "accepted"
    assert log.time_attendence_id == id
    assert log.http_status == 201
  end

  test "401 without token", %{conn: conn, emp: emp} do
    conn =
      post(conn, ~p"/api/punch/attendances", %{
        "employee_id" => emp.id,
        "punched_at" => DateTime.to_iso8601(DateTime.utc_now()),
        "client_id" => Ecto.UUID.generate(),
        "photo" => jpeg_upload()
      })

    assert conn.status == 401
  end

  test "401 when revoked", %{
    conn: conn,
    token: token,
    device: device,
    company: company,
    admin: admin,
    emp: emp
  } do
    {:ok, _} = PunchGate.revoke_device(device, company, admin)

    conn =
      conn
      |> auth(token)
      |> post(~p"/api/punch/attendances", %{
        "employee_id" => emp.id,
        "punched_at" => DateTime.to_iso8601(DateTime.utc_now()),
        "client_id" => Ecto.UUID.generate(),
        "photo" => jpeg_upload()
      })

    assert conn.status == 401
  end

  test "GET /api/punch/health is 204 when the device token is valid", %{
    conn: conn,
    token: token
  } do
    conn = conn |> auth(token) |> get(~p"/api/punch/health")
    assert conn.status == 204
  end

  test "GET /api/punch/health is 401 without a token", %{conn: conn} do
    conn = get(conn, ~p"/api/punch/health")
    assert conn.status == 401
  end

  test "GET /api/punch/health is 401 when revoked", %{
    conn: conn,
    token: token,
    device: device,
    company: company,
    admin: admin
  } do
    {:ok, _} = PunchGate.revoke_device(device, company, admin)
    conn = conn |> auth(token) |> get(~p"/api/punch/health")
    assert conn.status == 401
  end

  describe "revoked device" do
    test "POST still 401s and leaves one revoked log row", ctx do
      {:ok, _} = PunchGate.revoke_device(ctx.device, ctx.company, ctx.admin)

      conn =
        ctx.conn
        |> auth(ctx.token)
        |> post(~p"/api/punch/attendances", %{
          "employee_id" => ctx.emp.id,
          "punched_at" =>
            DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
          "client_id" => Ecto.UUID.generate(),
          "photo" => jpeg_upload()
        })

      assert conn.status == 401
      assert conn.resp_body == "No access for you"

      assert [log] = FullCircle.Repo.all(FullCircle.PunchGate.PunchIngestLog)
      assert log.outcome == "rejected"
      assert log.reason == "revoked"
      assert log.http_status == 401
      assert log.punch_device_id == ctx.device.id
      assert log.employee_id == ctx.emp.id
      assert is_nil(log.photo_path)
      assert FullCircle.Repo.aggregate(FullCircle.HR.TimeAttend, :count) == 0

      device = FullCircle.Repo.get!(FullCircle.PunchGate.PunchDevice, ctx.device.id)
      assert is_nil(device.last_seen_at)
    end

    test "the 20s health ping logs nothing", ctx do
      {:ok, _} = PunchGate.revoke_device(ctx.device, ctx.company, ctx.admin)

      conn = ctx.conn |> auth(ctx.token) |> get(~p"/api/punch/health")

      assert conn.status == 401
      assert FullCircle.Repo.aggregate(FullCircle.PunchGate.PunchIngestLog, :count) == 0
    end

    test "an unknown token logs nothing", ctx do
      conn =
        ctx.conn
        |> auth("not-a-real-token")
        |> post(~p"/api/punch/attendances", %{"employee_id" => Ecto.UUID.generate()})

      assert conn.status == 401
      assert FullCircle.Repo.aggregate(FullCircle.PunchGate.PunchIngestLog, :count) == 0
    end
  end
end
