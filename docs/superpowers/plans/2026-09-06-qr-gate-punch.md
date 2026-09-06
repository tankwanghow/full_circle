# QR Gate Punch Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Land live QR punches from a paired, wall-mounted Android phone into `time_attendences` (with an audit face photo and inferred IN/OUT), so Punch IO / Punch Card / PaySlip keep working and fingerprint import can stay until the gate is proven.

**Architecture:** Full Circle owns devices, ingest, flag rebuild, badge print, and photo review. A small Kotlin APK (`android/qr_gate/`) only scans, queues, and POSTs. Device Bearer token — never a logged-in ERP user on the phone. No web kiosk, no Face ID, no personal-phone QR.

**Tech Stack:** Elixir 1.19 / Phoenix 1.8 / LiveView 1.1, Ecto, PostgreSQL, Plug multipart; Android Kotlin minSdk 26, CameraX, ML Kit barcode, Room, WorkManager, OkHttp.

**Spec:** `docs/superpowers/specs/2026-09-06-qr-gate-punch-design.md`

## Global Constraints

- Do **not** revive `/PunchCamera`, the `punch_camera` role, Face ID, `employee_photos`, or face descriptors.
- Employee self-service QR on a personal phone is **forbidden**.
- Fingerprint import / `punch_card_id` path is **unchanged**.
- Punches: `input_medium = "QRGate"`, `user_id = nil`, `punch_device_id` set, `photo_path` set.
- Badge QR payload: `"fcqa:" <> employee_id`. Scanner also accepts a bare UUID that belongs to the company.
- IN/OUT is inferred on the server for that employee’s **calendar day** in the **company timezone**, order by `punch_time`. Flags cycle `1_IN_1`, `1_OUT_1`, `2_IN_2`, `2_OUT_2`, `3_IN_3`, `3_OUT_3`.
- Duplicate: same employee, any gate of that company, within **3 minutes** → 409.
- Photo is **required**; JPEG on disk under `{uploads_dir}/{company_id}/punch_photos/{yyyy}/{mm}/{id}.jpg`, cap **300 KB**.
- Pairing QR: `fcpair:<device_id>:<plain_token>:<api_base_url>`. Store **SHA-256 hex** of the token, never the plaintext after the pairing screen.
- Auth for pairing UI: new `can?(user, :manage_punch_device, company)` = admin / manager / supervisor (**not** clerk). Spec said `:update_employee` but that includes clerk; clerks only review photos.
- API pipeline is **not** `fetch_api_user`. New device-token plug.
- Android: front camera, two-step QR then face, kiosk, local queue, punch time = scan time.
- Runtime: Elixir 1.19.5, OTP 28, Phoenix 1.8. Sideload APK; no Play Store in v1.

---

## File Structure

- **Create** `priv/repo/migrations/20260906120000_create_punch_devices.exs` — `punch_devices` + `time_attendences.punch_device_id`, `photo_path`, `client_id`.
- **Create** `lib/full_circle/punch_gate/punch_device.ex` — schema.
- **Create** `lib/full_circle/punch_gate.ex` — create/revoke device, token lookup, ingest, flag rebuild, photo path helper.
- **Modify** `lib/full_circle/HR/timeattend.ex` — add `punch_device_id`, `photo_path`, `client_id` fields (no kiosk changeset).
- **Modify** `lib/full_circle/authorization.ex` — `can?(user, :manage_punch_device, company)`.
- **Create** `lib/full_circle_web/plugs/punch_device_auth.ex` — Bearer → device + company.
- **Create** `lib/full_circle_web/controllers/punch_attendance_controller.ex` — `POST /api/punch/attendances`.
- **Create** `lib/full_circle_web/controllers/punch_photo_controller.ex` — `GET .../TimeAttend/:id/photo`.
- **Modify** `lib/full_circle_web/router.ex` — punch API pipeline + live `/punch_devices` + photo GET.
- **Create** `lib/full_circle_web/live/punch_device_live/index.ex` — list / create (show pairing QR once) / revoke.
- **Modify** `lib/full_circle_web/live/employee_live/print.ex` — QR payload `fcqa:<id>`.
- **Modify** `lib/full_circle/hr.ex` — `emp_time_list` SQL includes `photo_path` and device name.
- **Modify** `lib/full_circle_web/live/helpers.ex` + `punch_time_component.ex` — photo camera icon.
- **Modify** `lib/full_circle_web/live/dashboard_live/dashboard_live.ex` — Punch devices link.
- **Create** `test/full_circle/punch_gate_test.exs`, `test/full_circle_web/controllers/punch_attendance_controller_test.exs`, `test/full_circle_web/controllers/punch_photo_controller_test.exs`, `test/full_circle_web/live/punch_device_live_test.exs`.
- **Create** `android/qr_gate/` — Kotlin scanner APK.
- **Create** `.claude/skills/qr-gate-punch.md` — domain contract for later sessions.

Do **not** grow `hr.ex` with ingest. Punch Card SQL only gains two extra `array_agg` fields.

---

### Task 1: Schema and PunchDevice

**Files:**
- Create: `priv/repo/migrations/20260906120000_create_punch_devices.exs`
- Create: `lib/full_circle/punch_gate/punch_device.ex`
- Modify: `lib/full_circle/HR/timeattend.ex`
- Test: `test/full_circle/punch_gate_test.exs` (schema compile + unique name — expand in Task 2)

**Interfaces:**
- Consumes: `FullCircle.Schema`, existing `time_attendences` / `companies` / `users`
- Produces: `FullCircle.PunchGate.PunchDevice` schema; TimeAttend fields `:punch_device_id`, `:photo_path`, `:client_id`

- [ ] **Step 1: Write the failing test**

`test/full_circle/punch_gate_test.exs`:

```elixir
defmodule FullCircle.PunchGateTest do
  use FullCircle.DataCase

  alias FullCircle.PunchGate
  alias FullCircle.PunchGate.PunchDevice

  import FullCircle.UserAccountsFixtures
  import FullCircle.SysFixtures

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
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/full_circle/punch_gate_test.exs`
Expected: FAIL — `FullCircle.PunchGate.PunchDevice` undefined.

- [ ] **Step 3: Migration + schema**

`priv/repo/migrations/20260906120000_create_punch_devices.exs`:

```elixir
defmodule FullCircle.Repo.Migrations.CreatePunchDevices do
  use Ecto.Migration

  def change do
    create table(:punch_devices) do
      add :name, :string, null: false
      add :token_hash, :string, null: false
      add :revoked_at, :utc_datetime
      add :last_seen_at, :utc_datetime
      add :company_id, references(:companies, on_delete: :delete_all), null: false
      add :paired_by_user_id, references(:users, on_delete: :nilify_all)

      timestamps(type: :timestamptz)
    end

    create unique_index(:punch_devices, [:company_id, :name])
    create unique_index(:punch_devices, [:token_hash])
    create index(:punch_devices, [:company_id])

    alter table(:time_attendences) do
      add :punch_device_id, references(:punch_devices, on_delete: :nilify_all)
      add :photo_path, :string
      add :client_id, :string
    end

    create unique_index(:time_attendences, [:punch_device_id, :client_id],
             where: "client_id IS NOT NULL"
           )
  end
end
```

`lib/full_circle/punch_gate/punch_device.ex`:

```elixir
defmodule FullCircle.PunchGate.PunchDevice do
  use FullCircle.Schema
  import Ecto.Changeset
  use Gettext, backend: FullCircleWeb.Gettext

  schema "punch_devices" do
    field :name, :string
    field :token_hash, :string
    field :revoked_at, :utc_datetime
    field :last_seen_at, :utc_datetime
    belongs_to :company, FullCircle.Sys.Company
    belongs_to :paired_by_user, FullCircle.UserAccounts.User

    timestamps(type: :utc_datetime)
  end

  def changeset(device, attrs) do
    device
    |> cast(attrs, [
      :name,
      :token_hash,
      :revoked_at,
      :last_seen_at,
      :company_id,
      :paired_by_user_id
    ])
    |> validate_required([:name, :token_hash, :company_id])
    |> unique_constraint([:company_id, :name],
      name: :punch_devices_company_id_name_index,
      message: gettext("has already been taken")
    )
  end
end
```

In `lib/full_circle/HR/timeattend.ex` schema, add after `field(:status, ...)`:

```elixir
    field(:photo_path, :string)
    field(:client_id, :string)
    belongs_to(:punch_device, FullCircle.PunchGate.PunchDevice)
```

Do **not** add these to `data_entry_changeset` / `finger_print_log_changeset`.

- [ ] **Step 4: Migrate and run the test**

Run: `mix ecto.migrate && mix test test/full_circle/punch_gate_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add priv/repo/migrations/20260906120000_create_punch_devices.exs \
  lib/full_circle/punch_gate/punch_device.ex lib/full_circle/HR/timeattend.ex \
  test/full_circle/punch_gate_test.exs
git commit -m "feat(punch-gate): punch_devices table and attendence photo/client columns"
```

---

### Task 2: Create / revoke device and token hash

**Files:**
- Create: `lib/full_circle/punch_gate.ex`
- Modify: `lib/full_circle/authorization.ex`
- Modify: `test/full_circle/punch_gate_test.exs`
- Modify: `test/full_circle/authorization_test.exs`

**Interfaces:**
- Consumes: `PunchDevice.changeset/2`
- Produces:
  - `PunchGate.hash_token/1 :: String.t() -> String.t()`
  - `PunchGate.create_device(name, company, user) :: {:ok, {device, plain_token}} | {:error, changeset} | :not_authorise`
  - `PunchGate.revoke_device(device, company, user) :: {:ok, device} | :not_authorise`
  - `PunchGate.get_active_device_by_token(plain) :: PunchDevice | nil` (preloads `:company`)
  - `can?(user, :manage_punch_device, company)` → admin/manager/supervisor only

- [ ] **Step 1: Write the failing tests**

Append to `test/full_circle/punch_gate_test.exs`:

```elixir
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
```

In `test/full_circle/authorization_test.exs` add:

```elixir
  test_authorise_to(:manage_punch_device, ["admin", "manager", "supervisor"])
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/full_circle/punch_gate_test.exs test/full_circle/authorization_test.exs:14`
Expected: FAIL — `PunchGate.create_device/3` undefined / no `can?` clause.

- [ ] **Step 3: Implement**

In `lib/full_circle/authorization.ex` next to the employee clauses:

```elixir
  def can?(user, :manage_punch_device, company),
    do: allow_roles(~w(admin manager supervisor), company, user)
```

`lib/full_circle/punch_gate.ex`:

```elixir
defmodule FullCircle.PunchGate do
  import Ecto.Query, warn: false
  alias FullCircle.Repo
  alias FullCircle.PunchGate.PunchDevice
  alias FullCircle.Authorization
  alias FullCircle.HR.{TimeAttend, Employee}

  def hash_token(plain) when is_binary(plain) do
    :crypto.hash(:sha256, plain) |> Base.encode16(case: :lower)
  end

  def create_device(name, company, user) do
    case Authorization.can?(user, :manage_punch_device, company) do
      true ->
        plain = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)

        %PunchDevice{}
        |> PunchDevice.changeset(%{
          name: name,
          token_hash: hash_token(plain),
          company_id: company.id,
          paired_by_user_id: user.id
        })
        |> Repo.insert()
        |> case do
          {:ok, device} -> {:ok, {device, plain}}
          {:error, cs} -> {:error, cs}
        end

      false ->
        :not_authorise
    end
  end

  def revoke_device(%PunchDevice{} = device, company, user) do
    case Authorization.can?(user, :manage_punch_device, company) and
           device.company_id == company.id do
      true ->
        device
        |> PunchDevice.changeset(%{
          revoked_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })
        |> Repo.update()

      false ->
        :not_authorise
    end
  end

  def get_active_device_by_token(plain) when is_binary(plain) do
    from(d in PunchDevice,
      where: d.token_hash == ^hash_token(plain),
      where: is_nil(d.revoked_at),
      preload: [:company]
    )
    |> Repo.one()
  end

  def list_devices(company, user) do
    case Authorization.can?(user, :manage_punch_device, company) do
      true ->
        from(d in PunchDevice,
          where: d.company_id == ^company.id,
          order_by: [asc: d.name]
        )
        |> Repo.all()

      false ->
        :not_authorise
    end
  end
end
```

Leave ingest functions for Task 3.

- [ ] **Step 4: Run tests**

Run: `mix test test/full_circle/punch_gate_test.exs test/full_circle/authorization_test.exs`
Expected: PASS (authorization file also has the new `test_authorise_to`).

- [ ] **Step 5: Commit**

```bash
git add lib/full_circle/punch_gate.ex lib/full_circle/authorization.ex \
  test/full_circle/punch_gate_test.exs test/full_circle/authorization_test.exs
git commit -m "feat(punch-gate): pair and revoke devices with hashed tokens"
```

---

### Task 3: Ingest punch, photo file, flag rebuild

**Files:**
- Modify: `lib/full_circle/punch_gate.ex`
- Modify: `test/full_circle/punch_gate_test.exs`

**Interfaces:**
- Consumes: `create_device/3`, `Employee`, `TimeAttend`, `uploads_dir`
- Produces:
  - `PunchGate.ingest_punch(device, attrs) :: {:ok, TimeAttend} | {:error, atom}`
  - `attrs` keys (strings or atoms): `employee_id`, `punched_at` (`DateTime`), `photo` (`Plug.Upload` or `%{path: path}`), `client_id`
  - Error atoms: `:not_found`, `:inactive`, `:duplicate`, `:missing_photo`, `:future`, `:too_large`, `:invalid`
  - `PunchGate.photo_abs_path(company_id, %TimeAttend{})`
  - `PunchGate.rebuild_day_flags(employee_id, company, punched_at)`

- [ ] **Step 1: Write the failing tests**

Append (need `HRFixtures.employee_fixture` and a tiny JPEG file):

```elixir
  import FullCircle.HRFixtures

  defp jpeg_upload do
    path = Path.join(System.tmp_dir!(), "face-#{System.unique_integer()}.jpg")
    # minimal JPEG (1x1)
    File.write!(path, Base.decode64!("/9j/4AAQSkZJRgABAQEASABIAAD/2wBDAP//////////////////////////////////////////////////////////////////////////////////////wgALCAABAAEBAREA/8QAFBABAAAAAAAAAAAAAAAAAAAAAP/aAAgBAQABPxA="))
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
      PunchGate.ingest_punch(device, ingest_attrs(emp, %{"punched_at" => DateTime.add(t0, 9 * 3600)}))
    {:ok, second} =
      PunchGate.ingest_punch(device, ingest_attrs(emp, %{"punched_at" => DateTime.add(t0, 8 * 3600)}))
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/full_circle/punch_gate_test.exs`
Expected: FAIL — `ingest_punch/2` undefined.

- [ ] **Step 3: Implement ingest + flag rebuild**

Add to `lib/full_circle/punch_gate.ex`:

```elixir
  @flags ~w(1_IN_1 1_OUT_1 2_IN_2 2_OUT_2 3_IN_3 3_OUT_3)
  @dup_seconds 180
  @future_leeway_seconds 120
  @max_photo_bytes 300_000

  def ingest_punch(%PunchDevice{} = device, attrs) do
    device = Repo.preload(device, :company)
    company = device.company
    employee_id = to_string(attrs["employee_id"] || attrs[:employee_id] || "")
    client_id = attrs["client_id"] || attrs[:client_id]
    punched_at = attrs["punched_at"] || attrs[:punched_at]
    photo = attrs["photo"] || attrs[:photo]

    with :ok <- validate_photo(photo),
         {:ok, punched_at} <- parse_punched_at(punched_at),
         :ok <- validate_not_future(punched_at),
         %Employee{} = emp <- get_company_employee(employee_id, company.id),
         :ok <- validate_active(emp),
         :ok <- reject_duplicate(emp.id, company.id, punched_at) do
      case existing_client(device.id, client_id) do
        %TimeAttend{} = ta ->
          {:ok, ta}

        nil ->
          insert_punch(device, emp, company, punched_at, client_id, photo)
      end
    end
  end

  def photo_abs_path(company_id, %TimeAttend{id: id, punch_time: pt}) do
    %{year: y, month: m} = DateTime.shift_zone!(pt, "Etc/UTC")
    Path.join([
      Application.get_env(:full_circle, :uploads_dir),
      "#{company_id}",
      "punch_photos",
      "#{y}",
      "#{m |> Integer.to_string() |> String.pad_leading(2, "0")}",
      "#{id}.jpg"
    ])
  end

  def rebuild_day_flags(employee_id, company, %DateTime{} = punched_at) do
    tz = company.timezone
    local = DateTime.shift_zone!(punched_at, tz)
    start_local = %{local | hour: 0, minute: 0, second: 0, microsecond: {0, 0}}
    start_utc = DateTime.shift_zone!(start_local, "Etc/UTC")
    end_utc = DateTime.add(start_utc, 24 * 3600 - 1, :second)

    rows =
      from(ta in TimeAttend,
        where: ta.employee_id == ^employee_id,
        where: ta.company_id == ^company.id,
        where: ta.punch_time >= ^start_utc and ta.punch_time <= ^end_utc,
        order_by: [asc: ta.punch_time, asc: ta.flag]
      )
      |> Repo.all()

    rows
    |> Enum.with_index()
    |> Enum.each(fn {ta, i} ->
      flag = Enum.at(@flags, rem(i, length(@flags)))
      if ta.flag != flag do
        ta |> Ecto.Changeset.change(%{flag: flag}) |> Repo.update!()
      end
    end)

    :ok
  end

  defp insert_punch(device, emp, company, punched_at, client_id, photo) do
    Ecto.Multi.new()
    |> Ecto.Multi.insert(
      :ta,
      TimeAttend.changeset_gate(%TimeAttend{}, %{
        employee_id: emp.id,
        company_id: company.id,
        punch_device_id: device.id,
        punch_time: punched_at,
        input_medium: "QRGate",
        flag: "1_IN_1",
        status: "Draft",
        client_id: client_id
      })
    )
    |> Ecto.Multi.run(:photo, fn _repo, %{ta: ta} ->
      abs = photo_abs_path(company.id, ta)
      File.mkdir_p!(Path.dirname(abs))
      File.cp!(photo_src(photo), abs)
      rel = Path.relative_to(abs, Application.get_env(:full_circle, :uploads_dir))
      ta |> Ecto.Changeset.change(%{photo_path: rel}) |> Repo.update()
    end)
    |> Ecto.Multi.run(:flags, fn _repo, %{photo: ta} ->
      rebuild_day_flags(emp.id, company, punched_at)
      {:ok, Repo.get!(TimeAttend, ta.id)}
    end)
    |> Ecto.Multi.update(:seen, fn _ ->
      PunchDevice.changeset(device, %{
        last_seen_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{flags: ta}} -> {:ok, Repo.preload(ta, :employee)}
      {:error, _, reason, _} -> {:error, reason}
    end
  end

  defp photo_src(%Plug.Upload{path: p}), do: p
  defp photo_src(%{path: p}), do: p

  defp validate_photo(nil), do: {:error, :missing_photo}
  defp validate_photo(photo) do
    src = photo_src(photo)
    case File.stat(src) do
      {:ok, %{size: n}} when n > 0 and n <= @max_photo_bytes -> :ok
      {:ok, %{size: n}} when n > @max_photo_bytes -> {:error, :too_large}
      _ -> {:error, :missing_photo}
    end
  end

  defp parse_punched_at(%DateTime{} = dt), do: {:ok, DateTime.truncate(dt, :second)}
  defp parse_punched_at(s) when is_binary(s) do
    case DateTime.from_iso8601(s) do
      {:ok, dt, _} -> {:ok, DateTime.truncate(dt, :second)}
      _ -> {:error, :invalid}
    end
  end
  defp parse_punched_at(_), do: {:error, :invalid}

  defp validate_not_future(%DateTime{} = dt) do
    if DateTime.diff(dt, DateTime.utc_now()) > @future_leeway_seconds,
      do: {:error, :future},
      else: :ok
  end

  defp get_company_employee(id, company_id) do
    Repo.get_by(Employee, id: id, company_id: company_id) || {:error, :not_found}
  end

  defp validate_active(%Employee{status: "Active"}), do: :ok
  defp validate_active(_), do: {:error, :inactive}

  defp reject_duplicate(emp_id, company_id, punched_at) do
    from_t = DateTime.add(punched_at, -@dup_seconds, :second)
    to_t = DateTime.add(punched_at, @dup_seconds, :second)

    exists? =
      from(ta in TimeAttend,
        where: ta.employee_id == ^emp_id,
        where: ta.company_id == ^company_id,
        where: ta.punch_time >= ^from_t and ta.punch_time <= ^to_t
      )
      |> Repo.exists?()

    if exists?, do: {:error, :duplicate}, else: :ok
  end

  defp existing_client(_device_id, nil), do: nil
  defp existing_client(device_id, client_id) do
    Repo.get_by(TimeAttend, punch_device_id: device_id, client_id: client_id)
  end
```

Add `TimeAttend.changeset_gate/2` in `lib/full_circle/HR/timeattend.ex` (do **not** run the deleted kiosk `validate_punch_time`):

```elixir
  def changeset_gate(st, attrs) do
    st
    |> cast(attrs, [
      :flag,
      :input_medium,
      :punch_time,
      :company_id,
      :employee_id,
      :punch_device_id,
      :client_id,
      :status
    ])
    |> validate_required([
      :flag,
      :input_medium,
      :punch_time,
      :company_id,
      :employee_id,
      :punch_device_id,
      :client_id
    ])
  end
```

`with` in `ingest_punch` must convert `{:error, :not_found}` from `get_company_employee`. The `|| {:error, :not_found}` already does. Elixir `with` does not match `{:error, _}` unless you add else. Add:

```elixir
    else
      {:error, reason} -> {:error, reason}
    end
```

Fix `photo_abs_path` to use company timezone month/year from `punch_time` converted to company TZ — after insert `punch_time` is UTC. Using UTC y/m in the path is fine and stable; keep UTC in the path (simpler, no TZ bugs). Update the function:

```elixir
  def photo_abs_path(company_id, %TimeAttend{id: id, punch_time: pt}) do
    date = DateTime.to_date(pt)
    Path.join([
      Application.get_env(:full_circle, :uploads_dir),
      "#{company_id}",
      "punch_photos",
      "#{date.year}",
      date.month |> Integer.to_string() |> String.pad_leading(2, "0"),
      "#{id}.jpg"
    ])
  end
```

`DateTime.shift_zone!/2` requires `tzdata`. Company fixture timezone is `Asia/Kuala_Lumpur`. For `rebuild_day_flags`, converting UTC → company TZ then taking local midnight is correct. Use:

```elixir
    {:ok, local} = DateTime.shift_zone(punched_at, tz)
```

If `shift_zone` needs a DateTime with zone, `DateTime.from_naive!(DateTime.to_naive(punched_at), "Etc/UTC")` then shift. `~U[...]` already has UTC.

`rebuild_day_flags` day window: local date D 00:00:00 in company TZ, convert that instant to UTC, through D+1 00:00 UTC-equivalent. Implementation:

```elixir
    {:ok, local} = DateTime.shift_zone(punched_at, tz)
    d = DateTime.to_date(local)
    {:ok, start_local} = DateTime.new(d, ~T[00:00:00], tz)
    start_utc = DateTime.shift_zone!(start_local, "Etc/UTC")
    end_utc = DateTime.add(start_utc, 86400, :second)
    # where: ta.punch_time >= start_utc and ta.punch_time < end_utc
```

Use `< end_utc` not `<= end-1s`.

Employee preload: `belongs_to :employee` already on TimeAttend. After ingest tests assert `ta.flag`. Preload employee for the controller later: `Repo.preload(ta, :employee)`.

`insert_punch` Multi `:seen` must not fail the punch if last_seen update fails — keep it simple, include it.

`TimeAttend` needs `belongs_to :employee` already — yes.

- [ ] **Step 4: Run tests**

Run: `mix test test/full_circle/punch_gate_test.exs`
Expected: PASS.

Also run: `mix test test/full_circle/hr_test.exs`
Expected: PASS (fingerprint path untouched).

- [ ] **Step 5: Commit**

```bash
git add lib/full_circle/punch_gate.ex lib/full_circle/HR/timeattend.ex \
  test/full_circle/punch_gate_test.exs
git commit -m "feat(punch-gate): ingest QR punches, store photo, rebuild day flags"
```

---

### Task 4: Device-token API `POST /api/punch/attendances`

**Files:**
- Create: `lib/full_circle_web/plugs/punch_device_auth.ex`
- Create: `lib/full_circle_web/controllers/punch_attendance_controller.ex`
- Modify: `lib/full_circle_web/router.ex`
- Test: `test/full_circle_web/controllers/punch_attendance_controller_test.exs`

**Interfaces:**
- Consumes: `PunchGate.get_active_device_by_token/1`, `PunchGate.ingest_punch/2`
- Produces: HTTP 201 JSON `%{id, employee_name, flag, punch_time}`; 401/404/409/413/422 as spec

- [ ] **Step 1: Write the failing test**

`test/full_circle_web/controllers/punch_attendance_controller_test.exs`:

```elixir
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
    File.write!(path, Base.decode64!("/9j/4AAQSkZJRgABAQEASABIAAD/2wBDAP//////////////////////////////////////////////////////////////////////////////////////wgALCAABAAEBAREA/8QAFBABAAAAAAAAAAAAAAAAAAAAAP/aAAgBAQABPxA="))
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

  test "401 when revoked", %{conn: conn, token: token, device: device, company: company, admin: admin, emp: emp} do
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/full_circle_web/controllers/punch_attendance_controller_test.exs`
Expected: FAIL — no `/api/punch/attendances` route.

- [ ] **Step 3: Plug, controller, router**

`lib/full_circle_web/plugs/punch_device_auth.ex`:

```elixir
defmodule FullCircleWeb.PunchDeviceAuth do
  import Plug.Conn
  alias FullCircle.PunchGate

  def init(opts), do: opts

  def call(conn, _opts) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         %{} = device <- PunchGate.get_active_device_by_token(token) do
      conn
      |> assign(:punch_device, device)
      |> assign(:current_company, device.company)
    else
      _ ->
        conn
        |> send_resp(:unauthorized, "No access for you")
        |> halt()
    end
  end
end
```

`lib/full_circle_web/controllers/punch_attendance_controller.ex`:

```elixir
defmodule FullCircleWeb.PunchAttendanceController do
  use FullCircleWeb, :controller
  alias FullCircle.PunchGate

  def create(conn, params) do
    case PunchGate.ingest_punch(conn.assigns.punch_device, params) do
      {:ok, ta} ->
        ta = FullCircle.Repo.preload(ta, :employee)

        conn
        |> put_status(:created)
        |> json(%{
          id: ta.id,
          employee_name: ta.employee.name,
          flag: ta.flag,
          punch_time: DateTime.to_iso8601(ta.punch_time)
        })

      {:error, :not_found} ->
        send_resp(conn, 404, "not found")

      {:error, :inactive} ->
        send_resp(conn, 422, "inactive")

      {:error, :duplicate} ->
        send_resp(conn, 409, "duplicate")

      {:error, :too_large} ->
        send_resp(conn, 413, "too large")

      {:error, :missing_photo} ->
        send_resp(conn, 422, "missing photo")

      {:error, :future} ->
        send_resp(conn, 422, "future")

      {:error, _} ->
        send_resp(conn, 422, "invalid")
    end
  end
end
```

In `router.ex` **replace** the empty `/api` scope with:

```elixir
  pipeline :punch_api do
    plug :accepts, ["json", "multipart"]
    plug FullCircleWeb.PunchDeviceAuth
  end

  scope "/api", FullCircleWeb do
    pipe_through(:api)
  end

  scope "/api/punch", FullCircleWeb do
    pipe_through(:punch_api)
    post "/attendances", PunchAttendanceController, :create
  end
```

Keep the existing `:api` pipeline (`fetch_api_user`) unused by punch.

- [ ] **Step 4: Run tests**

Run: `mix test test/full_circle_web/controllers/punch_attendance_controller_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/full_circle_web/plugs/punch_device_auth.ex \
  lib/full_circle_web/controllers/punch_attendance_controller.ex \
  lib/full_circle_web/router.ex \
  test/full_circle_web/controllers/punch_attendance_controller_test.exs
git commit -m "feat(punch-gate): POST /api/punch/attendances with device token"
```

---

### Task 5: Serve punch photo

**Files:**
- Create: `lib/full_circle_web/controllers/punch_photo_controller.ex`
- Modify: `lib/full_circle_web/router.ex` (inside `/companies/:company_id` browser scope, next to `get "/csv"`)
- Test: `test/full_circle_web/controllers/punch_photo_controller_test.exs`

**Interfaces:**
- Consumes: `TimeAttend.photo_path`, `uploads_dir`
- Produces: `GET /companies/:company_id/TimeAttend/:id/photo` → JPEG; logged-out 302; other company 404

- [ ] **Step 1: Write the failing test**

```elixir
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
    File.write!(jpeg_path, Base.decode64!("/9j/4AAQSkZJRgABAQEASABIAAD/2wBDAP//////////////////////////////////////////////////////////////////////////////////////wgALCAABAAEBAREA/8QAFBABAAAAAAAAAAAAAAAAAAAAAP/aAAgBAQABPxA="))
    {:ok, ta} =
      PunchGate.ingest_punch(device, %{
        "employee_id" => emp.id,
        "punched_at" => DateTime.utc_now() |> DateTime.truncate(:second),
        "client_id" => Ecto.UUID.generate(),
        "photo" => %Plug.Upload{path: jpeg_path, filename: "face.jpg", content_type: "image/jpeg"}
      })
    %{conn: log_in_user(conn, admin) |> put_session(:current_company, company),
      company: company, ta: ta, admin: admin}
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/full_circle_web/controllers/punch_photo_controller_test.exs`
Expected: FAIL — no route.

- [ ] **Step 3: Controller + route**

```elixir
defmodule FullCircleWeb.PunchPhotoController do
  use FullCircleWeb, :controller
  alias FullCircle.{Repo, PunchGate}
  alias FullCircle.HR.TimeAttend

  def show(conn, %{"id" => id, "company_id" => company_id}) do
    ta = Repo.get_by(TimeAttend, id: id, company_id: company_id)

    cond do
      is_nil(ta) or is_nil(ta.photo_path) ->
        send_resp(conn, 404, "not found")

      true ->
        abs = Path.join(Application.get_env(:full_circle, :uploads_dir), ta.photo_path)
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

`photo_abs_path` joins `uploads_dir` + company + punch_photos + …; `photo_path` on the row should be the **relative** path stored at ingest (`Path.relative_to`). Confirm Task 3 stores relative path. Controller joins `uploads_dir` + `photo_path`.

Router, in `scope "/companies/:company_id"` `pipe_through [:browser, :require_authenticated_user]`:

```elixir
    get "/TimeAttend/:id/photo", PunchPhotoController, :show
```

- [ ] **Step 4: Run tests**

Run: `mix test test/full_circle_web/controllers/punch_photo_controller_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/full_circle_web/controllers/punch_photo_controller.ex \
  lib/full_circle_web/router.ex \
  test/full_circle_web/controllers/punch_photo_controller_test.exs
git commit -m "feat(punch-gate): authenticated punch photo download"
```

---

### Task 6: Punch devices LiveView

**Files:**
- Create: `lib/full_circle_web/live/punch_device_live/index.ex`
- Modify: `lib/full_circle_web/router.ex` (inside the company live_session)
- Modify: `lib/full_circle_web/live/dashboard_live/dashboard_live.ex`
- Test: `test/full_circle_web/live/punch_device_live_test.exs`

**Interfaces:**
- Consumes: `PunchGate.create_device/3`, `list_devices/2`, `revoke_device/3`
- Produces: pairing payload `fcpair:<device_id>:<plain_token>:<api_base_url>` shown once as QR (`QRCode` already a mix dep)

- [ ] **Step 1: Write the failing test**

```elixir
defmodule FullCircleWeb.PunchDeviceLiveTest do
  use FullCircleWeb.ConnCase

  import Phoenix.LiveViewTest
  import FullCircle.UserAccountsFixtures
  import FullCircle.SysFixtures

  setup %{conn: conn} do
    user = user_fixture()
    comp = company_fixture(user, %{})
    %{conn: log_in_user(conn, user), user: user, comp: comp}
  end

  test "lists empty and creates a device showing pairing QR", %{conn: conn, comp: comp} do
    {:ok, lv, html} = live(conn, ~p"/companies/#{comp.id}/punch_devices")
    assert html =~ "Punch Devices"

    html =
      lv
      |> form("#device-form", device: %{name: "Gate 1"})
      |> render_submit()

    assert html =~ "Gate 1"
    assert html =~ "fcpair:"
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/full_circle_web/live/punch_device_live_test.exs`
Expected: FAIL — no live route.

- [ ] **Step 3: LiveView + route + dashboard link**

`lib/full_circle_web/live/punch_device_live/index.ex`:

```elixir
defmodule FullCircleWeb.PunchDeviceLive.Index do
  use FullCircleWeb, :live_view
  alias FullCircle.PunchGate
  alias FullCircle.PunchGate.PunchDevice

  @impl true
  def mount(_params, _session, socket) do
    if PunchGate.list_devices(socket.assigns.current_company, socket.assigns.current_user) ==
         :not_authorise do
      {:ok,
       socket
       |> put_flash(:error, gettext("Not Authorized!"))
       |> push_navigate(to: "/companies/#{socket.assigns.current_company.id}/dashboard")}
    else
      {:ok,
       socket
       |> assign(page_title: gettext("Punch Devices"))
       |> assign(pairing: nil)
       |> assign(form: to_form(%{"name" => ""}, as: :device))
       |> load_devices()}
    end
  end

  defp load_devices(socket) do
    devices = PunchGate.list_devices(socket.assigns.current_company, socket.assigns.current_user)
    assign(socket, devices: devices)
  end

  @impl true
  def handle_event("create", %{"device" => %{"name" => name}}, socket) do
    case PunchGate.create_device(name, socket.assigns.current_company, socket.assigns.current_user) do
      {:ok, {device, plain}} ->
        base = FullCircleWeb.Endpoint.url()
        payload = "fcpair:#{device.id}:#{plain}:#{base}"
        svg =
          QRCode.create(payload, :high) |> QRCode.render(:svg) |> elem(1)

        {:noreply,
         socket
         |> assign(pairing: %{payload: payload, svg: svg, name: device.name})
         |> load_devices()
         |> put_flash(:success, gettext("Device created. Scan the QR with the gate phone now."))}

      {:error, cs} ->
        {:noreply, assign(socket, form: to_form(cs, as: :device))}

      :not_authorise ->
        {:noreply, put_flash(socket, :error, gettext("Not Authorized!"))}
    end
  end

  def handle_event("revoke", %{"id" => id}, socket) do
    device = Enum.find(socket.assigns.devices, &(&1.id == id))

    case PunchGate.revoke_device(device, socket.assigns.current_company, socket.assigns.current_user) do
      {:ok, _} -> {:noreply, socket |> load_devices() |> put_flash(:success, gettext("Revoked"))}
      _ -> {:noreply, put_flash(socket, :error, gettext("Not Authorized!"))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto w-8/12">
      <p class="w-full text-3xl text-center font-medium">{@page_title}</p>
      <.form for={@form} id="device-form" phx-submit="create" class="flex gap-2 justify-center mb-4">
        <.input field={@form[:name]} label={gettext("Gate name")} />
        <.button class="mt-5">{gettext("Pair new phone")}</.button>
      </.form>
      <div :if={@pairing} class="text-center mb-4 border p-4">
        <p class="font-bold">{@pairing.name}</p>
        <div class="inline-block">{raw(@pairing.svg)}</div>
        <p class="text-xs break-all">{@pairing.payload}</p>
        <p class="text-rose-600">{gettext("This code is shown once. Scan it on the gate phone now.")}</p>
      </div>
      <div :for={d <- @devices} class="flex justify-between border-b py-2">
        <div>
          {d.name}
          <span :if={d.revoked_at} class="text-rose-600">({gettext("revoked")})</span>
        </div>
        <button
          :if={is_nil(d.revoked_at)}
          phx-click="revoke"
          phx-value-id={d.id}
          class="red button"
        >
          {gettext("Revoke")}
        </button>
      </div>
    </div>
    """
  end
end
```

Router live_session: `live("/punch_devices", PunchDeviceLive.Index, :index)`

Dashboard payroll block, after Employees:

```heex
        <.link
          :if={FullCircle.Authorization.can?(@current_user, :manage_punch_device, @current_company)}
          navigate={~p"/companies/#{@current_company.id}/punch_devices"}
          class="button orange"
        >
          {gettext("Punch Devices")}
        </.link>
```

- [ ] **Step 4: Run tests**

Run: `mix test test/full_circle_web/live/punch_device_live_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/full_circle_web/live/punch_device_live/index.ex \
  lib/full_circle_web/router.ex \
  lib/full_circle_web/live/dashboard_live/dashboard_live.ex \
  test/full_circle_web/live/punch_device_live_test.exs
git commit -m "feat(punch-gate): pair/revoke gate phones in Punch Devices"
```

---

### Task 7: Badge print payload `fcqa:`

**Files:**
- Modify: `lib/full_circle_web/live/employee_live/print.ex` (the `QRCode.create` line)
- Test: add a case to `test/full_circle_web/live/` — if no employee print test exists, create `test/full_circle_web/live/employee_print_test.exs`

**Interfaces:**
- Consumes: `emp.id`
- Produces: QR content `"fcqa:" <> emp.id`

- [ ] **Step 1: Write the failing test**

```elixir
defmodule FullCircleWeb.EmployeePrintTest do
  use FullCircleWeb.ConnCase
  import Phoenix.LiveViewTest
  import FullCircle.UserAccountsFixtures
  import FullCircle.SysFixtures
  import FullCircle.HRFixtures

  test "badge QR encodes fcqa prefix", %{conn: conn} do
    user = user_fixture()
    comp = company_fixture(user, %{})
    emp = employee_fixture(%{}, comp, user)
    {:ok, _lv, html} = live(log_in_user(conn, user), ~p"/companies/#{comp.id}/employees/#{emp.id}/print")
    assert html =~ "fcqa:#{emp.id}"
  end
end
```

(If the SVG does not embed the raw string, decode is hard. Then assert in a unit helper instead: extract the payload into `PunchGate.badge_payload(emp)` and test that; print.ex calls it.)

Prefer a tiny helper so the test does not depend on SVG guts:

In `punch_gate.ex`:

```elixir
  def badge_payload(%{id: id}), do: "fcqa:#{id}"
  def parse_badge_payload("fcqa:" <> id), do: {:ok, id}
  def parse_badge_payload(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> :error
    end
  end
```

Test `badge_payload/1` and `parse_badge_payload/1` in `punch_gate_test.exs`. Print uses `PunchGate.badge_payload(emp)`.

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/full_circle/punch_gate_test.exs --only line` of the new test, or the whole file.
Expected: FAIL — function undefined.

- [ ] **Step 3: Implement helper + print.ex**

Replace in `print.ex`:

```elixir
          svg: QRCode.create(FullCircle.PunchGate.badge_payload(emp), :high) |> QRCode.render(:svg, svg_settings) |> elem(1)
```

- [ ] **Step 4: Run tests**

Run: `mix test test/full_circle/punch_gate_test.exs test/full_circle_web/live/employee_print_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/full_circle/punch_gate.ex lib/full_circle_web/live/employee_live/print.ex \
  test/full_circle/punch_gate_test.exs test/full_circle_web/live/employee_print_test.exs
git commit -m "feat(punch-gate): print employee badges as fcqa:<id>"
```

---

### Task 8: Punch IO photo icon

**Files:**
- Modify: `lib/full_circle/hr.ex` (`emp_time_list` `array_agg` and `unzip_time_list/1`)
- Modify: `lib/full_circle_web/live/helpers.ex` (`make_timeattend/3`)
- Modify: `lib/full_circle_web/live/time_attend_live/punch_time_component.ex`
- Test: extend `test/full_circle/hr_test.exs` if there is a punch_query test; otherwise add `test/full_circle/punch_query_photo_test.exs`

**Interfaces:**
- Consumes: `time_attendences.photo_path`, `punch_devices.name`
- Produces: `unzip_time_list` entries `[time, id, status, flag, photo_path, device_name]`; tuple `{time, id, status, flag, datetime, photo_path}` in the component

- [ ] **Step 1: Write the failing test**

```elixir
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
    File.write!(path, Base.decode64!("/9j/4AAQSkZJRgABAQEASABIAAD/2wBDAP//////////////////////////////////////////////////////////////////////////////////////wgALCAABAAEBAREA/8QAFBABAAAAAAAAAAAAAAAAAAAAAP/aAAgBAQABPxA="))
    {:ok, ta} =
      PunchGate.ingest_punch(device, %{
        "employee_id" => emp.id,
        "punched_at" => DateTime.utc_now() |> DateTime.truncate(:second),
        "client_id" => Ecto.UUID.generate(),
        "photo" => %Plug.Upload{path: path, filename: "f.jpg", content_type: "image/jpeg"}
      })
    row = HR.punch_query_by_id(emp.id, DateTime.to_date(DateTime.shift_zone!(ta.punch_time, company.timezone)), company)
    [first | _] = row.time_list
    assert length(first) >= 5
    assert Enum.at(first, 4) not in [nil, ""]
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/full_circle/punch_query_photo_test.exs`
Expected: FAIL — unzip still 4 fields / photo empty.

- [ ] **Step 3: SQL + unzip + UI**

In `hr.ex` `emp_time_list`, left join devices and extend `array_agg`:

```sql
array_agg(
  (ta.punch_time at time zone '#{com.timezone}')::varchar
  || '|' || ta.id::varchar
  || '|' || ta.status
  || '|' || ta.flag
  || '|' || coalesce(ta.photo_path, '')
  || '|' || coalesce(pd.name, '')
  order by ta.punch_time, ta.flag
) time_list
from time_attendences ta
left join punch_devices pd on pd.id = ta.punch_device_id
cross join date_series ds
```

Keep the existing `where ta.punch_time between ds.dd and ...` and `group by`.

`unzip_time_list/1`:

```elixir
  def unzip_time_list(tl) do
    if is_nil(tl) do
      []
    else
      tl
      |> Enum.map(fn x -> String.split(x, "|") end)
      |> Enum.map(fn
        [t, i, s, f, photo, gate] ->
          [Timex.parse!(t, "{RFC3339}"), i, s, f, photo, gate]
        [t, i, s, f] ->
          [Timex.parse!(t, "{RFC3339}"), i, s, f, "", ""]
      end)
    end
  end
```

`make_timeattend/3` currently `fn [_, _, _, inout]`. Change to `fn row -> Enum.at(row, 3) == flag end` and:

```elixir
      [time, id, status, inout | rest] = ti
      photo = Enum.at(rest, 0) || ""
      {Timex.format!(...), id, status, inout, Timex.to_datetime(time, com.timezone), photo}
```

Empty slots stay `{nil, "_new_...", "normal", flag, nil, ""}`.

`PunchTimeComponent` render:

```elixir
          <% {time, id, status, flag, datetime, photo} = pad_tis(o) %>
```

Add:

```elixir
  defp pad_tis({t, i, s, f, d}), do: {t, i, s, f, d, ""}
  defp pad_tis({t, i, s, f, d, p}), do: {t, i, s, f, d, p}
```

After the time `<input>`, if `photo != ""` and id is a real UUID:

```heex
            <.link
              :if={photo != "" and !String.starts_with?(id, "_new_")}
              href={~p"/companies/#{@company.id}/TimeAttend/#{id}/photo"}
              target="_blank"
              class="block text-center text-xs"
            >
              📷
            </.link>
```

Pass `@company` — PunchTimeComponent already has `company={@company}`.

Replace every 5-tuple construction in `punch_time_component.ex` (`List.replace_at`) with a 6th `""` or keep `pad_tis` on render only and leave internal tuples at 5. **Safer:** only pad at render; leave create/update tuples at 5 fields. `pad_tis` handles both.

- [ ] **Step 4: Run tests**

Run: `mix test test/full_circle/punch_query_photo_test.exs test/full_circle/hr_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/full_circle/hr.ex lib/full_circle_web/live/helpers.ex \
  lib/full_circle_web/live/time_attend_live/punch_time_component.ex \
  test/full_circle/punch_query_photo_test.exs
git commit -m "feat(punch-gate): show punch photo link on Punch IO"
```

---

### Task 9: Skill + CLAUDE.md

**Files:**
- Create: `.claude/skills/qr-gate-punch.md`
- Modify: `CLAUDE.md` (skills list + note punch devices; do not add `punch_camera` back)

- [ ] **Step 1: Write the skill** (no test)

```markdown
---
name: qr-gate-punch
description: Use when working on QR gate attendance — paired Android scanners, POST /api/punch/attendances, punch_devices, fcqa: badge QR, audit face photos on time_attendences, Punch IO photo link, or IN/OUT flag rebuild for a calendar day.
---

# QR Gate Punch

Company wall-mounted Android phones scan printed badges (`fcqa:<employee_id>`), take an audit face JPEG (no matching), and POST to `/api/punch/attendances` with a **device** Bearer token. Full Circle inserts `time_attendences` (`input_medium: QRGate`, `user_id` nil) and rebuilds that employee's IN/OUT flags for the local calendar day.

Do **not** revive `/PunchCamera`, `punch_camera` role, Face ID, or employee self-service QR.

Fingerprint import is unchanged until the gate is proven.

Pairing: `PunchGate.create_device/3` returns `{device, plain_token}` once. QR `fcpair:<id>:<token>:<url>`. Clerks cannot pair (`:manage_punch_device` = admin/manager/supervisor).

Photos: `{uploads_dir}/{company_id}/punch_photos/{yyyy}/{mm}/{id}.jpg`. Serve via `GET /companies/:id/TimeAttend/:id/photo`.
```

Add `qr-gate-punch.md` to the skills list in `CLAUDE.md`.

- [ ] **Step 2: Commit**

```bash
git add .claude/skills/qr-gate-punch.md CLAUDE.md
git commit -m "docs(skill): QR gate punch contract"
```

---

### Task 10: Android scanner APK (`android/qr_gate/`)

This task starts only after Tasks 1–5 are green (API curl-able). Mix tests do not cover the APK; verify with a wall-mounted phone against the local HTTPS server.

**Files (create all):**
- `android/qr_gate/settings.gradle.kts`
- `android/qr_gate/build.gradle.kts`
- `android/qr_gate/app/build.gradle.kts`
- `android/qr_gate/app/src/main/AndroidManifest.xml`
- `android/qr_gate/app/src/main/java/com/fullcircle/qrgate/PairingActivity.kt`
- `android/qr_gate/app/src/main/java/com/fullcircle/qrgate/ScanActivity.kt`
- `android/qr_gate/app/src/main/java/com/fullcircle/qrgate/data/QueueDb.kt`
- `android/qr_gate/app/src/main/java/com/fullcircle/qrgate/data/PunchDao.kt`
- `android/qr_gate/app/src/main/java/com/fullcircle/qrgate/data/PunchEntity.kt`
- `android/qr_gate/app/src/main/java/com/fullcircle/qrgate/net/UploadWorker.kt`
- `android/qr_gate/app/src/main/java/com/fullcircle/qrgate/Prefs.kt`
- `android/qr_gate/README.md`

**Interfaces:**
- Consumes: pairing QR `fcpair:<device_id>:<token>:<url>`; `POST {url}/api/punch/attendances` multipart fields `employee_id`, `punched_at` (ISO-8601 UTC), `client_id`, `photo`; header `Authorization: Bearer <token>`
- Produces: sideloadable debug APK; local Room queue; no ERP password

- [ ] **Step 1: Gradle app module**

`app/build.gradle.kts` (essentials):

```kotlin
plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("com.google.devtools.ksp")
}
android {
    namespace = "com.fullcircle.qrgate"
    compileSdk = 35
    defaultConfig {
        applicationId = "com.fullcircle.qrgate"
        minSdk = 26
        targetSdk = 35
        versionCode = 1
        versionName = "0.1.0"
    }
    buildFeatures { viewBinding = true }
}
dependencies {
    implementation("androidx.camera:camera-camera2:1.4.1")
    implementation("androidx.camera:camera-lifecycle:1.4.1")
    implementation("androidx.camera:camera-view:1.4.1")
    implementation("com.google.mlkit:barcode-scanning:17.3.0")
    implementation("androidx.room:room-runtime:2.6.1")
    implementation("androidx.room:room-ktx:2.6.1")
    ksp("androidx.room:room-compiler:2.6.1")
    implementation("androidx.work:work-runtime-ktx:2.9.1")
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
}
```

- [ ] **Step 2: Prefs + pairing**

`Prefs.kt` stores `token` and `baseUrl` in ordinary `SharedPreferences` (device is company-owned and lock-tasked). If `token` is empty, launch `PairingActivity`.

`PairingActivity`: CameraX + ML Kit, parse payload:

```kotlin
fun parsePairing(raw: String): Triple<String, String, String>? {
    if (!raw.startsWith("fcpair:")) return null
    val rest = raw.removePrefix("fcpair:")
    val parts = rest.split(":", limit = 3)
    if (parts.size != 3) return null
    return Triple(parts[0], parts[1], parts[2])
}
```

Save token + baseUrl, start `ScanActivity`.

- [ ] **Step 3: Queue + worker**

`PunchEntity`: `clientId` (UUID PK), `employeeId`, `punchedAtIso`, `photoPath`, `tries`, `lastError`.

`UploadWorker`: for each row, POST multipart to `$baseUrl/api/punch/attendances`. On **201** delete row. On **401/404/422/409** delete row (do not retry forever). On network error increment `tries` and retry (WorkManager backoff).

- [ ] **Step 4: ScanActivity (front camera, two-step)**

1. Preview + square overlay. Decode QR from **ImageProxy** buffer (not screenshot). Accept `fcqa:<uuid>` or a raw UUID.
2. Switch overlay to oval, text “Look at the camera”, capture JPEG, scale long side to 480px, compress quality 70, abort if `> 300_000` bytes and recapture.
3. Insert Room row (`punchedAtIso` = now UTC), enqueue `UploadWorker`, play success beep, show “OK” 1.5s, back to QR step.
4. `FLAG_KEEP_SCREEN_ON`. Request camera permission. `startLockTask()` when possible.
5. No flip-camera. No employee list.

- [ ] **Step 5: Manifest**

`CAMERA` permission. `PairingActivity` launcher. `ScanActivity` `singleTask`. `android:keepScreenOn` / window flags in code.

- [ ] **Step 6: README**

How to assemble debug APK, install with `adb`, pair from Full Circle Punch Devices, point at a printed employee badge. Trust the local HTTPS cert or use HTTP in dev (`android:usesCleartextTraffic` only for debug).

- [ ] **Step 7: Manual gate check**

- Pair phone → scanner mode.
- Print employee badge (now `fcqa:`).
- Scan + face → Punch IO shows a 📷 for that slot.
- Airplane mode: scan twice (wait 3+ minutes), restore network → both rows appear in time order with rebuilt flags.
- Revoke device → next upload 401, phone stops (queue rows for 401 are dropped).

- [ ] **Step 8: Commit**

```bash
git add android/qr_gate
git commit -m "feat(punch-gate): Android kiosk scanner with offline queue"
```

---

## Spec coverage

| Spec requirement | Task |
|---|---|
| `punch_devices` + attendence columns | 1 |
| Pair / revoke / hashed token | 2, 6 |
| Ingest, photo file, flag rebuild, duplicate 3 min, client_id | 3 |
| `POST /api/punch/attendances` device Bearer | 4 |
| Photo GET authenticated | 5 |
| Punch Devices UI + pairing QR `fcpair:` | 6 |
| Badge `fcqa:` + bare UUID parse | 7 |
| Punch IO photo | 8 |
| Skill / no PunchCamera revival | 9 |
| Android front camera, queue, kiosk | 10 |
| Fingerprint unchanged | 3 (regression `hr_test`) |
| No personal-phone QR | 9 + Android has no login |
| Clerk cannot pair | 2 (`:manage_punch_device`) |

## Placeholder / consistency notes

- `client_id` is stored on `time_attendences` (needed for idempotency; spec implied it).
- Pairing auth is `:manage_punch_device`, not `:update_employee` (clerk excluded).
- Photo path uses UTC year/month of `punch_time`.
- `unzip_time_list` still accepts old 4-part rows.
- Android is one task because it is not Mix-testable; do not start it before the API is green.
