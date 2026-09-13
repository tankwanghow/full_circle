defmodule FullCircle.PunchIngestLogTest do
  use FullCircle.DataCase, async: false

  alias FullCircle.PunchGate
  alias FullCircle.PunchGate.PunchIngestLog
  alias FullCircle.Repo

  import FullCircle.UserAccountsFixtures
  import FullCircle.SysFixtures

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
end
