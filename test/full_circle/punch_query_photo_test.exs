defmodule FullCircle.PunchQueryPhotoTest do
  use FullCircle.DataCase
  alias FullCircle.{HR, PunchGate}
  import FullCircle.UserAccountsFixtures
  import FullCircle.SysFixtures
  import FullCircle.HRFixtures

  test "time_list includes photo_path for QR punches" do
    admin = user_fixture()
    company = company_fixture(admin, %{})
    emp = employee_fixture(%{}, company, admin)
    {:ok, {device, _}} = PunchGate.create_device("Gate 1", company, admin)
    path = Path.join(System.tmp_dir!(), "face-#{System.unique_integer()}.jpg")

    File.write!(
      path,
      Base.decode64!(
        "/9j/4AAQSkZJRgABAQEASABIAAD/2wBDAP//////////////////////////////////////////////////////////////////////////////////////wgALCAABAAEBAREA/8QAFBABAAAAAAAAAAAAAAAAAAAAAP/aAAgBAQABPxA="
      )
    )

    {:ok, ta} =
      PunchGate.ingest_punch(device, %{
        "employee_id" => emp.id,
        "punched_at" => DateTime.utc_now() |> DateTime.truncate(:second),
        "client_id" => Ecto.UUID.generate(),
        "photo" => %Plug.Upload{path: path, filename: "f.jpg", content_type: "image/jpeg"}
      })

    day =
      ta.punch_time
      |> DateTime.shift_zone!(company.timezone)
      |> DateTime.to_date()

    row = HR.punch_query_by_id(emp.id, day, company)
    [first | _] = row.time_list
    assert length(first) >= 5
    assert Enum.at(first, 4) not in [nil, ""]
  end
end
