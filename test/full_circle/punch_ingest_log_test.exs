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
end
