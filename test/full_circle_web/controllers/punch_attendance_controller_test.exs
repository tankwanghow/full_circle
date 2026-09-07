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

    assert %{"id" => _, "employee_name" => name, "flag" => "1_IN_1"} = json_response(conn, 201)
    assert name == emp.name
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
end
