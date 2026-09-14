defmodule FullCircle.PunchIngestLogTest do
  use FullCircle.DataCase, async: false

  alias FullCircle.PunchGate
  alias FullCircle.PunchGate.PunchIngestLog
  alias FullCircle.HR.TimeAttend
  alias FullCircle.Repo

  import FullCircle.UserAccountsFixtures
  import FullCircle.SysFixtures
  import FullCircle.HRFixtures

  setup do
    admin = user_fixture()
    company = company_fixture(admin, %{})
    {:ok, {device, token}} = PunchGate.create_device("Gate 1", company, admin)
    %{admin: admin, company: company, device: device, token: token}
  end

  defp base_attrs(ctx, extra \\ %{}) do
    Map.merge(
      %{
        company_id: ctx.company.id,
        punch_device_id: ctx.device.id,
        employee_id_raw: "whatever",
        outcome: "accepted",
        reason: nil,
        http_status: 201
      },
      extra
    )
  end

  describe "PunchIngestLog schema" do
    test "inserts an accepted row", ctx do
      assert {:ok, log} =
               %PunchIngestLog{}
               |> PunchIngestLog.changeset(base_attrs(ctx))
               |> Repo.insert()

      assert log.outcome == "accepted"
      assert is_nil(log.reason)
      assert %DateTime{} = log.inserted_at
      refute Map.has_key?(log, :updated_at)
    end

    test "rejects an unknown outcome", ctx do
      # Ecto 3.13 wraps the Postgres check violation as ConstraintError
      # (the spec's Postgrex.Error path is the unwrapped adapter error).
      assert_raise Ecto.ConstraintError, ~r/punch_ingest_logs_outcome_check/, fn ->
        %PunchIngestLog{}
        |> PunchIngestLog.changeset(base_attrs(ctx, %{outcome: "exploded"}))
        |> Repo.insert()
      end
    end

    test "rejects a rejected row with no reason", ctx do
      assert_raise Ecto.ConstraintError, ~r/punch_ingest_logs_reason_presence_check/, fn ->
        %PunchIngestLog{}
        |> PunchIngestLog.changeset(
          base_attrs(ctx, %{outcome: "rejected", reason: nil, http_status: 422})
        )
        |> Repo.insert()
      end
    end

    test "rejects a non-rejected row that carries a reason", ctx do
      assert_raise Ecto.ConstraintError, ~r/punch_ingest_logs_reason_presence_check/, fn ->
        %PunchIngestLog{}
        |> PunchIngestLog.changeset(base_attrs(ctx, %{outcome: "accepted", reason: "invalid"}))
        |> Repo.insert()
      end
    end

    test "rejects an unknown reason", ctx do
      assert_raise Ecto.ConstraintError, ~r/punch_ingest_logs_reason_check/, fn ->
        %PunchIngestLog{}
        |> PunchIngestLog.changeset(
          base_attrs(ctx, %{outcome: "rejected", reason: "banana", http_status: 422})
        )
        |> Repo.insert()
      end
    end

    test "accepts an explicit id and inserted_at", ctx do
      id = Ecto.UUID.generate()
      # Microsecond literal: inserted_at is :utc_datetime_usec, and DateTime
      # equality compares the precision tuple, so ~U[...05Z] != ~U[...05.000000Z].
      at = ~U[2026-01-02 03:04:05.000000Z]

      assert {:ok, log} =
               %PunchIngestLog{}
               |> PunchIngestLog.changeset(base_attrs(ctx, %{id: id, inserted_at: at}))
               |> Repo.insert()

      assert log.id == id
      assert log.inserted_at == at
    end
  end

  describe "http_status_for/1" do
    test "maps every ingest atom the controller can produce" do
      assert PunchGate.http_status_for(:accepted) == 201
      assert PunchGate.http_status_for(:revoked) == 401
      assert PunchGate.http_status_for(:not_found) == 404
      assert PunchGate.http_status_for(:duplicate) == 409
      assert PunchGate.http_status_for(:too_large) == 413
      assert PunchGate.http_status_for(:inactive) == 422
      assert PunchGate.http_status_for(:missing_photo) == 422
      assert PunchGate.http_status_for(:future) == 422
      assert PunchGate.http_status_for(:invalid) == 422
      assert PunchGate.http_status_for(:something_new) == 422
    end
  end

  describe "log_ingest writes one row per ingest" do
    setup ctx do
      %{emp: employee_fixture(%{}, ctx.company, ctx.admin)}
    end

    defp jpeg_upload do
      path = Path.join(System.tmp_dir!(), "face-#{System.unique_integer([:positive])}.jpg")

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

    defp logs(company), do: Repo.all(from l in PunchIngestLog, where: l.company_id == ^company.id)
    defp one_log(company), do: logs(company) |> List.first()

    test "accepted", ctx do
      assert {:ok, ta} = PunchGate.ingest_punch(ctx.device, ingest_attrs(ctx.emp))

      log = one_log(ctx.company)
      assert length(logs(ctx.company)) == 1
      assert log.outcome == "accepted"
      assert is_nil(log.reason)
      assert log.http_status == 201
      assert log.time_attendence_id == ta.id
      assert log.employee_id == ctx.emp.id
      assert log.employee_id_raw == ctx.emp.id
      assert log.punch_device_id == ctx.device.id
      assert is_nil(log.photo_path)
      assert %DateTime{} = log.punched_at
      # the accepted face stays on TimeAttend, it is never copied here
      assert File.exists?(PunchGate.photo_abs_path(ctx.company.id, ta))
    end

    test "same client_id twice logs accepted then replayed, one attendance row", ctx do
      attrs = ingest_attrs(ctx.emp)
      assert {:ok, a} = PunchGate.ingest_punch(ctx.device, attrs)
      assert {:ok, b} = PunchGate.ingest_punch(ctx.device, attrs)
      assert a.id == b.id

      # Sort with the DateTime module, never bare Enum.sort_by/2: plain term
      # order compares struct keys alphabetically, so :microsecond is weighed
      # before :second and two rows either side of a second boundary come back
      # reversed.
      assert ["accepted", "replayed"] ==
               logs(ctx.company)
               |> Enum.sort_by(& &1.inserted_at, DateTime)
               |> Enum.map(& &1.outcome)

      replay = Enum.find(logs(ctx.company), &(&1.outcome == "replayed"))
      assert replay.time_attendence_id == a.id
      assert replay.http_status == 201
      assert is_nil(replay.reason)
    end

    test "the unique-index race replays too, not rejects", ctx do
      # The test above hits the existing_client short-circuit, which always
      # wins once the row is visible — it does NOT cover the race.
      # Drive resolve_client_conflict/4 with a real unique-constraint changeset.
      attrs = ingest_attrs(ctx.emp)
      assert {:ok, ta} = PunchGate.ingest_punch(ctx.device, attrs)

      {:error, cs} =
        %TimeAttend{}
        |> TimeAttend.changeset_gate(%{
          employee_id: ctx.emp.id,
          company_id: ctx.company.id,
          punch_device_id: ctx.device.id,
          punch_time: DateTime.utc_now() |> DateTime.truncate(:second),
          input_medium: "QRGate",
          flag: "1_IN_1",
          status: "Draft",
          client_id: attrs["client_id"]
        })
        |> Repo.insert()

      assert {:replayed, replayed} =
               PunchGate.resolve_client_conflict(
                 cs,
                 ctx.device.id,
                 attrs["client_id"],
                 ctx.emp.id
               )

      assert replayed.id == ta.id
    end

    test "duplicate inside the 3 minute window", ctx do
      t0 = DateTime.utc_now() |> DateTime.truncate(:second)

      assert {:ok, _} =
               PunchGate.ingest_punch(ctx.device, ingest_attrs(ctx.emp, %{"punched_at" => t0}))

      assert {:error, :duplicate} =
               PunchGate.ingest_punch(
                 ctx.device,
                 ingest_attrs(ctx.emp, %{"punched_at" => DateTime.add(t0, 30, :second)})
               )

      dup = Enum.find(logs(ctx.company), &(&1.outcome == "duplicate"))
      assert dup.http_status == 409
      assert is_nil(dup.reason)
      assert dup.employee_id == ctx.emp.id
      assert is_nil(dup.time_attendence_id)
    end

    test "unknown badge", ctx do
      attrs = ingest_attrs(ctx.emp, %{"employee_id" => Ecto.UUID.generate()})
      assert {:error, :not_found} = PunchGate.ingest_punch(ctx.device, attrs)

      log = one_log(ctx.company)
      assert log.outcome == "rejected"
      assert log.reason == "not_found"
      assert log.http_status == 404
      assert is_nil(log.employee_id)
      assert log.employee_id_raw == attrs["employee_id"]
    end

    test "non-uuid badge", ctx do
      assert {:error, :not_found} =
               PunchGate.ingest_punch(
                 ctx.device,
                 ingest_attrs(ctx.emp, %{"employee_id" => "fcqa:nope"})
               )

      log = one_log(ctx.company)
      assert log.reason == "not_found"
      assert log.employee_id_raw == "fcqa:nope"
    end

    test "inactive employee keeps the resolved employee_id", ctx do
      emp = employee_fixture(%{status: "Resigned"}, ctx.company, ctx.admin)
      assert {:error, :inactive} = PunchGate.ingest_punch(ctx.device, ingest_attrs(emp))

      log = one_log(ctx.company)
      assert log.reason == "inactive"
      assert log.http_status == 422
      assert log.employee_id == emp.id
    end

    test "missing photo", ctx do
      assert {:error, :missing_photo} =
               PunchGate.ingest_punch(ctx.device, ingest_attrs(ctx.emp, %{"photo" => nil}))

      log = one_log(ctx.company)
      assert log.reason == "missing_photo"
      assert log.http_status == 422
      assert is_nil(log.photo_path)
      assert is_nil(log.employee_id)
    end

    test "too large photo", ctx do
      path = Path.join(System.tmp_dir!(), "big-#{System.unique_integer([:positive])}.jpg")
      File.write!(path, :binary.copy("x", 400_000))
      photo = %Plug.Upload{path: path, filename: "big.jpg", content_type: "image/jpeg"}

      assert {:error, :too_large} =
               PunchGate.ingest_punch(ctx.device, ingest_attrs(ctx.emp, %{"photo" => photo}))

      log = one_log(ctx.company)
      assert log.reason == "too_large"
      assert log.http_status == 413
      assert is_nil(log.photo_path)
    end

    test "future punch time", ctx do
      future = DateTime.utc_now() |> DateTime.add(600, :second) |> DateTime.truncate(:second)

      assert {:error, :future} =
               PunchGate.ingest_punch(
                 ctx.device,
                 ingest_attrs(ctx.emp, %{"punched_at" => future})
               )

      log = one_log(ctx.company)
      assert log.reason == "future"
      assert log.http_status == 422
      assert log.punched_at == future
    end

    # The two halves of :invalid. Same atom on the wire, different rows: one was
    # decided before the employee lookup ever ran, the other after it succeeded.
    test "unparseable punch time logs invalid with a nil punched_at and no employee", ctx do
      assert {:error, :invalid} =
               PunchGate.ingest_punch(
                 ctx.device,
                 ingest_attrs(ctx.emp, %{"punched_at" => "not-a-time"})
               )

      log = one_log(ctx.company)
      assert log.reason == "invalid"
      assert is_nil(log.punched_at)
      # The badge was valid, but the `with` never reached the lookup. Do not
      # "improve" this by re-resolving employee_id_raw for every :invalid.
      assert is_nil(log.employee_id)
      assert log.employee_id_raw == ctx.emp.id
    end

    test "an insert failure logs invalid and still names the employee", ctx do
      # changeset_gate/2 requires client_id, so omitting it resolves and
      # activates the employee and then fails the changeset — the only way to
      # reach :invalid with an employee in hand, and the row a clerk needs.
      assert {:error, :invalid} =
               PunchGate.ingest_punch(ctx.device, ingest_attrs(ctx.emp, %{"client_id" => nil}))

      log = one_log(ctx.company)
      assert log.outcome == "rejected"
      assert log.reason == "invalid"
      assert log.http_status == 422
      assert log.employee_id == ctx.emp.id
      assert is_nil(log.time_attendence_id)
      assert Repo.aggregate(TimeAttend, :count) == 0
    end

    test "an over-long employee_id still produces a row, truncated", ctx do
      long = String.duplicate("a", 400)

      assert {:error, :not_found} =
               PunchGate.ingest_punch(ctx.device, ingest_attrs(ctx.emp, %{"employee_id" => long}))

      log = one_log(ctx.company)
      assert log.reason == "not_found"
      assert String.length(log.employee_id_raw) == 64
    end

    test "an over-long client_id still produces a row, truncated", ctx do
      # 200, not 400: time_attendences.client_id is varchar(255) and
      # changeset_gate/2 has no length check, so 400 raises Postgrex.Error
      # inside the punch transaction itself — a different, pre-existing bug.
      long = String.duplicate("c", 200)

      assert {:ok, _} =
               PunchGate.ingest_punch(ctx.device, ingest_attrs(ctx.emp, %{"client_id" => long}))

      log = one_log(ctx.company)
      assert String.length(log.client_id) == 64
    end
  end

  describe "log JPEG" do
    setup ctx do
      %{emp: employee_fixture(%{}, ctx.company, ctx.admin)}
    end

    defp log_abs(log),
      do: Path.join(Application.get_env(:full_circle, :uploads_dir), log.photo_path)

    test "duplicate stores a file", ctx do
      t0 = DateTime.utc_now() |> DateTime.truncate(:second)

      assert {:ok, _} =
               PunchGate.ingest_punch(ctx.device, ingest_attrs(ctx.emp, %{"punched_at" => t0}))

      assert {:error, :duplicate} =
               PunchGate.ingest_punch(
                 ctx.device,
                 ingest_attrs(ctx.emp, %{"punched_at" => DateTime.add(t0, 30, :second)})
               )

      dup = Enum.find(logs(ctx.company), &(&1.outcome == "duplicate"))
      assert is_binary(dup.photo_path)
      refute String.starts_with?(dup.photo_path, "/")
      assert dup.photo_path =~ "punch_ingest_logs"
      assert dup.photo_path =~ "#{dup.id}.jpg"
      assert File.exists?(log_abs(dup))

      assert File.exists?(
               PunchGate.ingest_log_photo_abs_path(ctx.company.id, dup.id, dup.inserted_at)
             )
    end

    test "not_found stores a file", ctx do
      assert {:error, :not_found} =
               PunchGate.ingest_punch(
                 ctx.device,
                 ingest_attrs(ctx.emp, %{"employee_id" => Ecto.UUID.generate()})
               )

      log = one_log(ctx.company)
      assert File.exists?(log_abs(log))
    end

    test "inactive stores a file", ctx do
      emp = employee_fixture(%{status: "Resigned"}, ctx.company, ctx.admin)
      assert {:error, :inactive} = PunchGate.ingest_punch(ctx.device, ingest_attrs(emp))
      assert File.exists?(log_abs(one_log(ctx.company)))
    end

    test "future stores a file", ctx do
      future = DateTime.utc_now() |> DateTime.add(600, :second) |> DateTime.truncate(:second)

      assert {:error, :future} =
               PunchGate.ingest_punch(
                 ctx.device,
                 ingest_attrs(ctx.emp, %{"punched_at" => future})
               )

      assert File.exists?(log_abs(one_log(ctx.company)))
    end

    test "invalid timestamp stores a file", ctx do
      assert {:error, :invalid} =
               PunchGate.ingest_punch(
                 ctx.device,
                 ingest_attrs(ctx.emp, %{"punched_at" => "nope"})
               )

      assert File.exists?(log_abs(one_log(ctx.company)))
    end

    test "accepted stores no log file and leaves the TimeAttend photo alone", ctx do
      assert {:ok, ta} = PunchGate.ingest_punch(ctx.device, ingest_attrs(ctx.emp))
      log = one_log(ctx.company)
      assert is_nil(log.photo_path)
      assert File.exists?(PunchGate.photo_abs_path(ctx.company.id, ta))
    end

    test "missing_photo and too_large store no file", ctx do
      assert {:error, :missing_photo} =
               PunchGate.ingest_punch(ctx.device, ingest_attrs(ctx.emp, %{"photo" => nil}))

      assert is_nil(one_log(ctx.company).photo_path)

      big = Path.join(System.tmp_dir!(), "big-#{System.unique_integer([:positive])}.jpg")
      File.write!(big, :binary.copy("x", 400_000))
      too_big = %Plug.Upload{path: big, filename: "big.jpg", content_type: "image/jpeg"}

      assert {:error, :too_large} =
               PunchGate.ingest_punch(ctx.device, ingest_attrs(ctx.emp, %{"photo" => too_big}))

      assert length(logs(ctx.company)) == 2
      assert Enum.all?(logs(ctx.company), &is_nil(&1.photo_path))
    end

    test "a failing photo copy still leaves the row and the original result", ctx do
      original = Application.get_env(:full_circle, :uploads_dir)
      # A regular file where a directory has to be, so File.mkdir_p! raises.
      blocker = Path.join(System.tmp_dir!(), "blocker-#{System.unique_integer([:positive])}")
      File.write!(blocker, "not a directory")
      Application.put_env(:full_circle, :uploads_dir, blocker)
      on_exit(fn -> Application.put_env(:full_circle, :uploads_dir, original) end)

      # A rejected outcome, so the punch itself never writes a TimeAttend photo
      # and the only file operation in play is the log's.
      assert {:error, :not_found} =
               PunchGate.ingest_punch(
                 ctx.device,
                 ingest_attrs(ctx.emp, %{"employee_id" => Ecto.UUID.generate()})
               )

      log = one_log(ctx.company)
      assert log.reason == "not_found"
      assert is_nil(log.photo_path)
    end

    test "an invalid log changeset comes back as a tuple, not a raise", ctx do
      # Why insert_ingest_log/1 must `case` on the result instead of leaning on
      # the rescue: Repo.insert answers a failed changeset with {:error, cs}.
      assert {:error, %Ecto.Changeset{}} =
               %PunchIngestLog{}
               |> PunchIngestLog.changeset(%{outcome: "accepted", http_status: 201})
               |> Repo.insert()

      assert logs(ctx.company) == []
    end

    test "a raised log insert still leaves the punch result untouched", ctx do
      # Delete the device row but keep the struct in hand: punch_ingest_logs
      # .punch_device_id then violates its FK, which Repo.insert *raises*
      # (no constraint is declared on the changeset). A rejected outcome is used
      # so the punch itself never touches time_attendences.
      Repo.delete!(ctx.device)

      assert {:error, :not_found} =
               PunchGate.ingest_punch(
                 ctx.device,
                 ingest_attrs(ctx.emp, %{"employee_id" => Ecto.UUID.generate()})
               )

      assert logs(ctx.company) == []
    end
  end

  describe "authenticate_device/1" do
    test "active, revoked, and unknown tokens", ctx do
      assert {:ok, %FullCircle.PunchGate.PunchDevice{}} = PunchGate.authenticate_device(ctx.token)
      assert :error = PunchGate.authenticate_device("garbage")

      {:ok, _} = PunchGate.revoke_device(ctx.device, ctx.company, ctx.admin)
      assert {:revoked, device} = PunchGate.authenticate_device(ctx.token)
      assert device.id == ctx.device.id
      assert device.company.id == ctx.company.id
    end

    test "get_active_device_by_token/1 is unchanged", ctx do
      assert %FullCircle.PunchGate.PunchDevice{} = PunchGate.get_active_device_by_token(ctx.token)
      {:ok, _} = PunchGate.revoke_device(ctx.device, ctx.company, ctx.admin)
      assert is_nil(PunchGate.get_active_device_by_token(ctx.token))
    end
  end

  describe "log_revoked_attempt/2" do
    setup ctx do
      %{emp: employee_fixture(%{}, ctx.company, ctx.admin)}
    end

    test "logs a 401 row with the employee resolved and no photo", ctx do
      {:ok, _} = PunchGate.revoke_device(ctx.device, ctx.company, ctx.admin)
      {:revoked, device} = PunchGate.authenticate_device(ctx.token)
      punched = DateTime.utc_now() |> DateTime.truncate(:second)

      assert :ok =
               PunchGate.log_revoked_attempt(device, %{
                 "employee_id" => ctx.emp.id,
                 "client_id" => "abc123",
                 "punched_at" => DateTime.to_iso8601(punched)
               })

      log = one_log(ctx.company)
      assert log.outcome == "rejected"
      assert log.reason == "revoked"
      assert log.http_status == 401
      assert log.punch_device_id == ctx.device.id
      assert log.employee_id == ctx.emp.id
      assert log.employee_id_raw == ctx.emp.id
      assert log.client_id == "abc123"
      assert log.punched_at == punched
      assert is_nil(log.photo_path)
      assert is_nil(log.time_attendence_id)
    end

    test "an unresolvable badge still logs, with employee_id nil", ctx do
      {:ok, _} = PunchGate.revoke_device(ctx.device, ctx.company, ctx.admin)
      {:revoked, device} = PunchGate.authenticate_device(ctx.token)

      assert :ok = PunchGate.log_revoked_attempt(device, %{"employee_id" => "junk"})

      log = one_log(ctx.company)
      assert log.reason == "revoked"
      assert is_nil(log.employee_id)
      assert log.employee_id_raw == "junk"
      assert is_nil(log.punched_at)
    end

    test "a param shape that raises still answers :ok and writes nothing", ctx do
      # Raw multipart: a repeated or nested field makes this a map, and
      # to_string/1 raises on it. The plug must still send its plain 401.
      {:ok, _} = PunchGate.revoke_device(ctx.device, ctx.company, ctx.admin)
      {:revoked, device} = PunchGate.authenticate_device(ctx.token)

      assert :ok = PunchGate.log_revoked_attempt(device, %{"employee_id" => %{"nested" => "1"}})
      assert logs(ctx.company) == []
    end
  end

  describe "prune_ingest_logs_before/2" do
    setup ctx do
      %{emp: employee_fixture(%{}, ctx.company, ctx.admin)}
    end

    defp log_with_photo(ctx, inserted_at, write_file? \\ true) do
      id = Ecto.UUID.generate()
      abs = PunchGate.ingest_log_photo_abs_path(ctx.company.id, id, inserted_at)
      rel = Path.relative_to(abs, Application.get_env(:full_circle, :uploads_dir))

      if write_file? do
        File.mkdir_p!(Path.dirname(abs))
        File.write!(abs, "jpegbytes")
      end

      {:ok, log} =
        %PunchIngestLog{}
        |> PunchIngestLog.changeset(%{
          id: id,
          inserted_at: inserted_at,
          company_id: ctx.company.id,
          punch_device_id: ctx.device.id,
          employee_id: ctx.emp.id,
          employee_id_raw: ctx.emp.id,
          outcome: "duplicate",
          http_status: 409,
          photo_path: rel
        })
        |> Repo.insert()

      {log, abs}
    end

    test "deletes the row and its file past the cutoff", ctx do
      old = DateTime.utc_now() |> DateTime.add(-120, :day) |> DateTime.truncate(:second)
      {log, abs} = log_with_photo(ctx, old)
      assert File.exists?(abs)

      assert {:ok, 1} = PunchGate.prune_ingest_logs_before(DateTime.utc_now())

      refute File.exists?(abs)
      refute Repo.get(PunchIngestLog, log.id)
    end

    test "keeps rows newer than the cutoff", ctx do
      recent = DateTime.utc_now() |> DateTime.add(-10, :day) |> DateTime.truncate(:second)
      {log, abs} = log_with_photo(ctx, recent)

      cutoff = DateTime.utc_now() |> DateTime.add(-100, :day)
      assert {:ok, 0} = PunchGate.prune_ingest_logs_before(cutoff)

      assert File.exists?(abs)
      assert Repo.get(PunchIngestLog, log.id)
    end

    test "a missing file counts as success", ctx do
      old = DateTime.utc_now() |> DateTime.add(-120, :day) |> DateTime.truncate(:second)
      {log, _abs} = log_with_photo(ctx, old, false)

      assert {:ok, 1} = PunchGate.prune_ingest_logs_before(DateTime.utc_now())
      refute Repo.get(PunchIngestLog, log.id)
    end

    test "dry_run counts without deleting and does not loop", ctx do
      old = DateTime.utc_now() |> DateTime.add(-120, :day) |> DateTime.truncate(:second)
      for _ <- 1..3, do: log_with_photo(ctx, old)

      assert {:ok, 3} =
               PunchGate.prune_ingest_logs_before(DateTime.utc_now(), dry_run: true, batch: 2)

      assert Repo.aggregate(PunchIngestLog, :count) == 3
    end

    test "pages through more rows than one batch", ctx do
      old = DateTime.utc_now() |> DateTime.add(-120, :day) |> DateTime.truncate(:second)
      for _ <- 1..5, do: log_with_photo(ctx, old)

      assert {:ok, 5} = PunchGate.prune_ingest_logs_before(DateTime.utc_now(), batch: 2)
      assert Repo.aggregate(PunchIngestLog, :count) == 0
    end

    test "TimeAttend photos are untouched", ctx do
      assert {:ok, ta} = PunchGate.ingest_punch(ctx.device, ingest_attrs(ctx.emp))
      old = DateTime.utc_now() |> DateTime.add(-120, :day) |> DateTime.truncate(:second)
      log_with_photo(ctx, old)

      assert {:ok, 1} =
               PunchGate.prune_ingest_logs_before(DateTime.utc_now() |> DateTime.add(-1, :day))

      assert File.exists?(PunchGate.photo_abs_path(ctx.company.id, ta))
    end
  end

  describe "list_ingest_logs/3" do
    setup ctx do
      emp = employee_fixture(%{name: "Ali Bin Abu"}, ctx.company, ctx.admin)
      {:ok, _} = PunchGate.ingest_punch(ctx.device, ingest_attrs(emp))

      {:error, :not_found} =
        PunchGate.ingest_punch(ctx.device, ingest_attrs(emp, %{"employee_id" => "junk-badge"}))

      today =
        DateTime.now!(ctx.company.timezone) |> DateTime.to_date() |> Date.to_iso8601()

      %{emp: emp, today: today}
    end

    defp list(ctx, opts \\ []) do
      PunchGate.list_ingest_logs(
        ctx.company,
        ctx.admin,
        Keyword.merge([sdate: ctx.today, edate: ctx.today], opts)
      )
    end

    test "admin sees today's rows newest first", ctx do
      rows = list(ctx)
      assert length(rows) == 2
      assert hd(rows).outcome == "rejected"
      assert Enum.map(rows, & &1.device_name) == ["Gate 1", "Gate 1"]
    end

    test "a cashier gets :not_authorise", ctx do
      cashier = user_fixture()
      {:ok, _} = FullCircle.Sys.allow_user_to_access(ctx.company, cashier, "cashier", ctx.admin)

      assert :not_authorise =
               PunchGate.list_ingest_logs(ctx.company, cashier,
                 sdate: ctx.today,
                 edate: ctx.today
               )
    end

    test "a clerk is allowed", ctx do
      clerk = user_fixture()
      {:ok, _} = FullCircle.Sys.allow_user_to_access(ctx.company, clerk, "clerk", ctx.admin)

      assert is_list(
               PunchGate.list_ingest_logs(ctx.company, clerk, sdate: ctx.today, edate: ctx.today)
             )
    end

    test "outcome filter", ctx do
      assert [row] = list(ctx, outcome: "accepted")
      assert row.outcome == "accepted"
      assert row.employee_name == "Ali Bin Abu"
    end

    test "employee name search", ctx do
      assert [row] = list(ctx, emp_name: "ali")
      assert row.employee_name == "Ali Bin Abu"
    end

    test "raw badge search finds the unresolved row", ctx do
      assert [row] = list(ctx, emp_name: "junk-badge")
      assert is_nil(row.employee_name)
      assert row.employee_id_raw == "junk-badge"
    end

    test "device name search", ctx do
      assert length(list(ctx, device_name: "Gate")) == 2
      assert list(ctx, device_name: "Nowhere") == []
    end

    test "a day before today is empty", ctx do
      yesterday =
        DateTime.now!(ctx.company.timezone)
        |> DateTime.to_date()
        |> Date.add(-1)
        |> Date.to_iso8601()

      assert list(ctx, sdate: yesterday, edate: yesterday) == []
    end

    test "the range is inclusive of edate", ctx do
      yesterday =
        DateTime.now!(ctx.company.timezone)
        |> DateTime.to_date()
        |> Date.add(-1)
        |> Date.to_iso8601()

      assert length(list(ctx, sdate: yesterday, edate: ctx.today)) == 2
    end

    test "other companies are never visible", ctx do
      other_admin = user_fixture()
      other = company_fixture(other_admin, %{})

      assert PunchGate.list_ingest_logs(other, other_admin, sdate: ctx.today, edate: ctx.today) ==
               []
    end
  end
end
