# Punch Ingest Logs Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give clerks an append-only, per-company log of every gate POST the server can attribute to a device — accepted, replayed, duplicate, rejected, and revoked-device 401 — with the reject face photo, a read-only LiveView, and 3-month retention.

**Architecture:** A new `punch_ingest_logs` table written best-effort *after* `PunchGate.ingest_punch/2` has already decided the punch, so a logging failure can never change payroll or the HTTP response. `PunchDeviceAuth` gains one extra branch: a token that resolves to a *revoked* device is still attributable to a company, so its 401 gets a row too (POSTs only — the 20s health ping shares the plug). Retention is a `PhotoPruner`-shaped supervised GenServer; there is no job runner in this app.

**Tech Stack:** Elixir 1.19.5 / OTP 28.3.1, Phoenix 1.8.3, LiveView 1.1.x, Ecto + PostgreSQL, Timex, Gettext (en + zh), Tailwind 3.4.

**Spec:** `docs/superpowers/specs/2026-09-09-punch-ingest-logs-design.md`

## Global Constraints

- **Do not change the phone contract.** `POST /api/punch/attendances` and `GET /api/punch/health` keep their exact status codes and response bodies, 401 `"No access for you"` included. `PunchAttendanceControllerTest` must stay green without editing its response assertions.
- **A log failure must never change the HTTP result or roll back a punch.** Every log write is best-effort: outside the punch `Ecto.Multi`, wrapped so both `{:error, changeset}` and a raised `Postgrex.Error` are swallowed with `Logger.error`.
- **Do not use `StdInterface`** for this table — it writes CRUD `logs` and requires a `user_id`; a gate POST has no ERP user.
- **Never run bare `mix format`** — it rewrites ~14 already-unformatted files on master. Format only the files you touched: `mix format <path> <path>`.
- **Commit directly to `master`.** Solo workflow, no feature branches.
- Schemas use `use FullCircle.Schema` (binary_id PK + binary_id FKs). Migrations inherit `migration_primary_key: [name: :id, type: :binary_id]` and `migration_timestamps: [type: :timestamptz]` from `config/config.exs:39-40`, so plain `create table/2` and plain `timestamps/1` are already correct.
- Retention is **3 calendar months** via `Timex.shift(months: -3)`, never 90 days.
- Roles for viewing: `admin`, `manager`, `supervisor`, `clerk`. Not cashier, auditor, guest, disable.
- Both light and dark theme must look right in any new UI (`.dark` overrides live in `assets/css/app.css`).

---

## File Structure

**Created**

| File | Responsibility |
|---|---|
| `priv/repo/migrations/20260909120000_create_punch_ingest_logs.exs` | Table, indexes, three check constraints |
| `lib/full_circle/punch_gate/punch_ingest_log.ex` | Schema + changeset. Nothing else. |
| `lib/full_circle/punch_gate/ingest_log_pruner.ex` | Daily GenServer, mirrors `PhotoPruner` |
| `lib/full_circle_web/controllers/punch_ingest_log_photo_controller.ex` | Serves one log JPEG with a role check |
| `lib/full_circle_web/live/punch_ingest_log_live/index.ex` | Read-only list, filters, infinite scroll |
| `test/full_circle/punch_ingest_log_test.exs` | Context tests for logging + pruning |
| `test/full_circle_web/controllers/punch_ingest_log_photo_controller_test.exs` | 200 / 403 / 404 |
| `test/full_circle_web/live/punch_ingest_log_live_test.exs` | Access, default day, filters |

**Modified**

| File | Change |
|---|---|
| `lib/full_circle/punch_gate.ex` | `authenticate_device/1`, `http_status_for/1`, `log_ingest`, `log_revoked_attempt/2`, `list_ingest_logs/3`, `prune_ingest_logs_before/2`, tag replays |
| `lib/full_circle_web/plugs/punch_device_auth.ex` | Revoked branch (POSTs only) |
| `lib/full_circle_web/controllers/punch_attendance_controller.ex` | Take statuses from `http_status_for/1` |
| `lib/full_circle/authorization.ex` | `:view_punch_ingest_log` |
| `lib/full_circle/application.ex` | Start `IngestLogPruner` |
| `lib/full_circle_web/router.ex` | Live route + photo GET |
| `lib/full_circle_web/live/dashboard_live/dashboard_live.ex` | Payroll link |
| `config/config.exs`, `config/test.exs` | Retention knobs |
| `priv/gettext/{en,zh}/LC_MESSAGES/default.po` | New msgids |
| `.claude/skills/qr-gate-punch.md` | Where to look when a punch is missing |

`punch_gate.ex` is already 354 lines and this adds roughly 200 more. That is acceptable — the log write is inseparable from `ingest_punch/2`, and the codebase keeps context modules whole. Keep the schema and the pruner in their own files under `lib/full_circle/punch_gate/`, exactly as `PunchDevice` and `PhotoPruner` already are.

---

## Task 1: Table, schema, and one source of truth for HTTP status

**Files:**
- Create: `priv/repo/migrations/20260909120000_create_punch_ingest_logs.exs`
- Create: `lib/full_circle/punch_gate/punch_ingest_log.ex`
- Create: `test/full_circle/punch_ingest_log_test.exs`
- Modify: `lib/full_circle/punch_gate.ex` (add `http_status_for/1`)
- Modify: `lib/full_circle_web/controllers/punch_attendance_controller.ex:8-46`

**Interfaces:**
- Produces: `FullCircle.PunchGate.PunchIngestLog` with fields `id, company_id, punch_device_id, employee_id, employee_id_raw, time_attendence_id, client_id, punched_at, outcome, reason, http_status, photo_path, inserted_at`; `PunchIngestLog.changeset(struct, attrs)` casting **all** of those (including `:id` and `:inserted_at`, which later tasks set explicitly).
- Produces: `PunchGate.http_status_for(atom) :: integer` — `:accepted → 201`, `:revoked → 401`, `:not_found → 404`, `:duplicate → 409`, `:too_large → 413`, anything else → `422`.

- [ ] **Step 1: Write the failing test**

Create `test/full_circle/punch_ingest_log_test.exs`:

```elixir
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
      assert_raise Postgrex.Error, ~r/punch_ingest_logs_outcome_check/, fn ->
        %PunchIngestLog{}
        |> PunchIngestLog.changeset(base_attrs(ctx, %{outcome: "exploded"}))
        |> Repo.insert()
      end
    end

    test "rejects a rejected row with no reason", ctx do
      assert_raise Postgrex.Error, ~r/punch_ingest_logs_reason_presence_check/, fn ->
        %PunchIngestLog{}
        |> PunchIngestLog.changeset(
          base_attrs(ctx, %{outcome: "rejected", reason: nil, http_status: 422})
        )
        |> Repo.insert()
      end
    end

    test "rejects a non-rejected row that carries a reason", ctx do
      assert_raise Postgrex.Error, ~r/punch_ingest_logs_reason_presence_check/, fn ->
        %PunchIngestLog{}
        |> PunchIngestLog.changeset(base_attrs(ctx, %{outcome: "accepted", reason: "invalid"}))
        |> Repo.insert()
      end
    end

    test "rejects an unknown reason", ctx do
      assert_raise Postgrex.Error, ~r/punch_ingest_logs_reason_check/, fn ->
        %PunchIngestLog{}
        |> PunchIngestLog.changeset(
          base_attrs(ctx, %{outcome: "rejected", reason: "banana", http_status: 422})
        )
        |> Repo.insert()
      end
    end

    test "accepts an explicit id and inserted_at", ctx do
      id = Ecto.UUID.generate()
      at = ~U[2026-01-02 03:04:05Z]

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
```

- [ ] **Step 2: Run it and watch it fail**

Run: `mix test test/full_circle/punch_ingest_log_test.exs`
Expected: FAIL — `FullCircle.PunchGate.PunchIngestLog` is undefined.

- [ ] **Step 3: Write the migration**

Create `priv/repo/migrations/20260909120000_create_punch_ingest_logs.exs`:

```elixir
defmodule FullCircle.Repo.Migrations.CreatePunchIngestLogs do
  use Ecto.Migration

  def change do
    create table(:punch_ingest_logs) do
      add :company_id, references(:companies, on_delete: :delete_all), null: false
      add :punch_device_id, references(:punch_devices, on_delete: :nilify_all)
      add :employee_id, references(:employees, on_delete: :nilify_all)
      add :employee_id_raw, :string
      add :time_attendence_id, references(:time_attendences, on_delete: :nilify_all)
      add :client_id, :string
      add :punched_at, :timestamptz
      add :outcome, :string, null: false
      add :reason, :string
      add :http_status, :integer, null: false
      add :photo_path, :string

      timestamps(updated_at: false)
    end

    # Newest-first listing. PostgreSQL scans a btree backwards, so a plain
    # ascending index serves `order_by: [desc: inserted_at]` without a DESC index.
    create index(:punch_ingest_logs, [:company_id, :inserted_at])
    create index(:punch_ingest_logs, [:company_id, :outcome, :inserted_at])

    create constraint(:punch_ingest_logs, :punch_ingest_logs_outcome_check,
             check: "outcome IN ('accepted','replayed','duplicate','rejected')"
           )

    create constraint(:punch_ingest_logs, :punch_ingest_logs_reason_presence_check,
             check:
               "(outcome = 'rejected' AND reason IS NOT NULL) OR (outcome <> 'rejected' AND reason IS NULL)"
           )

    create constraint(:punch_ingest_logs, :punch_ingest_logs_reason_check,
             check:
               "reason IS NULL OR reason IN ('not_found','inactive','too_large','missing_photo','future','invalid','revoked')"
           )
  end
end
```

Company deletion needs no trigger work: `delete_company_trigger` only cleans detail tables that have no `company_id` of their own (`invoice_details`, `pur_invoice_details`), so the plain `on_delete: :delete_all` above cascades these rows.

- [ ] **Step 4: Write the schema**

Create `lib/full_circle/punch_gate/punch_ingest_log.ex`:

```elixir
defmodule FullCircle.PunchGate.PunchIngestLog do
  @moduledoc """
  Append-only operational log of every gate POST the server can attribute to a
  company — accepted, replayed, duplicate, rejected, or refused with a 401
  because the device was revoked.

  This is **not** an attendance register; `time_attendences` stays the payroll
  source of truth. Rows are written best-effort after the punch is already
  decided, so a bad row here can never cost a punch. `id` and `inserted_at` are
  cast on purpose: the writer generates both up front so the JPEG filename and
  its `yyyy/mm` folder are known before the row exists.
  """
  use FullCircle.Schema
  import Ecto.Changeset

  @outcomes ~w(accepted replayed duplicate rejected)
  @reasons ~w(not_found inactive too_large missing_photo future invalid revoked)

  schema "punch_ingest_logs" do
    field :employee_id_raw, :string
    field :client_id, :string
    field :punched_at, :utc_datetime
    field :outcome, :string
    field :reason, :string
    field :http_status, :integer
    field :photo_path, :string

    belongs_to :company, FullCircle.Sys.Company
    belongs_to :punch_device, FullCircle.PunchGate.PunchDevice
    belongs_to :employee, FullCircle.HR.Employee
    belongs_to :time_attendence, FullCircle.HR.TimeAttend

    timestamps(updated_at: false, type: :utc_datetime)
  end

  def outcomes, do: @outcomes
  def reasons, do: @reasons

  def changeset(log, attrs) do
    log
    |> cast(attrs, [
      :id,
      :inserted_at,
      :company_id,
      :punch_device_id,
      :employee_id,
      :employee_id_raw,
      :time_attendence_id,
      :client_id,
      :punched_at,
      :outcome,
      :reason,
      :http_status,
      :photo_path
    ])
    |> validate_required([:company_id, :outcome, :http_status])
  end
end
```

- [ ] **Step 5: Add `http_status_for/1` and use it in the controller**

In `lib/full_circle/punch_gate.ex`, add next to the other public helpers (just below `parse_badge_payload/1`):

```elixir
  @doc """
  The HTTP status the gate API answers for an ingest result.

  Single source of truth: `PunchAttendanceController` sends it and
  `punch_ingest_logs.http_status` stores it, so the two cannot drift.
  """
  def http_status_for(:accepted), do: 201
  def http_status_for(:revoked), do: 401
  def http_status_for(:not_found), do: 404
  def http_status_for(:duplicate), do: 409
  def http_status_for(:too_large), do: 413
  def http_status_for(_), do: 422
```

Replace the body of `PunchAttendanceController.create/2` (`lib/full_circle_web/controllers/punch_attendance_controller.ex:8-46`) with:

```elixir
  def create(conn, params) do
    case PunchGate.ingest_punch(conn.assigns.punch_device, params) do
      {:ok, ta} ->
        ta = FullCircle.Repo.preload(ta, :employee)

        conn
        |> put_status(PunchGate.http_status_for(:accepted))
        |> json(%{
          id: ta.id,
          employee_name: ta.employee.name,
          flag: ta.flag,
          punch_time: DateTime.to_iso8601(ta.punch_time)
        })

      {:error, reason} ->
        send_resp(conn, PunchGate.http_status_for(reason), body_for(reason))
    end
  end

  defp body_for(:not_found), do: "not found"
  defp body_for(:inactive), do: "inactive"
  defp body_for(:duplicate), do: "duplicate"
  defp body_for(:too_large), do: "too large"
  defp body_for(:missing_photo), do: "missing photo"
  defp body_for(:future), do: "future"
  defp body_for(_), do: "invalid"
```

- [ ] **Step 6: Migrate and run both test files**

```bash
mix ecto.migrate
mix test test/full_circle/punch_ingest_log_test.exs test/full_circle_web/controllers/punch_attendance_controller_test.exs
```
Expected: PASS. The controller test is the proof the refactor changed no status or body.

- [ ] **Step 7: Format and commit**

```bash
mix format priv/repo/migrations/20260909120000_create_punch_ingest_logs.exs \
  lib/full_circle/punch_gate/punch_ingest_log.ex \
  lib/full_circle/punch_gate.ex \
  lib/full_circle_web/controllers/punch_attendance_controller.ex \
  test/full_circle/punch_ingest_log_test.exs
git add -A
git commit -m "feat(punch-gate): punch_ingest_logs table and one HTTP status map

"
```

---

## Task 2: Log a row for every ingest outcome

Rows only — the JPEG comes in Task 3.

**Files:**
- Modify: `lib/full_circle/punch_gate.ex:89-115` (`ingest_punch/2`), `:271` (`resolve_client_conflict/3`)
- Modify: `test/full_circle/punch_ingest_log_test.exs`

**Interfaces:**
- Consumes: `PunchIngestLog.changeset/2`, `PunchGate.http_status_for/1` (Task 1).
- Produces: `PunchGate.ingest_punch/2` public return is **unchanged** (`{:ok, ta} | {:error, atom}`). Internally `insert_punch/6` and `resolve_client_conflict/3` may now return `{:replayed, ta}`, stripped before returning.
- Produces: private `log_ingest/3`, `truncate_field/1`, `outcome_and_reason/1`.

- [ ] **Step 1: Write the failing tests**

Append to `test/full_circle/punch_ingest_log_test.exs` (inside the module, after the existing describes). Note `import FullCircle.HRFixtures` must be added to the top-level imports:

```elixir
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

      assert ["accepted", "replayed"] ==
               logs(ctx.company) |> Enum.sort_by(& &1.inserted_at) |> Enum.map(& &1.outcome)

      replay = Enum.find(logs(ctx.company), &(&1.outcome == "replayed"))
      assert replay.time_attendence_id == a.id
      assert replay.http_status == 201
      assert is_nil(replay.reason)
    end

    test "duplicate inside the 3 minute window", ctx do
      t0 = DateTime.utc_now() |> DateTime.truncate(:second)
      assert {:ok, _} = PunchGate.ingest_punch(ctx.device, ingest_attrs(ctx.emp, %{"punched_at" => t0}))

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
               PunchGate.ingest_punch(ctx.device, ingest_attrs(ctx.emp, %{"employee_id" => "fcqa:nope"}))

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
               PunchGate.ingest_punch(ctx.device, ingest_attrs(ctx.emp, %{"punched_at" => future}))

      log = one_log(ctx.company)
      assert log.reason == "future"
      assert log.http_status == 422
      assert log.punched_at == future
    end

    test "unparseable punch time logs invalid with a nil punched_at", ctx do
      assert {:error, :invalid} =
               PunchGate.ingest_punch(ctx.device, ingest_attrs(ctx.emp, %{"punched_at" => "not-a-time"}))

      log = one_log(ctx.company)
      assert log.reason == "invalid"
      assert is_nil(log.punched_at)
    end

    test "an over-long employee_id still produces a row, truncated", ctx do
      long = String.duplicate("a", 400)
      assert {:error, :not_found} = PunchGate.ingest_punch(ctx.device, ingest_attrs(ctx.emp, %{"employee_id" => long}))

      log = one_log(ctx.company)
      assert log.reason == "not_found"
      assert String.length(log.employee_id_raw) == 64
    end

    test "an over-long client_id still produces a row, truncated", ctx do
      long = String.duplicate("c", 400)
      assert {:ok, _} = PunchGate.ingest_punch(ctx.device, ingest_attrs(ctx.emp, %{"client_id" => long}))

      log = one_log(ctx.company)
      assert String.length(log.client_id) == 64
    end

  end
```

Add `import Ecto.Query` and `import FullCircle.HRFixtures` to the top of the test module.

- [ ] **Step 2: Run and watch them fail**

Run: `mix test test/full_circle/punch_ingest_log_test.exs`
Expected: FAIL — every log assertion fails because no rows are written.

- [ ] **Step 3: Tag the two replay paths**

In `lib/full_circle/punch_gate.ex`, `insert_punch/6`'s `case` (around line 256) — change only the conflict branch's helper. Then in `resolve_client_conflict/3` (line 271) change the success return:

```elixir
    if unique? do
      case existing_client(device_id, client_id) do
        %TimeAttend{} = ta -> {:replayed, Repo.preload(ta, :employee)}
        nil -> {:error, :invalid}
      end
    else
      {:error, :invalid}
    end
```

- [ ] **Step 4: Rewrite `ingest_punch/2` to log, then strip the tag**

Replace `ingest_punch/2` (`lib/full_circle/punch_gate.ex:89-115`) with:

```elixir
  def ingest_punch(%PunchDevice{} = device, attrs) do
    device = Repo.preload(device, :company)
    company = device.company
    employee_id = to_string(attrs["employee_id"] || attrs[:employee_id] || "")
    client_id = attrs["client_id"] || attrs[:client_id]
    raw_punched_at = attrs["punched_at"] || attrs[:punched_at]
    photo = attrs["photo"] || attrs[:photo]

    result =
      with :ok <- validate_photo(photo),
           {:ok, punched_at} <- parse_punched_at(raw_punched_at),
           :ok <- validate_not_future(punched_at),
           %Employee{} = emp <- get_company_employee(employee_id, company.id),
           :ok <- validate_active(emp) do
        case existing_client(device.id, client_id) do
          %TimeAttend{} = ta ->
            {:replayed, ta}

          nil ->
            with :ok <- reject_duplicate(emp.id, company.id, punched_at) do
              insert_punch(device, emp, company, punched_at, client_id, photo)
            else
              {:error, reason} -> {:error, reason}
            end
        end
      else
        {:error, reason} -> {:error, reason}
      end

    log_ingest(device, %{
      employee_id_raw: employee_id,
      client_id: client_id,
      punched_at: raw_punched_at,
      photo: photo
    }, result)

    strip_replay_tag(result)
  end

  defp strip_replay_tag({:replayed, ta}), do: {:ok, ta}
  defp strip_replay_tag(other), do: other
```

Note `{:replayed, ta}` from the `existing_client` short-circuit is **not** preloaded, while the one from `resolve_client_conflict/3` is. `PunchAttendanceController.create/2` preloads `:employee` itself, so both are safe — that is pre-existing behavior, do not "fix" it here.

- [ ] **Step 5: Write the logging helpers**

Add near the bottom of `lib/full_circle/punch_gate.ex`, and add `require Logger` under the existing `import Ecto.Query` at the top:

```elixir
  # ── Ingest logging ─────────────────────────────────────────────────
  # Best effort, always after the punch is decided. Nothing in here may
  # change what ingest_punch/2 returns or what the controller sends.

  @raw_field_limit 64

  # The rescue sits on this function, not on the insert alone: building the
  # attrs touches unvalidated client values (to_string/1 on whatever the phone
  # sent), so a raise there must be swallowed too.
  defp log_ingest(%PunchDevice{} = device, info, result) do
    {outcome, reason} = outcome_and_reason(result)

    attrs = %{
      company_id: device.company_id,
      punch_device_id: device.id,
      employee_id: log_employee_id(result, info.employee_id_raw, device.company_id),
      employee_id_raw: truncate_field(info.employee_id_raw),
      time_attendence_id: log_time_attendence_id(result),
      client_id: truncate_field(info.client_id),
      punched_at: parsed_or_nil(info.punched_at),
      outcome: outcome,
      reason: reason,
      http_status: http_status_for(log_status_atom(outcome, reason))
    }

    insert_ingest_log(attrs)
  rescue
    e ->
      Logger.error("punch ingest log raised: #{Exception.message(e)}")
      :error
  end

  # Repo.insert returns {:error, changeset} without raising, so the tuple needs
  # handling here; the raising cases (a check-constraint violation with no
  # check_constraint/3 on the changeset raises Postgrex.Error) are caught by the
  # rescue on log_ingest/3 above.
  defp insert_ingest_log(attrs) do
    %PunchIngestLog{}
    |> PunchIngestLog.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, log} ->
        {:ok, log}

      {:error, reason} ->
        Logger.error("punch ingest log insert failed: #{inspect(reason)}")
        :error
    end
  end

  defp outcome_and_reason({:ok, _}), do: {"accepted", nil}
  defp outcome_and_reason({:replayed, _}), do: {"replayed", nil}
  defp outcome_and_reason({:error, :duplicate}), do: {"duplicate", nil}
  defp outcome_and_reason({:error, reason}), do: {"rejected", to_string(reason)}

  defp log_status_atom("accepted", _), do: :accepted
  defp log_status_atom("replayed", _), do: :accepted
  defp log_status_atom("duplicate", _), do: :duplicate
  defp log_status_atom("rejected", reason), do: String.to_existing_atom(reason)

  defp log_time_attendence_id({:ok, %TimeAttend{id: id}}), do: id
  defp log_time_attendence_id({:replayed, %TimeAttend{id: id}}), do: id
  defp log_time_attendence_id(_), do: nil

  # Only the two outcomes that resolved an employee but produced no row pay for
  # an extra lookup; the happy path reads it off the attendance row.
  defp log_employee_id({:ok, %TimeAttend{employee_id: id}}, _raw, _company_id), do: id
  defp log_employee_id({:replayed, %TimeAttend{employee_id: id}}, _raw, _company_id), do: id

  defp log_employee_id({:error, reason}, raw, company_id) when reason in [:duplicate, :inactive] do
    case get_company_employee(raw, company_id) do
      %Employee{id: id} -> id
      _ -> nil
    end
  end

  defp log_employee_id(_result, _raw, _company_id), do: nil

  defp parsed_or_nil(raw) do
    case parse_punched_at(raw) do
      {:ok, dt} -> dt
      _ -> nil
    end
  end

  # employee_id and client_id are unvalidated client strings. varchar(255)
  # would raise on a long one, the rescue above would swallow it, and the log
  # row would be lost for exactly the malformed POST worth seeing.
  defp truncate_field(nil), do: nil
  defp truncate_field(s) when is_binary(s), do: String.slice(s, 0, @raw_field_limit)
  defp truncate_field(other), do: other |> to_string() |> String.slice(0, @raw_field_limit)
```

Add the alias at the top of the module: `alias FullCircle.PunchGate.{PunchDevice, PunchIngestLog}` (replacing the existing single-module alias).

`log_status_atom/2` uses `String.to_existing_atom/1`, which is safe here: every reason string it can see was produced by `to_string/1` on an atom that already exists in this module.

- [ ] **Step 6: Run the tests**

Run: `mix test test/full_circle/punch_ingest_log_test.exs test/full_circle/punch_gate_test.exs test/full_circle_web/controllers/punch_attendance_controller_test.exs`
Expected: PASS — including every pre-existing `punch_gate_test.exs` assertion, which is the proof the public return did not change.

The "a log failure never costs a punch" contract is proven in Task 3, where a
broken `uploads_dir` makes the write actually fail. Do not fake it here with a
test that asserts nothing.

- [ ] **Step 7: Format and commit**

```bash
mix format lib/full_circle/punch_gate.ex test/full_circle/punch_ingest_log_test.exs
git add -A
git commit -m "feat(punch-gate): log every ingest outcome to punch_ingest_logs

"
```

---

## Task 3: Store the reject/duplicate JPEG

**Files:**
- Modify: `lib/full_circle/punch_gate.ex` (logging helpers from Task 2)
- Modify: `test/full_circle/punch_ingest_log_test.exs`

**Interfaces:**
- Consumes: `log_ingest/3`, `insert_ingest_log/1` (Task 2).
- Produces: `PunchGate.ingest_log_photo_abs_path(company_id, log_id, %DateTime{})` — used by the pruner (Task 5) and the photo controller test (Task 7).

Because `validate_photo/1` is the **first** clause of the `with`, every outcome that is reachable past it already has a usable JPEG. The rule is therefore flat: store a file for everything except `accepted`, `replayed`, `missing_photo`, `too_large`, and `revoked`.

- [ ] **Step 1: Write the failing tests**

Append a new describe block to `test/full_circle/punch_ingest_log_test.exs`:

```elixir
  describe "log JPEG" do
    setup ctx do
      %{emp: employee_fixture(%{}, ctx.company, ctx.admin)}
    end

    defp log_abs(log),
      do: Path.join(Application.get_env(:full_circle, :uploads_dir), log.photo_path)

    test "duplicate stores a file", ctx do
      t0 = DateTime.utc_now() |> DateTime.truncate(:second)
      assert {:ok, _} = PunchGate.ingest_punch(ctx.device, ingest_attrs(ctx.emp, %{"punched_at" => t0}))

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
      assert File.exists?(PunchGate.ingest_log_photo_abs_path(ctx.company.id, dup.id, dup.inserted_at))
    end

    test "not_found stores a file", ctx do
      assert {:error, :not_found} =
               PunchGate.ingest_punch(ctx.device, ingest_attrs(ctx.emp, %{"employee_id" => Ecto.UUID.generate()}))

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
      assert {:error, :future} = PunchGate.ingest_punch(ctx.device, ingest_attrs(ctx.emp, %{"punched_at" => future}))
      assert File.exists?(log_abs(one_log(ctx.company)))
    end

    test "invalid timestamp stores a file", ctx do
      assert {:error, :invalid} =
               PunchGate.ingest_punch(ctx.device, ingest_attrs(ctx.emp, %{"punched_at" => "nope"}))

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
  end
```

- [ ] **Step 2: Run and watch them fail**

Run: `mix test test/full_circle/punch_ingest_log_test.exs`
Expected: FAIL — `PunchGate.ingest_log_photo_abs_path/3` undefined, and `photo_path` is nil everywhere.

- [ ] **Step 3: Add the path helper**

In `lib/full_circle/punch_gate.ex`, next to `photo_abs_path/2`:

```elixir
  @doc """
  Where a log JPEG lives. The folder is `inserted_at`'s UTC year/month — a
  folder, not a business date, so no timezone conversion is wanted here.
  """
  def ingest_log_photo_abs_path(company_id, log_id, %DateTime{} = at) do
    Path.join([
      Application.get_env(:full_circle, :uploads_dir),
      "#{company_id}",
      "punch_ingest_logs",
      "#{at.year}",
      at.month |> Integer.to_string() |> String.pad_leading(2, "0"),
      "#{log_id}.jpg"
    ])
  end
```

- [ ] **Step 4: Generate the id up front and write the file before the row**

Replace `log_ingest/3` and `insert_ingest_log/1` from Task 2 with:

```elixir
  defp log_ingest(%PunchDevice{} = device, info, result) do
    {outcome, reason} = outcome_and_reason(result)
    id = Ecto.UUID.generate()
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    photo_path =
      if log_photo?(outcome, reason),
        do: copy_log_photo(device.company_id, id, now, info.photo),
        else: nil

    attrs = %{
      id: id,
      inserted_at: now,
      company_id: device.company_id,
      punch_device_id: device.id,
      employee_id: log_employee_id(result, info.employee_id_raw, device.company_id),
      employee_id_raw: truncate_field(info.employee_id_raw),
      time_attendence_id: log_time_attendence_id(result),
      client_id: truncate_field(info.client_id),
      punched_at: parsed_or_nil(info.punched_at),
      outcome: outcome,
      reason: reason,
      http_status: http_status_for(log_status_atom(outcome, reason)),
      photo_path: photo_path
    }

    case insert_ingest_log(attrs) do
      {:ok, log} ->
        {:ok, log}

      :error ->
        # The row is what makes the file findable; without one it is garbage.
        if photo_path, do: File.rm(Path.join(uploads_dir(), photo_path))
        :error
    end
  end

  defp uploads_dir, do: Application.get_env(:full_circle, :uploads_dir)

  # validate_photo/1 is the first clause of the ingest `with`, so anything that
  # gets past it has a usable JPEG. Accepted and replayed faces already live on
  # time_attendences for 24 months and are never copied here; revoked is logged
  # from the auth plug, before any photo handling.
  defp log_photo?(outcome, _reason) when outcome in ["accepted", "replayed"], do: false
  defp log_photo?(_outcome, reason) when reason in ["missing_photo", "too_large", "revoked"], do: false
  defp log_photo?(_outcome, _reason), do: true

  defp copy_log_photo(_company_id, _id, _now, nil), do: nil

  defp copy_log_photo(company_id, id, now, photo) do
    abs = ingest_log_photo_abs_path(company_id, id, now)
    File.mkdir_p!(Path.dirname(abs))
    File.cp!(photo_src(photo), abs)
    Path.relative_to(abs, uploads_dir())
  rescue
    e ->
      # A missing picture is worth far less than a missing row. Keep the row.
      Logger.error("punch ingest log photo copy failed: #{Exception.message(e)}")
      nil
  end
```

And simplify `insert_ingest_log/1` to take the attrs it is given (it no longer builds them):

```elixir
  defp insert_ingest_log(attrs) do
    %PunchIngestLog{}
    |> PunchIngestLog.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, log} ->
        {:ok, log}

      {:error, reason} ->
        Logger.error("punch ingest log insert failed: #{inspect(reason)}")
        :error
    end
  rescue
    e ->
      Logger.error("punch ingest log raised: #{Exception.message(e)}")
      :error
  end
```

- [ ] **Step 5: Run the tests**

Run: `mix test test/full_circle/punch_ingest_log_test.exs test/full_circle/punch_gate_test.exs`
Expected: PASS.

- [ ] **Step 6: Format and commit**

```bash
mix format lib/full_circle/punch_gate.ex test/full_circle/punch_ingest_log_test.exs
git add -A
git commit -m "feat(punch-gate): store the reject and duplicate face on the ingest log

"
```

---

## Task 4: Log revoked-device 401s

The failure this whole feature exists for: revoke a gate and re-pair it on a new phone, and the old phone 401s and **silently drops** every queued punch, because the APK treats 4xx as done. A revoked token still resolves to a company, so unlike an unknown token it can be logged.

**Files:**
- Modify: `lib/full_circle/punch_gate.ex` (`get_active_device_by_token/1:67-74`)
- Modify: `lib/full_circle_web/plugs/punch_device_auth.ex`
- Modify: `test/full_circle/punch_ingest_log_test.exs`
- Modify: `test/full_circle_web/controllers/punch_attendance_controller_test.exs`

**Interfaces:**
- Produces: `PunchGate.authenticate_device(binary) :: {:ok, %PunchDevice{}} | {:revoked, %PunchDevice{}} | :error` — one `token_hash` query, company preloaded.
- Produces: `PunchGate.log_revoked_attempt(%PunchDevice{}, map) :: :ok` — always `:ok`, never raises.
- `get_active_device_by_token/1` keeps its exact current behavior and is reimplemented on top of `authenticate_device/1`.

- [ ] **Step 1: Write the failing context test**

Append to `test/full_circle/punch_ingest_log_test.exs`:

```elixir
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
  end
```

- [ ] **Step 2: Write the failing controller test**

Append to `test/full_circle_web/controllers/punch_attendance_controller_test.exs`. That file's `setup` already yields `conn, admin, company, emp, device, token`, and it already defines `auth/2` and `jpeg_upload/0` — reuse them, do not redefine them:

```elixir
  describe "revoked device" do
    test "POST still 401s and leaves one revoked log row", ctx do
      {:ok, _} = PunchGate.revoke_device(ctx.device, ctx.company, ctx.admin)

      conn =
        ctx.conn
        |> auth(ctx.token)
        |> post(~p"/api/punch/attendances", %{
          "employee_id" => ctx.emp.id,
          "punched_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
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
```

- [ ] **Step 3: Run both and watch them fail**

Run: `mix test test/full_circle/punch_ingest_log_test.exs test/full_circle_web/controllers/punch_attendance_controller_test.exs`
Expected: FAIL — `PunchGate.authenticate_device/1` undefined.

- [ ] **Step 4: Add `authenticate_device/1` and rebase the old lookup on it**

Replace `get_active_device_by_token/1` (`lib/full_circle/punch_gate.ex:67-74`) with:

```elixir
  @doc """
  Resolves a device Bearer token.

  Returns `{:revoked, device}` rather than `nil` for a token whose device was
  revoked: that POST is still attributable to a company, and it is a *silent*
  punch loss (the APK drops 4xx), so it is worth a `punch_ingest_logs` row.
  A token matching no row stays anonymous and is never logged.
  """
  def authenticate_device(plain) when is_binary(plain) do
    from(d in PunchDevice,
      where: d.token_hash == ^hash_token(plain),
      preload: [:company]
    )
    |> Repo.one()
    |> case do
      nil -> :error
      %PunchDevice{revoked_at: nil} = device -> {:ok, device}
      %PunchDevice{} = device -> {:revoked, device}
    end
  end

  def get_active_device_by_token(plain) when is_binary(plain) do
    case authenticate_device(plain) do
      {:ok, device} -> device
      _ -> nil
    end
  end
```

- [ ] **Step 5: Add `log_revoked_attempt/2`**

In `lib/full_circle/punch_gate.ex`, with the other logging helpers:

```elixir
  @doc """
  Records a POST refused with 401 because the device is revoked.

  Always returns `:ok`; the caller is an auth plug and must send its 401
  regardless. No photo is copied — the useful fact is "this phone is unpaired",
  not the face.
  """
  def log_revoked_attempt(%PunchDevice{} = device, params) do
    raw = to_string(params["employee_id"] || "")

    insert_ingest_log(%{
      id: Ecto.UUID.generate(),
      inserted_at: DateTime.utc_now() |> DateTime.truncate(:second),
      company_id: device.company_id,
      punch_device_id: device.id,
      employee_id: revoked_employee_id(raw, device.company_id),
      employee_id_raw: truncate_field(raw),
      client_id: truncate_field(params["client_id"]),
      punched_at: parsed_or_nil(params["punched_at"]),
      outcome: "rejected",
      reason: "revoked",
      http_status: http_status_for(:revoked)
    })

    :ok
  end

  defp revoked_employee_id(raw, company_id) do
    case get_company_employee(raw, company_id) do
      %Employee{id: id} -> id
      _ -> nil
    end
  end
```

- [ ] **Step 6: Add the plug branch, POSTs only**

Replace `lib/full_circle_web/plugs/punch_device_auth.ex` with:

```elixir
defmodule FullCircleWeb.PunchDeviceAuth do
  import Plug.Conn
  alias FullCircle.PunchGate

  def init(opts), do: opts

  def call(conn, _opts) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         {:ok, device} <- PunchGate.authenticate_device(token) do
      conn
      |> assign(:punch_device, device)
      |> assign(:current_company, device.company)
    else
      {:revoked, device} ->
        # POSTs only. This plug also fronts GET /api/punch/health, which the
        # scanner pings every 20 seconds — logging those would write thousands
        # of rows a day per revoked phone and bury the punch worth seeing.
        if conn.method == "POST", do: PunchGate.log_revoked_attempt(device, conn.params)
        unauthorized(conn)

      _ ->
        unauthorized(conn)
    end
  end

  defp unauthorized(conn) do
    conn
    |> send_resp(:unauthorized, "No access for you")
    |> halt()
  end
end
```

- [ ] **Step 7: Run the tests**

Run: `mix test test/full_circle/punch_ingest_log_test.exs test/full_circle/punch_gate_test.exs test/full_circle_web/controllers/punch_attendance_controller_test.exs`
Expected: PASS, with the pre-existing 401 assertions untouched.

- [ ] **Step 8: Format and commit**

```bash
mix format lib/full_circle/punch_gate.ex lib/full_circle_web/plugs/punch_device_auth.ex \
  test/full_circle/punch_ingest_log_test.exs \
  test/full_circle_web/controllers/punch_attendance_controller_test.exs
git add -A
git commit -m "feat(punch-gate): log POSTs refused because the device is revoked

"
```

---

## Task 5: Three-month retention

**Files:**
- Create: `lib/full_circle/punch_gate/ingest_log_pruner.ex`
- Modify: `lib/full_circle/punch_gate.ex`, `lib/full_circle/application.ex:17`, `config/config.exs:93-94`, `config/test.exs:39`
- Modify: `test/full_circle/punch_ingest_log_test.exs`

**Interfaces:**
- Produces: `PunchGate.prune_ingest_logs_before(%DateTime{}, opts) :: {:ok, integer}` with `:dry_run` and `:batch`.
- Produces: `FullCircle.PunchGate.IngestLogPruner.prune/0`.

- [ ] **Step 1: Write the failing tests**

Append to `test/full_circle/punch_ingest_log_test.exs`:

```elixir
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

      assert {:ok, 3} = PunchGate.prune_ingest_logs_before(DateTime.utc_now(), dry_run: true, batch: 2)
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

      assert {:ok, 1} = PunchGate.prune_ingest_logs_before(DateTime.utc_now() |> DateTime.add(-1, :day))
      assert File.exists?(PunchGate.photo_abs_path(ctx.company.id, ta))
    end
  end
```

- [ ] **Step 2: Run and watch them fail**

Run: `mix test test/full_circle/punch_ingest_log_test.exs`
Expected: FAIL — `PunchGate.prune_ingest_logs_before/2` undefined.

- [ ] **Step 3: Write the prune functions**

In `lib/full_circle/punch_gate.ex`, below `prune_photos_before/2` and its helpers:

```elixir
  @doc """
  Deletes `punch_ingest_logs` received before `cutoff`, file then row.

  The file is removed first: if that is interrupted the row points at a missing
  file, which the photo controller already answers with a 404, and the next run
  finishes the job. The reverse order would orphan the file forever.

  Options: `:dry_run` (report what would go, change nothing) and `:batch`.
  """
  def prune_ingest_logs_before(%DateTime{} = cutoff, opts \\ []) do
    dry_run? = Keyword.get(opts, :dry_run, false)
    batch = Keyword.get(opts, :batch, @prune_batch)
    uploads = Application.get_env(:full_circle, :uploads_dir)

    {:ok, prune_log_batches(cutoff, batch, dry_run?, uploads, 0)}
  end

  defp prune_log_batches(cutoff, batch, dry_run?, uploads, done) do
    rows =
      from(l in PunchIngestLog,
        where: l.inserted_at < ^cutoff,
        order_by: [asc: l.inserted_at],
        limit: ^batch,
        select: %{id: l.id, photo_path: l.photo_path}
      )
      |> Repo.all()

    cond do
      rows == [] ->
        done

      dry_run? ->
        # Nothing is written, so paging would loop forever on the same rows.
        done + length(rows) + count_remaining_logs(cutoff, length(rows))

      true ->
        Enum.each(rows, fn row ->
          if row.photo_path, do: uploads |> Path.join(row.photo_path) |> File.rm()
          from(l in PunchIngestLog, where: l.id == ^row.id) |> Repo.delete_all()
        end)

        prune_log_batches(cutoff, batch, dry_run?, uploads, done + length(rows))
    end
  end

  defp count_remaining_logs(cutoff, seen) do
    total =
      from(l in PunchIngestLog,
        where: l.inserted_at < ^cutoff,
        select: count(l.id)
      )
      |> Repo.one()

    max(total - seen, 0)
  end
```

- [ ] **Step 4: Write the pruner GenServer**

Create `lib/full_circle/punch_gate/ingest_log_pruner.ex`:

```elixir
defmodule FullCircle.PunchGate.IngestLogPruner do
  @moduledoc """
  Deletes `punch_ingest_logs` rows (and their JPEGs) older than the retention
  window.

  Same shape as `PhotoPruner` and for the same reason: there is no job runner
  in this project, so this is a plain supervised process that wakes daily and
  ships with the release. Single node assumed — with more than one, each runs
  its own copy, which is wasteful but harmless because the work is idempotent.

  Unlike `PhotoPruner` this one deletes **rows**, not just files: the ingest log
  is an operational breadcrumb trail, not a register. `time_attendences` and
  its 24-month photos are untouched.

  To see what it would do without deleting anything:

      FullCircle.PunchGate.prune_ingest_logs_before(
        Timex.shift(DateTime.utc_now(), months: -3),
        dry_run: true
      )
  """
  use GenServer
  require Logger

  alias FullCircle.PunchGate

  @day_ms 24 * 60 * 60 * 1000
  @default_retention_months 3
  # Late enough after boot that a deploy is not competing with startup work.
  @first_run_ms 5 * 60 * 1000

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(nil) do
    if enabled?(), do: Process.send_after(self(), :prune, @first_run_ms)
    {:ok, nil}
  end

  @impl true
  def handle_info(:prune, state) do
    prune()
    Process.send_after(self(), :prune, @day_ms)
    {:noreply, state}
  end

  @doc "Runs one pass now. Safe to call by hand from a release console."
  def prune do
    months =
      Application.get_env(
        :full_circle,
        :punch_ingest_log_retention_months,
        @default_retention_months
      )

    # Calendar months, not 30-day approximations.
    cutoff = Timex.shift(DateTime.utc_now(), months: -months)

    case PunchGate.prune_ingest_logs_before(cutoff) do
      {:ok, 0} ->
        :ok

      {:ok, n} ->
        Logger.info("punch ingest log pruner: removed #{n} rows received before #{cutoff}")
        :ok
    end
  rescue
    e ->
      # Never take the supervision tree down over housekeeping; retry tomorrow.
      Logger.error("punch ingest log pruner failed: #{Exception.message(e)}")
      :error
  end

  defp enabled?, do: Application.get_env(:full_circle, :punch_ingest_log_prune_enabled, true)
end
```

- [ ] **Step 5: Supervise it and add the config knobs**

`lib/full_circle/application.ex`, directly after line 17:

```elixir
      FullCircle.PunchGate.PhotoPruner,
      FullCircle.PunchGate.IngestLogPruner,
```

`config/config.exs`, after the existing punch photo lines (93-94):

```elixir
# Punch ingest log rows and their reject photos are deleted after this many
# calendar months. Shorter than the 24-month punch photo window: this is an
# operational breadcrumb trail, not a register.
config :full_circle, punch_ingest_log_retention_months: 3
config :full_circle, punch_ingest_log_prune_enabled: true
```

`config/test.exs`, after line 39:

```elixir
config :full_circle, punch_ingest_log_prune_enabled: false
```

- [ ] **Step 6: Run the tests**

Run: `mix test test/full_circle/punch_ingest_log_test.exs`
Expected: PASS.

- [ ] **Step 7: Format and commit**

```bash
mix format lib/full_circle/punch_gate.ex lib/full_circle/punch_gate/ingest_log_pruner.ex \
  lib/full_circle/application.ex config/config.exs config/test.exs \
  test/full_circle/punch_ingest_log_test.exs
git add -A
git commit -m "feat(punch-gate): prune ingest logs after 3 calendar months

"
```

---

## Task 6: Authorization and the list query

**Files:**
- Modify: `lib/full_circle/authorization.ex:274` (next to `:manage_punch_device`)
- Modify: `lib/full_circle/punch_gate.ex`
- Modify: `test/full_circle/punch_ingest_log_test.exs`

**Interfaces:**
- Produces: `Authorization.can?(user, :view_punch_ingest_log, company)` — admin, manager, supervisor, clerk.
- Produces: `PunchGate.list_ingest_logs(company, user, opts) :: [map] | :not_authorise`. `opts`: `:sdate`, `:edate` (ISO date strings, company-local), `:emp_name`, `:device_name`, `:outcome` (`"all"` or one outcome), `:page`, `:per_page`. Each row is a map with `id, inserted_at, punched_at, outcome, reason, http_status, photo_path, time_attendence_id, employee_name, employee_id_raw, device_name`.

- [ ] **Step 1: Write the failing tests**

Append to `test/full_circle/punch_ingest_log_test.exs`:

```elixir
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
               PunchGate.list_ingest_logs(ctx.company, cashier, sdate: ctx.today, edate: ctx.today)
    end

    test "a clerk is allowed", ctx do
      clerk = user_fixture()
      {:ok, _} = FullCircle.Sys.allow_user_to_access(ctx.company, clerk, "clerk", ctx.admin)

      assert is_list(PunchGate.list_ingest_logs(ctx.company, clerk, sdate: ctx.today, edate: ctx.today))
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
      assert PunchGate.list_ingest_logs(other, other_admin, sdate: ctx.today, edate: ctx.today) == []
    end
  end
```

- [ ] **Step 2: Run and watch them fail**

Run: `mix test test/full_circle/punch_ingest_log_test.exs`
Expected: FAIL — `PunchGate.list_ingest_logs/3` undefined.

- [ ] **Step 3: Add the permission**

`lib/full_circle/authorization.ex`, immediately after the `:manage_punch_device` clause (line 274-275):

```elixir
  def can?(user, :view_punch_ingest_log, company),
    do: allow_roles(~w(admin manager supervisor clerk), company, user)
```

Clerks get read-only visibility without widening `:manage_punch_device` (pairing) or `:create_time_attendence` (editing punches).

- [ ] **Step 4: Write the query**

In `lib/full_circle/punch_gate.ex`:

```elixir
  @doc """
  Rows for the ingest log list page, newest first.

  `sdate`/`edate` are company-local ISO dates. The window is
  `[local 00:00 of sdate, local 00:00 of edate + 1 day)` converted to UTC —
  never `inserted_at::date` in UTC, which would split "today" in Malaysia
  (UTC+8).
  """
  def list_ingest_logs(company, user, opts \\ []) do
    if Authorization.can?(user, :view_punch_ingest_log, company) do
      page = Keyword.get(opts, :page, 1)
      per_page = Keyword.get(opts, :per_page, 100)
      outcome = Keyword.get(opts, :outcome, "all")
      emp_name = Keyword.get(opts, :emp_name, "") |> to_string() |> String.trim()
      device_name = Keyword.get(opts, :device_name, "") |> to_string() |> String.trim()

      {from_utc, to_utc} =
        local_day_range(company, Keyword.fetch!(opts, :sdate), Keyword.fetch!(opts, :edate))

      from(l in PunchIngestLog,
        left_join: e in Employee,
        on: e.id == l.employee_id,
        left_join: d in PunchDevice,
        on: d.id == l.punch_device_id,
        where: l.company_id == ^company.id,
        where: l.inserted_at >= ^from_utc and l.inserted_at < ^to_utc,
        order_by: [desc: l.inserted_at],
        offset: ^((page - 1) * per_page),
        limit: ^per_page,
        select: %{
          id: l.id,
          inserted_at: l.inserted_at,
          punched_at: l.punched_at,
          outcome: l.outcome,
          reason: l.reason,
          http_status: l.http_status,
          photo_path: l.photo_path,
          time_attendence_id: l.time_attendence_id,
          employee_id_raw: l.employee_id_raw,
          employee_name: e.name,
          device_name: d.name
        }
      )
      |> filter_log_outcome(outcome)
      |> filter_log_employee(emp_name)
      |> filter_log_device(device_name)
      |> Repo.all()
    else
      :not_authorise
    end
  end

  defp filter_log_outcome(query, outcome) when outcome in [nil, "", "all"], do: query
  defp filter_log_outcome(query, outcome), do: from(l in query, where: l.outcome == ^outcome)

  defp filter_log_employee(query, ""), do: query

  defp filter_log_employee(query, name) do
    like = "%#{name}%"

    from([l, e, _d] in query,
      where: ilike(e.name, ^like) or ilike(l.employee_id_raw, ^like)
    )
  end

  defp filter_log_device(query, ""), do: query

  defp filter_log_device(query, name) do
    from([_l, _e, d] in query, where: ilike(d.name, ^"%#{name}%"))
  end

  defp local_day_range(company, sdate, edate) do
    tz = company.timezone
    {:ok, s} = sdate |> to_string() |> Date.from_iso8601()
    {:ok, e} = edate |> to_string() |> Date.from_iso8601()
    {:ok, start_local} = DateTime.new(s, ~T[00:00:00], tz)
    {:ok, end_local} = DateTime.new(Date.add(e, 1), ~T[00:00:00], tz)

    {DateTime.shift_zone!(start_local, "Etc/UTC"), DateTime.shift_zone!(end_local, "Etc/UTC")}
  end
```

- [ ] **Step 5: Run the tests**

Run: `mix test test/full_circle/punch_ingest_log_test.exs`
Expected: PASS. There is no `authorization_test.exs`; the cashier/clerk cases above are the permission proof.

- [ ] **Step 6: Format and commit**

```bash
mix format lib/full_circle/punch_gate.ex lib/full_circle/authorization.ex \
  test/full_circle/punch_ingest_log_test.exs
git add -A
git commit -m "feat(punch-gate): view_punch_ingest_log permission and list query

"
```

---

## Task 7: The log photo route

Do this before the LiveView: verified routes (`~p`) are checked at compile time, so the list page cannot reference a route that does not exist yet.

**Files:**
- Create: `lib/full_circle_web/controllers/punch_ingest_log_photo_controller.ex`
- Create: `test/full_circle_web/controllers/punch_ingest_log_photo_controller_test.exs`
- Modify: `lib/full_circle_web/router.ex:120` (beside the existing `TimeAttend` photo GET)

**Interfaces:**
- Consumes: `Authorization.can?(user, :view_punch_ingest_log, company)` (Task 6), `PunchIngestLog` (Task 1).
- Produces: `GET /companies/:company_id/punch_ingest_logs/:id/photo` → 200 JPEG / 403 / 404.

- [ ] **Step 1: Write the failing test**

Create `test/full_circle_web/controllers/punch_ingest_log_photo_controller_test.exs`:

```elixir
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

  test "200 JPEG for an admin", ctx do
    conn = get(ctx.conn, ~p"/companies/#{ctx.company.id}/punch_ingest_logs/#{ctx.log.id}/photo")
    assert conn.status == 200
    assert get_resp_header(conn, "content-type") |> hd() =~ "image/jpeg"
  end

  test "200 for a clerk", %{company: company, admin: admin, log: log} do
    conn =
      build_conn()
      |> log_in_user(member(company, "clerk", admin))
      |> get(~p"/companies/#{company.id}/punch_ingest_logs/#{log.id}/photo")

    assert conn.status == 200
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
```

- [ ] **Step 2: Run and watch it fail**

Run: `mix test test/full_circle_web/controllers/punch_ingest_log_photo_controller_test.exs`
Expected: FAIL — no route matches `/companies/:company_id/punch_ingest_logs/:id/photo`.

- [ ] **Step 3: Write the controller**

Create `lib/full_circle_web/controllers/punch_ingest_log_photo_controller.ex`:

```elixir
defmodule FullCircleWeb.PunchIngestLogPhotoController do
  @moduledoc """
  Serves one reject/duplicate face from `punch_ingest_logs`.

  Separate from `PunchPhotoController` on purpose: this one is role-gated, and
  an unauthorised viewer must get a bare **403**, never a redirect — an `<img>`
  that follows a dashboard redirect renders HTML into an image slot.
  """
  use FullCircleWeb, :controller

  alias FullCircle.Authorization
  alias FullCircle.PunchGate.PunchIngestLog
  alias FullCircle.Repo

  def show(conn, %{"id" => id, "company_id" => company_id}) do
    user = conn.assigns.current_user
    company = conn.assigns.current_company

    cond do
      is_nil(company) or to_string(company.id) != to_string(company_id) ->
        send_resp(conn, 404, "not found")

      !Authorization.can?(user, :view_punch_ingest_log, company) ->
        send_resp(conn, 403, "forbidden")

      true ->
        send_log_photo(conn, company_id, id)
    end
  end

  defp send_log_photo(conn, company_id, id) do
    log =
      case Ecto.UUID.cast(id) do
        {:ok, uuid} -> Repo.get_by(PunchIngestLog, id: uuid, company_id: company_id)
        :error -> nil
      end

    if is_nil(log) or is_nil(log.photo_path) do
      send_resp(conn, 404, "not found")
    else
      abs = Path.join(Application.get_env(:full_circle, :uploads_dir), log.photo_path)

      if File.exists?(abs) do
        conn
        |> put_resp_content_type("image/jpeg")
        |> send_file(200, abs)
      else
        send_resp(conn, 404, "not found")
      end
    end
  end
end
```

`conn.assigns.current_company` is set by the `set_active_company` plug in the `:browser` pipeline (`lib/full_circle_web/active_company.ex:31`), which resolves it from the `:company_id` URL segment and redirects a non-member away before this controller runs.

- [ ] **Step 4: Add the route**

`lib/full_circle_web/router.ex`, immediately after line 120:

```elixir
    get "/punch_ingest_logs/:id/photo", PunchIngestLogPhotoController, :show
```

- [ ] **Step 5: Run the test**

Run: `mix test test/full_circle_web/controllers/punch_ingest_log_photo_controller_test.exs`
Expected: PASS.

- [ ] **Step 6: Format and commit**

```bash
mix format lib/full_circle_web/controllers/punch_ingest_log_photo_controller.ex \
  lib/full_circle_web/router.ex \
  test/full_circle_web/controllers/punch_ingest_log_photo_controller_test.exs
git add -A
git commit -m "feat(punch-gate): serve ingest log photos behind view_punch_ingest_log

"
```

---

## Task 8: The list page

**Files:**
- Create: `lib/full_circle_web/live/punch_ingest_log_live/index.ex`
- Create: `test/full_circle_web/live/punch_ingest_log_live_test.exs`
- Modify: `lib/full_circle_web/router.ex:199` (beside `punch_devices`)
- Modify: `lib/full_circle_web/live/dashboard_live/dashboard_live.ex:114-120`
- Modify: `priv/gettext/{en,zh}/LC_MESSAGES/default.po`

**Interfaces:**
- Consumes: `PunchGate.list_ingest_logs/3` (Task 6), the photo routes (Task 7 and the existing `TimeAttend` one).

- [ ] **Step 1: Write the failing test**

Create `test/full_circle_web/live/punch_ingest_log_live_test.exs`:

```elixir
defmodule FullCircleWeb.PunchIngestLogLiveTest do
  use FullCircleWeb.ConnCase

  import Phoenix.LiveViewTest
  import FullCircle.UserAccountsFixtures
  import FullCircle.SysFixtures
  import FullCircle.HRFixtures

  alias FullCircle.PunchGate
  alias FullCircle.Repo

  setup %{conn: conn} do
    admin = user_fixture()
    company = company_fixture(admin, %{})
    emp = employee_fixture(%{name: "Ali Bin Abu"}, company, admin)
    {:ok, {device, _}} = PunchGate.create_device("Gate 1", company, admin)

    jpeg = Path.join(System.tmp_dir!(), "face-#{System.unique_integer([:positive])}.jpg")

    File.write!(
      jpeg,
      Base.decode64!(
        "/9j/4AAQSkZJRgABAQEASABIAAD/2wBDAP//////////////////////////////////////////////////////////////////////////////////////wgALCAABAAEBAREA/8QAFBABAAAAAAAAAAAAAAAAAAAAAP/aAAgBAQABPxA="
      )
    )

    photo = fn -> %Plug.Upload{path: jpeg, filename: "face.jpg", content_type: "image/jpeg"} end

    {:ok, _ta} =
      PunchGate.ingest_punch(device, %{
        "employee_id" => emp.id,
        "punched_at" => DateTime.utc_now() |> DateTime.truncate(:second),
        "client_id" => Ecto.UUID.generate(),
        "photo" => photo.()
      })

    {:error, :not_found} =
      PunchGate.ingest_punch(device, %{
        "employee_id" => "junk-badge",
        "punched_at" => DateTime.utc_now() |> DateTime.truncate(:second),
        "client_id" => Ecto.UUID.generate(),
        "photo" => photo.()
      })

    %{conn: log_in_user(conn, admin), company: company, admin: admin, emp: emp}
  end

  defp member_conn(company, role, admin) do
    user = user_fixture()
    {:ok, _} = FullCircle.Sys.allow_user_to_access(company, user, role, admin)
    build_conn() |> log_in_user(user)
  end

  test "admin sees today's rows", %{conn: conn, company: company} do
    {:ok, _lv, html} = live(conn, ~p"/companies/#{company.id}/punch_ingest_logs")

    assert html =~ "Punch Ingest Log"
    assert html =~ "Ali Bin Abu"
    assert html =~ "junk-badge"
  end

  test "a clerk is allowed in", %{company: company, admin: admin} do
    {:ok, _lv, html} =
      live(member_conn(company, "clerk", admin), ~p"/companies/#{company.id}/punch_ingest_logs")

    assert html =~ "Punch Ingest Log"
  end

  test "a cashier is bounced to the dashboard", %{company: company, admin: admin} do
    assert {:error, {:live_redirect, %{to: to}}} =
             live(member_conn(company, "cashier", admin), ~p"/companies/#{company.id}/punch_ingest_logs")

    assert to == "/companies/#{company.id}/dashboard"
  end

  test "outcome filter narrows the list", %{conn: conn, company: company} do
    {:ok, _lv, html} =
      live(
        conn,
        ~p"/companies/#{company.id}/punch_ingest_logs?#{[search: %{outcome: "rejected"}]}"
      )

    assert html =~ "junk-badge"
    refute html =~ "Ali Bin Abu"
  end

  test "employee search finds the raw badge", %{conn: conn, company: company} do
    {:ok, _lv, html} =
      live(
        conn,
        ~p"/companies/#{company.id}/punch_ingest_logs?#{[search: %{emp_name: "junk"}]}"
      )

    assert html =~ "junk-badge"
    refute html =~ "Ali Bin Abu"
  end

  test "a day with no rows is empty", %{conn: conn, company: company} do
    d =
      DateTime.now!(company.timezone)
      |> DateTime.to_date()
      |> Date.add(-5)
      |> Date.to_iso8601()

    {:ok, _lv, html} =
      live(
        conn,
        ~p"/companies/#{company.id}/punch_ingest_logs?#{[search: %{sdate: d, edate: d}]}"
      )

    refute html =~ "Ali Bin Abu"
    refute html =~ "junk-badge"
  end
end
```

- [ ] **Step 2: Run and watch it fail**

Run: `mix test test/full_circle_web/live/punch_ingest_log_live_test.exs`
Expected: FAIL — no route for `/punch_ingest_logs`.

- [ ] **Step 3: Add the routes**

`lib/full_circle_web/router.ex`, immediately after line 199 (`live("/punch_devices", ...)`):

```elixir
      live("/punch_ingest_logs", PunchIngestLogLive.Index, :index)
```

- [ ] **Step 4: Write the LiveView**

Create `lib/full_circle_web/live/punch_ingest_log_live/index.ex`:

```elixir
defmodule FullCircleWeb.PunchIngestLogLive.Index do
  @moduledoc """
  Read-only list of every gate POST the server could attribute to this company.

  Punch IO answers "what got recorded"; this answers "what arrived and what the
  server did with it" — including the rejects and revoked-device 401s that
  never reach `time_attendences`. No new/edit/delete, by design.
  """
  use FullCircleWeb, :live_view

  alias FullCircle.Authorization
  alias FullCircle.PunchGate

  @per_page 100

  @impl true
  def render(assigns) do
    ~H"""
    <div id="punchIngestLogIndex" class="mx-auto w-11/12">
      <p class="w-full text-3xl text-center font-medium">{@page_title}</p>
      <div class="flex justify-center mb-2">
        <.form for={%{}} id="search-form" phx-submit="search" autocomplete="off" class="w-full">
          <div class="flex flex-row flex-wrap tracking-tighter text-sm">
            <div class="w-[24%]">
              <.input
                id="search_emp_name"
                name="search[emp_name]"
                type="search"
                value={@search.emp_name}
                label={gettext("Employee or Badge")}
              />
            </div>
            <div class="w-[16%]">
              <.input
                id="search_device_name"
                name="search[device_name]"
                type="search"
                value={@search.device_name}
                label={gettext("Device")}
              />
            </div>
            <div class="w-[15%]">
              <.input
                name="search[sdate]"
                type="date"
                value={@search.sdate}
                id="search_sdate"
                label={gettext("Received From")}
              />
            </div>
            <div class="w-[15%]">
              <.input
                name="search[edate]"
                type="date"
                value={@search.edate}
                id="search_edate"
                label={gettext("Received To")}
              />
            </div>
            <div class="w-[15%]">
              <.input
                name="search[outcome]"
                type="select"
                value={@search.outcome}
                id="search_outcome"
                options={outcome_options()}
                label={gettext("Outcome")}
              />
            </div>
            <div class="w-[10%] flex items-center justify-center mt-5">
              <.input
                id="search_show_photos"
                name="search[show_photos]"
                type="checkbox"
                value={@search.show_photos}
                phx-debounce={nil}
                phx-click={
                  JS.toggle_class("show-punch-photos", to: "#punch_photos_wrapper")
                  |> JS.push("toggle_photos")
                }
                label={gettext("Show photos")}
              />
            </div>
            <.button class="mt-5 h-10 w-10 grow-0 shrink-0">🔍</.button>
          </div>
        </.form>
      </div>

      <div class="font-medium flex flex-row text-center tracking-tighter bg-amber-200 dark:bg-amber-800">
        <div class="w-[17%] border-b border-t border-amber-400 py-1">{gettext("Received At")}</div>
        <div class="w-[17%] border-b border-t border-amber-400 py-1">{gettext("Punch Time")}</div>
        <div class="w-[14%] border-b border-t border-amber-400 py-1">{gettext("Device")}</div>
        <div class="w-[24%] border-b border-t border-amber-400 py-1">{gettext("Employee")}</div>
        <div class="w-[20%] border-b border-t border-amber-400 py-1">{gettext("Outcome")}</div>
        <div class="w-[8%] border-b border-t border-amber-400 py-1">{gettext("Status")}</div>
      </div>

      <div id="punch_photos_wrapper" class={@search.show_photos && "show-punch-photos"}>
        <div
          :if={Enum.count(@streams.objects) > 0 or @page > 1}
          id="objects_list"
          phx-update="stream"
          phx-viewport-bottom={!@end_of_timeline? && "next-page"}
          phx-page-loading
        >
          <div
            :for={{obj_id, obj} <- @streams.objects}
            id={obj_id}
            class="flex flex-row text-center tracking-tighter hover:bg-gray-100 dark:hover:bg-gray-700 border-b border-gray-300 dark:border-gray-600 py-1"
          >
            <div class="w-[17%]">{local_time(obj.inserted_at, @current_company)}</div>
            <div class="w-[17%]">{local_time(obj.punched_at, @current_company)}</div>
            <div class="w-[14%]">{obj.device_name}</div>
            <div class="w-[24%]">
              <span :if={obj.employee_name}>{obj.employee_name}</span>
              <span :if={is_nil(obj.employee_name)} class="text-xs break-all text-gray-500">
                {obj.employee_id_raw}
              </span>
              <img
                :if={photo_src(obj, @current_company)}
                src={photo_src(obj, @current_company)}
                loading="lazy"
                alt={gettext("Punch photo")}
                class="punch-photo mt-0.5 mx-auto w-16 h-16 object-cover rounded border border-gray-400 dark:border-gray-600"
              />
            </div>
            <div class={["w-[20%] font-medium", outcome_class(obj.outcome)]}>
              {outcome_label(obj.outcome)}<span :if={obj.reason}>: {reason_label(obj.reason)}</span>
            </div>
            <div class="w-[8%]">{obj.http_status}</div>
          </div>
        </div>
      </div>

      <.infinite_scroll_footer ended={@end_of_timeline?} />
    </div>
    """
  end

  @impl true
  def mount(params, _session, socket) do
    company = socket.assigns.current_company

    if Authorization.can?(socket.assigns.current_user, :view_punch_ingest_log, company) do
      today =
        DateTime.now!(company.timezone)
        |> DateTime.to_date()
        |> Date.to_iso8601()

      search = %{
        emp_name: params["search"]["emp_name"] || "",
        device_name: params["search"]["device_name"] || "",
        sdate: params["search"]["sdate"] || today,
        edate: params["search"]["edate"] || today,
        outcome: params["search"]["outcome"] || "all",
        show_photos: (params["search"]["show_photos"] || "false") == "true"
      }

      {:ok,
       socket
       |> assign(page_title: gettext("Punch Ingest Log"))
       |> assign(search: search)
       |> filter_objects(true, 1)}
    else
      {:ok,
       socket
       |> put_flash(:error, gettext("Not Authorized!"))
       |> push_navigate(to: ~p"/companies/#{company.id}/dashboard")}
    end
  end

  @impl true
  def handle_event("toggle_photos", _, socket) do
    s = socket.assigns.search
    # Visibility is CSS on the wrapper, so the stream keeps its rows and its
    # scroll position and nothing is re-queried.
    {:noreply, assign(socket, search: %{s | show_photos: !s.show_photos})}
  end

  @impl true
  def handle_event("next-page", _, socket) do
    {:noreply, filter_objects(socket, false, socket.assigns.page + 1)}
  end

  @impl true
  def handle_event("search", %{"search" => search}, socket) do
    qry = %{
      "search[emp_name]" => search["emp_name"],
      "search[device_name]" => search["device_name"],
      "search[sdate]" => search["sdate"],
      "search[edate]" => search["edate"],
      "search[outcome]" => search["outcome"],
      "search[show_photos]" => to_string((search["show_photos"] || "false") == "true")
    }

    {:noreply,
     push_navigate(socket,
       to:
         "/companies/#{socket.assigns.current_company.id}/punch_ingest_logs?#{URI.encode_query(qry)}"
     )}
  end

  defp filter_objects(socket, reset, page) do
    s = socket.assigns.search

    objects =
      if s.sdate == "" or s.edate == "" do
        []
      else
        PunchGate.list_ingest_logs(
          socket.assigns.current_company,
          socket.assigns.current_user,
          emp_name: s.emp_name,
          device_name: s.device_name,
          sdate: s.sdate,
          edate: s.edate,
          outcome: s.outcome,
          page: page,
          per_page: @per_page
        )
      end

    socket
    |> assign(page: page, per_page: @per_page)
    |> stream(:objects, objects, reset: reset)
    |> assign(end_of_timeline?: Enum.count(objects) < @per_page)
  end

  defp outcome_options do
    [
      {gettext("All"), "all"},
      {gettext("Accepted"), "accepted"},
      {gettext("Replayed"), "replayed"},
      {gettext("Duplicate"), "duplicate"},
      {gettext("Rejected"), "rejected"}
    ]
  end

  defp outcome_label("accepted"), do: gettext("Accepted")
  defp outcome_label("replayed"), do: gettext("Replayed")
  defp outcome_label("duplicate"), do: gettext("Duplicate")
  defp outcome_label("rejected"), do: gettext("Rejected")
  defp outcome_label(other), do: other

  defp outcome_class("accepted"), do: "text-green-700 dark:text-green-400"
  defp outcome_class("replayed"), do: "text-blue-700 dark:text-blue-400"
  defp outcome_class("duplicate"), do: "text-amber-700 dark:text-amber-400"
  defp outcome_class(_), do: "text-rose-700 dark:text-rose-400"

  defp reason_label("not_found"), do: gettext("Unknown Badge")
  defp reason_label("inactive"), do: gettext("Not Active")
  defp reason_label("too_large"), do: gettext("Photo Too Large")
  defp reason_label("missing_photo"), do: gettext("No Photo")
  defp reason_label("future"), do: gettext("Future Time")
  defp reason_label("invalid"), do: gettext("Invalid")
  defp reason_label("revoked"), do: gettext("Device Revoked")
  defp reason_label(other), do: other

  defp photo_src(%{photo_path: path, id: id}, company) when is_binary(path),
    do: ~p"/companies/#{company.id}/punch_ingest_logs/#{id}/photo"

  defp photo_src(%{time_attendence_id: ta_id}, company) when is_binary(ta_id),
    do: ~p"/companies/#{company.id}/TimeAttend/#{ta_id}/photo"

  defp photo_src(_obj, _company), do: nil

  defp local_time(nil, _company), do: ""

  defp local_time(%DateTime{} = dt, company) do
    dt
    |> DateTime.shift_zone!(company.timezone)
    |> Calendar.strftime("%d-%m-%Y %H:%M:%S")
  end
end
```

- [ ] **Step 5: Add the dashboard link**

`lib/full_circle_web/live/dashboard_live/dashboard_live.ex`, right after the Punch Devices link (line 120's closing `</.link>`):

```elixir
        <.link
          :if={
            FullCircle.Authorization.can?(
              @current_user,
              :view_punch_ingest_log,
              @current_company
            )
          }
          navigate={~p"/companies/#{@current_company.id}/punch_ingest_logs"}
          class="button orange"
        >
          {gettext("Punch Ingest Log")}
        </.link>
```

- [ ] **Step 6: Run the test**

Run: `mix test test/full_circle_web/live/punch_ingest_log_live_test.exs`
Expected: PASS.

- [ ] **Step 7: Extract and translate the new strings**

```bash
mix gettext.extract --merge
```

Then open `priv/gettext/zh/LC_MESSAGES/default.po` and fill in the new msgids. Use these:

| msgid | zh msgstr |
|---|---|
| `Punch Ingest Log` | `打卡上传记录` |
| `Employee or Badge` | `员工或工牌` |
| `Device` | `设备` |
| `Received From` | `接收日期从` |
| `Received To` | `接收日期到` |
| `Received At` | `接收时间` |
| `Punch Time` | `打卡时间` |
| `Outcome` | `结果` |
| `Status` | `状态` |
| `All` | `全部` |
| `Accepted` | `已接受` |
| `Replayed` | `重复提交` |
| `Duplicate` | `重复打卡` |
| `Rejected` | `已拒绝` |
| `Unknown Badge` | `工牌不明` |
| `Not Active` | `员工非在职` |
| `Photo Too Large` | `照片过大` |
| `No Photo` | `没有照片` |
| `Future Time` | `时间在未来` |
| `Invalid` | `无效` |
| `Device Revoked` | `设备已注销` |

Some of these msgids (`Device`, `Status`, `All`, `Employee`, `Punch photo`) may already exist with a translation — if so leave the existing entry alone and only fill genuinely new ones.

- [ ] **Step 8: See it in the browser**

```bash
mix phx.server
```

Open `/companies/<id>/punch_ingest_logs`. Confirm: today's rows load, the outcome dropdown filters, **Show photos** reveals reject faces with no re-query, and the page reads correctly in both light and dark theme (toggle the `.dark` class on `<html>` in devtools).

- [ ] **Step 9: Format and commit**

```bash
mix format lib/full_circle_web/live/punch_ingest_log_live/index.ex \
  lib/full_circle_web/router.ex \
  lib/full_circle_web/live/dashboard_live/dashboard_live.ex \
  test/full_circle_web/live/punch_ingest_log_live_test.exs
git add -A
git commit -m "feat(punch-gate): read-only Punch Ingest Log page

"
```

---

## Task 9: Skill update and full-suite verification

**Files:**
- Modify: `.claude/skills/qr-gate-punch.md`

- [ ] **Step 1: Add the section to the skill**

Insert into `.claude/skills/qr-gate-punch.md`, after the pairing paragraph and before `## Building & installing the APK`:

```markdown
## Where a missing punch went

Punch IO shows what was **recorded**. `punch_ingest_logs` shows what **arrived** —
one append-only row per gate POST the server can attribute to a company, written
best-effort *after* the punch is decided so it can never cost a punch.

- **Page:** `/companies/:id/punch_ingest_logs`, `:view_punch_ingest_log`
  (admin/manager/supervisor/**clerk** — clerks still cannot pair or edit punches).
- **Outcomes:** `accepted`, `replayed` (same device + `client_id` — two code paths,
  the `existing_client` short-circuit *and* the unique-index race in
  `resolve_client_conflict/3`), `duplicate` (±3 min), `rejected` + a reason.
- **Reasons:** `not_found`, `inactive`, `too_large`, `missing_photo`, `future`,
  `invalid`, `revoked`.
- **`revoked` is the one 401 that gets logged.** A revoked token still resolves to a
  company, and the APK drops 4xx, so re-pairing a gate on a new phone makes the old
  phone discard punches silently. `PunchDeviceAuth` logs those — **POSTs only**, since
  the same plug fronts the 20-second `/health` ping. An unknown token is never logged:
  there is no company to scope it to.
- **Reject/duplicate faces** live at
  `{uploads_dir}/{company_id}/punch_ingest_logs/{yyyy}/{mm}/{log_id}.jpg` and are served
  by `PunchIngestLogPhotoController` (403, never a redirect, for a member without the
  role). Accepted faces are **not** copied — they stay on `time_attendences` for 24
  months. There is a JPEG for every outcome except `accepted`, `replayed`,
  `missing_photo`, `too_large`, and `revoked`.
- **Retention:** 3 calendar months, `IngestLogPruner` (a supervised GenServer, same
  shape as `PhotoPruner`; there is no Oban here). It deletes **rows**, not just files.
- **Nothing at all in the table** means the POST never reached `ingest_punch` and the
  token matched no device: network, DNS, TLS, or an unpaired phone.

`punch_ingest_logs` is not `logs` — no `user_id`, never goes through `StdInterface`.
Statuses come from `PunchGate.http_status_for/1`, which the controller also uses; do
not hardcode a status in either place.
```

- [ ] **Step 2: Run the whole suite**

```bash
mix test
```
Expected: PASS, with no failures anywhere — in particular `punch_gate_test.exs`, `punch_attendance_controller_test.exs`, `punch_photo_controller_test.exs`, `punch_query_photo_test.exs`, and `punch_device_live_test.exs`, which together prove the gate contract did not move.

If anything fails, fix it before committing — do not commit a red suite.

- [ ] **Step 3: Commit**

```bash
git add -A
git commit -m "docs(skills): record where a missing gate punch shows up

"
```

---

## Self-review notes

- **Spec coverage:** table + constraints + indexes (T1), `punched_at` as `:timestamptz` (T1), outcome map incl. both replay paths and the flat JPEG rule (T2, T3), truncation (T2), `http_status_for/1` including `:revoked` (T1), controller wired to that function (T1), best-effort `{:error, changeset}` + rescue (T2/T3), id-before-row photo write (T3), revoked 401 with `client_id`/`punched_at` + POST-only guard (T4), 3-month calendar pruner + `config.exs` knobs (T5), `:view_punch_ingest_log` + `list_ingest_logs` itself returns `:not_authorise` + local day range (T6), 403-not-redirect photo route (T7), list page with filters/infinite scroll/photo toggle + dashboard link + en/zh (T8), skill paragraph (T9).
- **Known gap carried from the spec, deliberately not closed:** `PunchPhotoController` has no role check, so a cashier can still fetch an accepted face at `/TimeAttend/:id/photo` by URL. Gating that shipped route is a separate decision and is out of scope here.
- **Not built:** `docs` for a UI prune button, any edit/delete path, and any change to `PhotoPruner` or the 24-month TimeAttend window — all explicit non-goals.
