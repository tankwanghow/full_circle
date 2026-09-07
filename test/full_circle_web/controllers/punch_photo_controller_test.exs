defmodule FullCircleWeb.PunchPhotoControllerTest do
  use FullCircleWeb.ConnCase, async: false

  alias FullCircle.PunchGate
  import FullCircle.UserAccountsFixtures
  import FullCircle.SysFixtures
  import FullCircle.HRFixtures

  setup %{conn: conn} do
    admin = user_fixture()
    company = company_fixture(admin, %{})
    emp = employee_fixture(%{}, company, admin)
    {:ok, {device, _}} = PunchGate.create_device("Gate 1", company, admin)
    jpeg_path = Path.join(System.tmp_dir!(), "face-#{System.unique_integer()}.jpg")

    File.write!(
      jpeg_path,
      Base.decode64!(
        "/9j/4AAQSkZJRgABAQEASABIAAD/2wBDAP//////////////////////////////////////////////////////////////////////////////////////wgALCAABAAEBAREA/8QAFBABAAAAAAAAAAAAAAAAAAAAAP/aAAgBAQABPxA="
      )
    )

    {:ok, ta} =
      PunchGate.ingest_punch(device, %{
        "employee_id" => emp.id,
        "punched_at" => DateTime.utc_now() |> DateTime.truncate(:second),
        "client_id" => Ecto.UUID.generate(),
        "photo" => %Plug.Upload{
          path: jpeg_path,
          filename: "face.jpg",
          content_type: "image/jpeg"
        }
      })

    %{
      conn: log_in_user(conn, admin) |> put_session(:current_company, company),
      company: company,
      ta: ta,
      admin: admin
    }
  end

  test "200 for company user", %{conn: conn, company: company, ta: ta} do
    conn = get(conn, ~p"/companies/#{company.id}/TimeAttend/#{ta.id}/photo")
    assert conn.status == 200
    assert get_resp_header(conn, "content-type") |> hd() =~ "image/jpeg"
  end

  test "302 when logged out", %{company: company, ta: ta} do
    conn = build_conn() |> get(~p"/companies/#{company.id}/TimeAttend/#{ta.id}/photo")
    assert conn.status == 302
  end
end
