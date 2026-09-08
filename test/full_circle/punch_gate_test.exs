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

  test "revoked gate name can be reused", %{admin: admin, company: company} do
    assert {:ok, {device, _}} = PunchGate.create_device("Gate 1", company, admin)
    assert {:ok, _} = PunchGate.revoke_device(device, company, admin)
    assert {:ok, {again, _}} = PunchGate.create_device("Gate 1", company, admin)
    assert again.name == "Gate 1"
    refute again.id == device.id
  end

  test "device name containing a pipe is rejected", %{admin: admin, company: company} do
    assert {:error, cs} = PunchGate.create_device("Gate|1", company, admin)
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
    assert is_binary(ta.photo_path)
    refute String.starts_with?(ta.photo_path, "/")
    assert String.starts_with?(ta.photo_path, "#{company.id}/punch_photos/")
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

  test "malformed employee_id is :not_found", %{admin: admin, company: company} do
    {:ok, {device, _}} = PunchGate.create_device("Gate 1", company, admin)
    attrs = ingest_attrs(%{id: "not-a-uuid"})
    assert {:error, :not_found} = PunchGate.ingest_punch(device, attrs)
  end

  test "nil photo is :missing_photo", %{admin: admin, company: company} do
    {:ok, {device, _}} = PunchGate.create_device("Gate 1", company, admin)
    emp = employee_fixture(%{}, company, admin)

    assert {:error, :missing_photo} =
             PunchGate.ingest_punch(device, ingest_attrs(emp, %{"photo" => nil}))
  end

  test "photo over 300KB is :too_large", %{admin: admin, company: company} do
    {:ok, {device, _}} = PunchGate.create_device("Gate 1", company, admin)
    emp = employee_fixture(%{}, company, admin)
    path = Path.join(System.tmp_dir!(), "big-#{System.unique_integer()}.jpg")
    File.write!(path, :binary.copy(<<0>>, 300_001))
    photo = %Plug.Upload{path: path, filename: "face.jpg", content_type: "image/jpeg"}

    assert {:error, :too_large} =
             PunchGate.ingest_punch(device, ingest_attrs(emp, %{"photo" => photo}))
  end

  test "punched_at more than 120s ahead is :future", %{admin: admin, company: company} do
    {:ok, {device, _}} = PunchGate.create_device("Gate 1", company, admin)
    emp = employee_fixture(%{}, company, admin)
    future = DateTime.utc_now() |> DateTime.add(180, :second) |> DateTime.truncate(:second)

    assert {:error, :future} =
             PunchGate.ingest_punch(device, ingest_attrs(emp, %{"punched_at" => future}))
  end

  test "garbage punched_at is :invalid", %{admin: admin, company: company} do
    {:ok, {device, _}} = PunchGate.create_device("Gate 1", company, admin)
    emp = employee_fixture(%{}, company, admin)

    assert {:error, :invalid} =
             PunchGate.ingest_punch(
               device,
               ingest_attrs(emp, %{"punched_at" => "not-a-datetime"})
             )
  end

  test "badge_payload prefixes employee id with fcqa:" do
    id = Ecto.UUID.generate()
    assert PunchGate.badge_payload(%{id: id}) == "fcqa:#{id}"
  end

  test "parse_badge_payload accepts fcqa: prefix and bare UUID" do
    id = Ecto.UUID.generate()
    assert PunchGate.parse_badge_payload("fcqa:#{id}") == {:ok, id}
    assert PunchGate.parse_badge_payload(id) == {:ok, id}
    assert PunchGate.parse_badge_payload("not-a-badge") == :error
  end

  describe "prune_photos_before/2" do
    # The gate went live in 2026-09, so nothing is older than 24 months until
    # late 2028. These tests are the only evidence this job behaves before it
    # first deletes ~125k files unattended.

    setup %{admin: admin, company: company} do
      emp = employee_fixture(%{}, company, admin)
      %{emp: emp}
    end

    defp punch_with_photo(company, emp, admin, punch_time, write_file? \\ true) do
      ta =
        FullCircle.Repo.insert!(%FullCircle.HR.TimeAttend{
          company_id: company.id,
          employee_id: emp.id,
          user_id: admin.id,
          punch_time: punch_time,
          flag: "1_IN_1",
          status: "Draft",
          input_medium: "QRGate"
        })

      abs = PunchGate.photo_abs_path(company.id, ta)
      rel = Path.relative_to(abs, Application.get_env(:full_circle, :uploads_dir))

      if write_file? do
        File.mkdir_p!(Path.dirname(abs))
        File.write!(abs, "jpegbytes")
      end

      ta = ta |> Ecto.Changeset.change(%{photo_path: rel}) |> FullCircle.Repo.update!()
      {ta, abs}
    end

    defp reload(ta), do: FullCircle.Repo.get!(FullCircle.HR.TimeAttend, ta.id)

    test "deletes the file and clears photo_path past the cutoff", ctx do
      old = DateTime.utc_now() |> DateTime.add(-800, :day) |> DateTime.truncate(:second)
      {ta, abs} = punch_with_photo(ctx.company, ctx.emp, ctx.admin, old)
      assert File.exists?(abs)

      assert {:ok, 1} = PunchGate.prune_photos_before(DateTime.utc_now())

      refute File.exists?(abs)
      assert is_nil(reload(ta).photo_path)
    end

    test "keeps photos newer than the cutoff", ctx do
      recent = DateTime.utc_now() |> DateTime.add(-10, :day) |> DateTime.truncate(:second)
      {ta, abs} = punch_with_photo(ctx.company, ctx.emp, ctx.admin, recent)

      cutoff = DateTime.utc_now() |> DateTime.add(-100, :day)
      assert {:ok, 0} = PunchGate.prune_photos_before(cutoff)

      assert File.exists?(abs)
      assert reload(ta).photo_path
    end

    test "the punch row itself survives", ctx do
      old = DateTime.utc_now() |> DateTime.add(-800, :day) |> DateTime.truncate(:second)
      {ta, _abs} = punch_with_photo(ctx.company, ctx.emp, ctx.admin, old)

      PunchGate.prune_photos_before(DateTime.utc_now())

      kept = reload(ta)
      assert kept.punch_time == ta.punch_time
      assert kept.flag == ta.flag
      assert kept.employee_id == ta.employee_id
    end

    test "an already-missing file still clears photo_path", ctx do
      old = DateTime.utc_now() |> DateTime.add(-800, :day) |> DateTime.truncate(:second)
      {ta, abs} = punch_with_photo(ctx.company, ctx.emp, ctx.admin, old, false)
      refute File.exists?(abs)

      assert {:ok, 1} = PunchGate.prune_photos_before(DateTime.utc_now())
      assert is_nil(reload(ta).photo_path)
    end

    test "dry_run reports the count but changes nothing", ctx do
      old = DateTime.utc_now() |> DateTime.add(-800, :day) |> DateTime.truncate(:second)
      {ta, abs} = punch_with_photo(ctx.company, ctx.emp, ctx.admin, old)

      assert {:ok, 1} = PunchGate.prune_photos_before(DateTime.utc_now(), dry_run: true)

      assert File.exists?(abs)
      assert reload(ta).photo_path
    end

    test "the scheduled pruner honours the configured retention window", ctx do
      prev = Application.get_env(:full_circle, :punch_photo_retention_months)
      Application.put_env(:full_circle, :punch_photo_retention_months, 1)
      on_exit(fn -> Application.put_env(:full_circle, :punch_photo_retention_months, prev) end)

      old_t = Timex.shift(DateTime.utc_now(), months: -3) |> DateTime.truncate(:second)
      recent_t = Timex.shift(DateTime.utc_now(), days: -3) |> DateTime.truncate(:second)
      {old_ta, old_abs} = punch_with_photo(ctx.company, ctx.emp, ctx.admin, old_t)
      {new_ta, new_abs} = punch_with_photo(ctx.company, ctx.emp, ctx.admin, recent_t)

      assert :ok = FullCircle.PunchGate.PhotoPruner.prune()

      refute File.exists?(old_abs)
      assert is_nil(reload(old_ta).photo_path)
      assert File.exists?(new_abs)
      assert reload(new_ta).photo_path
    end

    test "works across more rows than one batch", ctx do
      old = DateTime.utc_now() |> DateTime.add(-800, :day) |> DateTime.truncate(:second)

      pairs =
        for i <- 1..5 do
          punch_with_photo(
            ctx.company,
            ctx.emp,
            ctx.admin,
            DateTime.add(old, i, :second)
          )
        end

      assert {:ok, 5} = PunchGate.prune_photos_before(DateTime.utc_now(), batch: 2)

      for {ta, abs} <- pairs do
        refute File.exists?(abs)
        assert is_nil(reload(ta).photo_path)
      end
    end
  end
end
