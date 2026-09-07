defmodule FullCircle.PunchGateTest do
  use FullCircle.DataCase

  alias FullCircle.PunchGate
  alias FullCircle.PunchGate.PunchDevice

  import FullCircle.UserAccountsFixtures
  import FullCircle.SysFixtures
  import FullCircle.HRFixtures

  setup do
    admin = user_fixture()
    company = company_fixture(admin, %{})
    %{admin: admin, company: company}
  end

  test "PunchDevice schema fields exist" do
    assert %PunchDevice{}.__struct__ == PunchDevice
    assert :name in PunchDevice.__schema__(:fields)
    assert :token_hash in PunchDevice.__schema__(:fields)
    assert :revoked_at in PunchDevice.__schema__(:fields)
  end

  test "create_device returns plaintext once and stores only the hash", %{
    admin: admin,
    company: company
  } do
    assert {:ok, {device, plain}} = PunchGate.create_device("Gate 1", company, admin)
    assert is_binary(plain) and byte_size(plain) >= 32
    assert device.token_hash == PunchGate.hash_token(plain)
    assert device.token_hash != plain
    assert device.name == "Gate 1"
    assert device.company_id == company.id
    assert device.paired_by_user_id == admin.id
    assert is_nil(device.revoked_at)
  end

  test "duplicate name in company is rejected", %{admin: admin, company: company} do
    assert {:ok, _} = PunchGate.create_device("Gate 1", company, admin)
    assert {:error, cs} = PunchGate.create_device("Gate 1", company, admin)
    assert %{name: _} = errors_on(cs)
  end

  test "revoke then lookup by token returns nil", %{admin: admin, company: company} do
    {:ok, {device, plain}} = PunchGate.create_device("Gate 1", company, admin)
    assert %PunchDevice{} = PunchGate.get_active_device_by_token(plain)
    assert {:ok, revoked} = PunchGate.revoke_device(device, company, admin)
    refute is_nil(revoked.revoked_at)
    assert is_nil(PunchGate.get_active_device_by_token(plain))
  end

  defp jpeg_upload do
    path = Path.join(System.tmp_dir!(), "face-#{System.unique_integer()}.jpg")
    # minimal JPEG (1x1)
    File.write!(
      path,
      Base.decode64!(
        "/9j/4AAQSkZJRgABAQEASABIAAD/2wBDAP//////////////////////////////////////////////////////////////////////////////////////wgALCAABAAEBAREA/8QAFBABAAAAAAAAAAAAAAAAAAAAAP/aAAgBAQABPxA="
      )
    )

    %Plug.Upload{path: path, filename: "face.jpg", content_type: "image/jpeg"}
  end

  defp ingest_attrs(emp, extra \\ %{}) do
    Map.merge(
      %{
        "employee_id" => emp.id,
        "punched_at" => DateTime.utc_now() |> DateTime.truncate(:second),
        "photo" => jpeg_upload(),
        "client_id" => Ecto.UUID.generate()
      },
      extra
    )
  end

  test "ingest writes QRGate row, photo file, infers 1_IN_1", %{admin: admin, company: company} do
    {:ok, {device, _}} = PunchGate.create_device("Gate 1", company, admin)
    emp = employee_fixture(%{}, company, admin)
    assert {:ok, ta} = PunchGate.ingest_punch(device, ingest_attrs(emp))
    assert ta.input_medium == "QRGate"
    assert ta.flag == "1_IN_1"
    assert ta.punch_device_id == device.id
    assert is_nil(ta.user_id)
    assert File.exists?(PunchGate.photo_abs_path(company.id, ta))
  end

  test "second punch same day is 1_OUT_1; third is 2_IN_2", %{admin: admin, company: company} do
    {:ok, {device, _}} = PunchGate.create_device("Gate 1", company, admin)
    emp = employee_fixture(%{}, company, admin)
    t0 = ~U[2026-09-06 00:10:00Z]
    assert {:ok, a} = PunchGate.ingest_punch(device, ingest_attrs(emp, %{"punched_at" => t0}))

    assert {:ok, b} =
             PunchGate.ingest_punch(
               device,
               ingest_attrs(emp, %{"punched_at" => DateTime.add(t0, 8 * 3600)})
             )

    assert {:ok, c} =
             PunchGate.ingest_punch(
               device,
               ingest_attrs(emp, %{"punched_at" => DateTime.add(t0, 9 * 3600)})
             )

    assert FullCircle.Repo.get!(FullCircle.HR.TimeAttend, a.id).flag == "1_IN_1"
    assert FullCircle.Repo.get!(FullCircle.HR.TimeAttend, b.id).flag == "1_OUT_1"
    assert FullCircle.Repo.get!(FullCircle.HR.TimeAttend, c.id).flag == "2_IN_2"
  end

  test "late punch in the middle of the day rebuilds flags", %{admin: admin, company: company} do
    {:ok, {device, _}} = PunchGate.create_device("Gate 1", company, admin)
    emp = employee_fixture(%{}, company, admin)
    t0 = ~U[2026-09-06 00:10:00Z]
    {:ok, first} = PunchGate.ingest_punch(device, ingest_attrs(emp, %{"punched_at" => t0}))

    {:ok, third} =
      PunchGate.ingest_punch(
        device,
        ingest_attrs(emp, %{"punched_at" => DateTime.add(t0, 9 * 3600)})
      )

    {:ok, second} =
      PunchGate.ingest_punch(
        device,
        ingest_attrs(emp, %{"punched_at" => DateTime.add(t0, 8 * 3600)})
      )

    assert FullCircle.Repo.get!(FullCircle.HR.TimeAttend, first.id).flag == "1_IN_1"
    assert FullCircle.Repo.get!(FullCircle.HR.TimeAttend, second.id).flag == "1_OUT_1"
    assert FullCircle.Repo.get!(FullCircle.HR.TimeAttend, third.id).flag == "2_IN_2"
  end

  test "duplicate within 3 minutes is :duplicate", %{admin: admin, company: company} do
    {:ok, {device, _}} = PunchGate.create_device("Gate 1", company, admin)
    emp = employee_fixture(%{}, company, admin)
    t0 = DateTime.utc_now() |> DateTime.truncate(:second)
    assert {:ok, _} = PunchGate.ingest_punch(device, ingest_attrs(emp, %{"punched_at" => t0}))

    assert {:error, :duplicate} =
             PunchGate.ingest_punch(
               device,
               ingest_attrs(emp, %{"punched_at" => DateTime.add(t0, 60)})
             )
  end

  test "same client_id retries return the same row", %{admin: admin, company: company} do
    {:ok, {device, _}} = PunchGate.create_device("Gate 1", company, admin)
    emp = employee_fixture(%{}, company, admin)
    attrs = ingest_attrs(emp)
    assert {:ok, a} = PunchGate.ingest_punch(device, attrs)
    assert {:ok, b} = PunchGate.ingest_punch(device, attrs)
    assert a.id == b.id
  end

  test "inactive employee is :inactive", %{admin: admin, company: company} do
    {:ok, {device, _}} = PunchGate.create_device("Gate 1", company, admin)
    emp = employee_fixture(%{status: "Resigned"}, company, admin)
    assert {:error, :inactive} = PunchGate.ingest_punch(device, ingest_attrs(emp))
  end

  test "unknown employee is :not_found", %{admin: admin, company: company} do
    {:ok, {device, _}} = PunchGate.create_device("Gate 1", company, admin)
    attrs = ingest_attrs(%{id: Ecto.UUID.generate()})
    assert {:error, :not_found} = PunchGate.ingest_punch(device, attrs)
  end
end
