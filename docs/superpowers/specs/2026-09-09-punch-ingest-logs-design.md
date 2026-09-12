# Punch ingest logs — Design

**Date:** 2026-09-09
**Status:** Draft
**App:** FullCircle (`full_circle`)
**Related:** `docs/superpowers/specs/2026-09-06-qr-gate-punch-design.md`, `.claude/skills/qr-gate-punch.md`
**Does not change:** Android `qr_gate` APK, `POST /api/punch/attendances` request/response (statuses and bodies, 401 included), Punch IO / Punch Card / PaySlip math, fingerprint import.

## Problem

Gate POSTs that the server rejects (unknown badge, inactive employee, ±3 min duplicate, missing/too-large photo, future time, invalid payload, **revoked device**) currently vanish after the HTTP status. The phone treats 4xx as done and drops the queue row. Clerks looking at Punch IO cannot tell "the server never saw it" from "the server saw it and refused it."

`time_attendences` stays the payroll register. This feature is an **append-only operational log** of every attributable POST the gate makes.

## Decisions taken during brainstorming

| Topic | Decision |
|---|---|
| Storage | New `punch_ingest_logs` table. Do not reuse CRUD `logs` (requires `user_id`, stores entity deltas). |
| What is logged | Every POST that reaches `PunchGate.ingest_punch/2`, **plus** POSTs rejected as 401 because the device is revoked (the token still resolves to a company). Not `GET /health`. Not unknown-token 401s — nothing to scope them to. |
| Outcomes | `accepted` \| `replayed` \| `duplicate` \| `rejected` |
| Photos | JPEG on **rejects that had a usable upload**, plus `duplicate`. Never on `revoked`. Accepted/replayed faces stay on `time_attendences` (24 months). Never copy those onto the log. |
| Viewers | admin, manager, supervisor, clerk via `:view_punch_ingest_log`. Cashier, auditor, guest, disable cannot. |
| Phone | Unchanged. Same multipart fields, same status codes, same JSON. |
| Retention | 3 **calendar** months from `inserted_at` (server received time). Delete file then row. |
| Writes vs punch | Log **after** the punch result is known, best-effort. A log failure must not change the HTTP result. |

## Non-goals

- Face matching, enrolment, or storing embeddings.
- Logging health pings, or 401s whose token matches no device row.
- A second attendance register, or clerks editing/deleting log rows.
- Changing when the phone drops 4xx vs retries 5xx.
- Writing into `logs`.
- Oban (this app has none; pruner is a supervised GenServer, same as `PhotoPruner`).
- Fixing the 6-punch ceiling. A local day with more than 3 IN/OUT pairs is **accepted** and logged as `accepted` — correctly, since the server did accept it. But `rebuild_day_flags/3` wraps (`rem(i, 6)` at `punch_gate.ex:213`), so punch 7 is labelled `1_IN_1` again; `make_timeattend_list/2` (`helpers.ex:295`) keeps only the **first** row per flag; and `PunchTimeComponent` destructures a fixed 6-element list and recomputes `wh` from it (`punch_time_component.ex:185-204`). Punches 7+ are therefore invisible on Punch IO and Punch Card, and a clerk editing any punch on such a day replaces that day's hours with the truncated six (`punch_card.ex:677-700`) — the query-level `wh` over the full list (`hr.ex:1287`) is correct until then. That is a pre-existing payroll-UI ceiling, not an ingest gap. This log is what makes it **diagnosable** (8 `accepted` rows, 6 shown); fixing it has its own spec.

## Outcome map

`ingest_punch/2` **public** return stays `{:ok, ta}` \| `{:error, atom}`. Internally tag first insert vs replay (both paths below), log, then strip the tag so callers still see `{:ok, ta}`.

`PunchAttendanceController.create/2` keeps the same status **numbers** and body **strings**. The module itself **does** change: it must call `PunchGate.http_status_for/1` instead of a local atom→status map. Do not describe that file as untouched.

| Ingest result | `outcome` | `reason` | `http_status` | `time_attendence_id` | `employee_id` | Log JPEG |
|---|---|---|---|---|---|---|
| First insert | `accepted` | nil | 201 | new row | resolved | no |
| Replay (`existing_client/2` **or** unique-constraint race) | `replayed` | nil | 201 | existing row | resolved | no |
| ±3 min window (`:duplicate`) | `duplicate` | nil | 409 | nil | resolved | yes |
| Unknown / other-company / non-UUID (`:not_found`) | `rejected` | `not_found` | 404 | nil | nil | yes |
| Employee not Active (`:inactive`) | `rejected` | `inactive` | 422 | nil | resolved | yes |
| Photo missing/empty (`:missing_photo`) | `rejected` | `missing_photo` | 422 | nil | nil | no |
| Photo > 300 KB (`:too_large`) | `rejected` | `too_large` | 413 | nil | nil | no |
| `punched_at` > ~2 min future (`:future`) | `rejected` | `future` | 422 | nil | nil | yes |
| Bad `punched_at` or other (`:invalid`) | `rejected` | `invalid` | 422 | nil | nil unless the employee already resolved | yes |
| Token matches a revoked device (never reaches `ingest_punch`) | `rejected` | `revoked` | 401 | nil | resolved if the badge resolves in that company | no |

`http_status` on the log row is `PunchGate.http_status_for/1`. The controller uses the same function for the response. One map:

| Atom | Status |
|---|---|
| `:accepted` (controller success path; logger uses this for `accepted` **and** `replayed`) | 201 |
| `:revoked` | 401 |
| `:not_found` | 404 |
| `:duplicate` | 409 |
| `:too_large` | 413 |
| `:inactive`, `:missing_photo`, `:future`, `:invalid`, anything else | 422 |

### The JPEG rule is unconditional

`validate_photo/1` runs **first** in today's `with`, so by the time any of `not_found`, `inactive`, `future`, `duplicate`, or an insert-failure `:invalid` is reachable, the upload has already passed (non-empty JPEG ≤ 300 KB). The rule is therefore:

> Store a log JPEG on every outcome except `accepted`, `replayed`, and the two reasons that mean there was no usable upload — `missing_photo` and `too_large` — and except `revoked`, which is logged before any photo handling.

### Two replay paths, not one

`replayed` is produced in **two** places and both must be tagged:

1. `ingest_punch/2` short-circuits on `existing_client/2` (`punch_gate.ex:104`).
2. `resolve_client_conflict/3` (`punch_gate.ex:271`) returns `{:ok, ta}` after losing the `(punch_device_id, client_id)` unique-index race.

### Field ordering note

Today's `with` order is photo → parse time → future → employee → active → duplicate/insert. So `missing_photo`, `too_large`, `future`, and a bad timestamp all happen **before** employee lookup: `employee_id` is nil, `employee_id_raw` is still stored. `:invalid` after a resolved employee is possible only from insert/changeset failures.

`last_seen_at` still updates only on a real `time_attendences` insert — not on replay, duplicate, reject, or a revoked-device 401.

## Data model

### `punch_ingest_logs`

`use FullCircle.Schema`. Append-only: `timestamps(updated_at: false, type: :utc_datetime)` in the schema, `timestamps(updated_at: false, type: :timestamptz)` in the migration (matching `20260906120000_create_punch_devices`).

| Column | Type | Notes |
|---|---|---|
| `id` | `binary_id` | PK; also the JPEG filename when a log photo exists |
| `company_id` | FK `companies` `on_delete: :delete_all` | required |
| `punch_device_id` | FK `punch_devices` `on_delete: :nilify_all` | always set at insert (the token resolved, active or revoked) |
| `employee_id` | FK `employees` `on_delete: :nilify_all` | set when the badge resolved in this company (including inactive / duplicate / revoked-device); nil on unknown / non-UUID |
| `employee_id_raw` | `:string` | exact string the phone sent, **truncated to 64 chars**; searchable when `employee_id` is nil |
| `time_attendence_id` | FK `time_attendences` `on_delete: :nilify_all` | accepted + replayed only |
| `client_id` | `:string` | phone idempotency key, **truncated to 64 chars**; **not unique** — retries are extra rows |
| `punched_at` | schema `:utc_datetime`; migration `:timestamptz` | scan time from the phone; nil if it would not parse. Same pair as `time_attendences.punch_time`. |
| `outcome` | `:string` | `accepted` \| `replayed` \| `duplicate` \| `rejected` |
| `reason` | `:string` | only when `outcome = rejected`: `not_found`, `inactive`, `too_large`, `missing_photo`, `future`, `invalid`, `revoked` |
| `http_status` | `:integer` | 201 / 401 / 404 / 409 / 413 / 422 |
| `photo_path` | `:string` | relative under `uploads_dir`; nil unless a log JPEG was stored |
| `inserted_at` | `:utc_datetime` | server received time |

**Truncate `employee_id_raw` and `client_id` before building the changeset.** Both are unvalidated client strings — `ingest_punch` does `to_string(attrs["employee_id"] || ...)` with no bound. A 300-character `employee_id` overflows `varchar(255)`, raises `Postgrex.Error`, gets swallowed by the best-effort rescue, and loses the log row for exactly the malformed POST the log exists to surface.

Check constraints:

- `outcome IN ('accepted','replayed','duplicate','rejected')`
- `(outcome = 'rejected' AND reason IS NOT NULL) OR (outcome <> 'rejected' AND reason IS NULL)`
- `reason IS NULL OR reason IN ('not_found','inactive','too_large','missing_photo','future','invalid','revoked')`

Indexes:

- `(company_id, inserted_at DESC)` — list, newest first
- `(company_id, outcome, inserted_at DESC)` — status filter, which always carries the date range and the same sort

Schema module: `FullCircle.PunchGate.PunchIngestLog`. Do **not** run this through `StdInterface` (that writes CRUD `logs` and expects a user).

Company deletion needs no trigger work: `delete_company_trigger` only cleans up detail tables that have no `company_id` of their own, so the plain `references(:companies, on_delete: :delete_all)` cascades these rows.

### Log JPEG files

Path: `{uploads_dir}/{company_id}/punch_ingest_logs/{yyyy}/{mm}/{punch_ingest_log_id}.jpg`

`yyyy`/`mm` from `inserted_at` (UTC is fine; this is a folder, not a business date).

Accepted faces stay at `{uploads_dir}/{company_id}/punch_photos/...` with 24-month `PhotoPruner`. The ingest log never copies them.

**Volume:** duplicates are the common photo-storing outcome, not the exotic rejects — a double-scan at the gate is routine. Budget on that basis: 3 months × duplicates/day × ≤300 KB. At a few dozen duplicates a day this is well under a gigabyte; nothing to engineer around, but size it before assuming rejects are rare.

## Write path

### Revoked device (401)

`PunchGate.authenticate_device(token)` returns `{:ok, device}` \| `{:revoked, device}` \| `:error` from a **single** `token_hash` lookup. `get_active_device_by_token/1` stays as the public API (existing tests assert on it) and is reimplemented on top of it, so there is one query and one code path.

`PunchDeviceAuth.call/2` then:

- `{:ok, device}` — assign `:punch_device` / `:current_company` and continue, exactly as today.
- `{:revoked, device}` — best-effort `PunchGate.log_revoked_attempt(device, conn.params)`, then the same `401 "No access for you"` and `halt()`. The response is byte-identical to today's.
- `:error` — 401, nothing logged.

**Only log `POST`s.** The plug also fronts `GET /api/punch/health`, which the scanner pings **every 20 seconds** (see `.claude/skills/qr-gate-punch.md`). Logging those would write ~4,300 rows a day per revoked phone and bury the punch it exists to show. Guard the revoked branch on `conn.method == "POST"`.

`Plug.Parsers` runs in the endpoint (`endpoint.ex:47`), before the router pipeline, so `conn.params` already holds the parsed multipart fields when the plug runs: `employee_id`, `client_id`, `punched_at` are all available. Resolve `employee_id` against the device's company so the list shows a name rather than a raw UUID — that is the whole point of the row ("Ali's punches are being dropped"). Also store truncated `client_id` and `punched_at` if it parses (nil if junk). No photo is copied.

A 401 on **health** wipes the phone's local queue without POSTing the rest (`LinkStatus.REVOKED` → `wipeBecauseRevoked`). Those never-sent rows will not appear here. Logging revoked POSTs covers what actually hit the server after revoke, not the unsent queue. That is fine with "phone unchanged."

### Normal ingest

1. `GET /api/punch/health` unchanged; not logged.
2. `PunchAttendanceController.create/2` still returns the same status numbers and JSON. It **does** change to call `PunchGate.http_status_for/1` instead of a local atom→status map.
3. `ingest_punch/2` runs today's `with` in the same order. After the result is known, `log_ingest` runs. `Repo.insert` often returns `{:error, changeset}` **without raising**; a check-constraint violation with no matching `check_constraint/3` raises `Postgrex.Error`. The helper must match `{:ok, _} | {:error, _}` and `Logger.error` on the error tuple, **and** an outer `try/rescue` for the raising cases. `ingest_punch` still returns the original punch result.
4. Log insert is **after** the punch `Repo.transaction`. If logging fails, Punch IO still has the row. A later retry with the same `client_id` logs `replayed` against that row — that is acceptable (and useful).
5. Do not wrap the log row in the punch `Ecto.Multi`. A log constraint failure must not roll back attendance.

### `http_status` has one source of truth

The status is decided by `PunchAttendanceController.create/2`; a column filled independently by `PunchGate` is a second copy that drifts silently. Extract `PunchGate.http_status_for/1` (atom → integer) and have **both** the controller and the logger call it.

### Swallowing log failures properly

`try/rescue` alone is not enough: `Repo.insert` returns `{:error, changeset}` **without raising**. The helper must match `{:ok, _} | {:error, _}` and `Logger.error` on the error tuple, *and* keep the rescue for the raising cases (a check-constraint violation with no `check_constraint/3` declared on the changeset raises `Postgrex.Error`).

### Writing the JPEG

Generate the id first, then insert once:

1. `id = Ecto.UUID.generate()`, `now = DateTime.utc_now() |> DateTime.truncate(:second)`.
2. Derive the path from `id` + `now`; `File.mkdir_p!` + `File.cp` from the upload.
3. Insert one row carrying `id`, `inserted_at: now`, and `photo_path`.
4. If the insert fails, `File.rm` the file.

One write, no update to a table declared append-only, and no window where the row claims to have no photo. If the copy fails, insert the row with `photo_path` nil; never fail the HTTP response. Do not use the punch-photo "delete file then clear path" order here — these files are owned by the log row and die with it.

## List page

- Route: `live("/punch_ingest_logs", PunchIngestLogLive.Index, :index)` under the authenticated company live session.
- Dashboard Payroll: button next to Punch Devices, `:if={can?(:view_punch_ingest_log, company)}`.
- Mount: check `Authorization.can?(user, :view_punch_ingest_log, company)` **directly**; on false, flash "Not Authorized!" and navigate to dashboard. (`PunchDeviceLive.Index` runs its list query twice to make that decision — do not copy that.)
- Read-only. No new/edit/delete. No UI prune.
- Filters (query string, Punch IO style):
  - employee: name **or** `employee_id_raw`
  - device name
  - received-at date range, **company timezone**. Default: **today**.
  - outcome: `all` (default) / `accepted` / `replayed` / `duplicate` / `rejected`
- Columns: received at (local), punch time (local), device name, employee (name, else raw id), outcome + reason, HTTP status.
- Infinite scroll, `@per_page 100` (same as Punch IO), newest `inserted_at` first.
- Date range is company-local **received** time. The window is `[local 00:00 of sdate, local 00:00 of edate + 1 day)` converted to UTC, filtering `inserted_at`. Be explicit about that upper bound: Punch IO papers over it by defaulting `edate` to tomorrow (`punch_index.ex:124`); do not inherit that. Do not use `inserted_at::date` in UTC (Malaysia UTC+8 would split "today").
- **Show photos** toggle: same CSS as Punch IO (`.punch-photo` / `.show-punch-photos` on a wrapper **outside** `#objects_list`, `phx-debounce={nil}`).
  - `duplicate` / `rejected` with `photo_path`: `GET /companies/:company_id/punch_ingest_logs/:id/photo`
  - `accepted` / `replayed` with `time_attendence_id`: existing `GET /companies/:company_id/TimeAttend/:id/photo`
- Log JPEG controller: `PunchIngestLogPhotoController.show/2` (do not overload `PunchPhotoController.show/2`). Logged-out users hit the existing `:require_authenticated_user` redirect to login. Logged-in without `:view_punch_ingest_log` → **403** (an `<img>` must not follow a dashboard redirect and render HTML). Wrong `company_id` or missing row/file/`photo_path` → **404**.

Query lives on `PunchGate.list_ingest_logs/3`. The function itself must `can?(:view_punch_ingest_log)` and return `:not_authorise` if the caller is not allowed (same as `list_devices/2`). Mount also checks `can?` directly so it does not run the list query twice. Scope `where: company_id == ^company.id`. Join employee and device for display names. `Repo`, not `QueryRepo`.

Gettext for title, column headers, outcome/reason labels (en + zh).

## Auth

```elixir
def can?(user, :view_punch_ingest_log, company),
  do: allow_roles(~w(admin manager supervisor clerk), company, user)
```

Clerks still cannot pair devices (`:manage_punch_device`) and still cannot create/update/delete `time_attendences`. They can only **see** the ingest log.

Cashier, auditor, guest, disable: no dashboard link, LiveView bounce, log photo route forbidden.

### Known gap, deliberately not closed here

`PunchPhotoController.show/2` has **no** role check — any authenticated company user can fetch a face at `/TimeAttend/:id/photo` by URL. Because the list page serves `accepted`/`replayed` photos through that existing route, "cashier cannot see punch photos" is **not** true end-to-end, whatever the new route does. This spec only claims the new route is gated. Gating the shipped `TimeAttend` photo route is a separate behavior change and needs its own decision.

## Retention

`FullCircle.PunchGate.IngestLogPruner` — supervised GenServer next to `PhotoPruner` in `application.ex`.

| Knob | Default | Set in |
|---|---|---|
| `:punch_ingest_log_retention_months` | `3` | `config/config.exs` (beside `punch_photo_retention_months`, line ~94) |
| `:punch_ingest_log_prune_enabled` | `true` | `config/config.exs`; `false` in `config/test.exs` |
| First run | 5 minutes after boot | |
| Interval | 24 hours | |
| Batch | 500 | |

Cutoff: `Timex.shift(DateTime.utc_now(), months: -months)` — calendar months, not 90 days.

`PunchGate.prune_ingest_logs_before(cutoff, opts \\ [])` with `:dry_run` and `:batch`.

Each batch:

1. Select rows with `inserted_at < cutoff`, oldest first, limit batch.
2. For each: if `photo_path` present, `File.rm` (missing file = success), then `Repo.delete`.
3. Repeat until empty.

`dry_run: true` must **not** page the same rows forever (nothing is deleted). Count remaining after the first page, same as `PhotoPruner`.

Rescue in the GenServer so a prune error never kills the supervision tree (`Logger.error`, retry tomorrow) — copy `PhotoPruner`.

Company delete already `delete_all`s the rows. Leftover files under `{uploads_dir}/{company_id}/punch_ingest_logs/` are the same class of orphan as deleted-company punch photos; do not add a special sweeper.

TimeAttend photos and `PhotoPruner` are untouched.

## Testing

### Context (`test/full_circle/punch_gate_test.exs`)

- Accepted ingest → one log row, `outcome=accepted`, `time_attendence_id` set, `photo_path` nil, punch JPEG still on TimeAttend.
- Same `client_id` again → second log row `replayed`, still one `time_attendences` row.
- The `resolve_client_conflict` replay path also logs `replayed` (not `invalid`).
- ±3 min → `duplicate`, log JPEG exists, no new TimeAttend.
- Unknown employee → `rejected`/`not_found`, `employee_id` nil, `employee_id_raw` set, log JPEG exists.
- Inactive → `rejected`/`inactive`, `employee_id` set.
- Missing photo / too large → `rejected` with that reason, `photo_path` nil.
- Future / invalid timestamp → `rejected` with that reason, log JPEG exists.
- An over-long `employee_id` (say 400 chars) still produces a log row, with `employee_id_raw` truncated.
- `GET` health and unknown-token 401 create **zero** log rows.
- Log failure does not change the punch result: `Repo.insert` returning `{:error, changeset}` is matched (no raise) and logged; a raised `Postgrex.Error` (or any exception while building/copying) is rescued the same way. A broken `uploads_dir` that makes the JPEG copy fail still leaves the log row and still returns the original ingest result.
- Prune: row older than cutoff is deleted and its JPEG removed; a newer row remains; TimeAttend photo remains.

### Revoked device 401

- `authenticate_device/1` returns `{:ok, _}` for active, `{:revoked, _}` for revoked, `:error` for garbage; `get_active_device_by_token/1` keeps its current behavior.
- POST with a revoked device's token → still `401 "No access for you"`, and one log row `rejected`/`revoked`/`401` with `punch_device_id` and `company_id` set, `employee_id` resolved when the badge resolves, truncated `client_id`, `punched_at` if it parses, `photo_path` nil.
- The same POST creates no `time_attendences` row and does not move `last_seen_at`.
- A revoked device's `GET /health` still 401s and logs **nothing** (the 20s ping must not flood the table).

### LiveView + photo

- Clerk (and admin) can open `/punch_ingest_logs`.
- Cashier (or guest role) is redirected to dashboard.
- Default list is today's rows; outcome filter and employee/raw search work.
- Log photo: authorized 200 JPEG; other company 404; logged-in cashier 403; missing file 404.

### HTTP contract

Existing `PunchAttendanceControllerTest` statuses and JSON stay green — including the 401 body, which must not change. Add only that a 201 also left an `accepted` log row if that is cheap; do not change assertions on the response body.

## Files (expected)

- `priv/repo/migrations/*_create_punch_ingest_logs.exs`
- `lib/full_circle/punch_gate/punch_ingest_log.ex`
- `lib/full_circle/punch_gate.ex` — `authenticate_device/1`, `http_status_for/1`, log after ingest, `log_revoked_attempt/2`, list, prune
- `lib/full_circle_web/plugs/punch_device_auth.ex` — revoked branch
- `lib/full_circle/punch_gate/ingest_log_pruner.ex`
- `lib/full_circle/application.ex` — start pruner
- `lib/full_circle/authorization.ex` — `:view_punch_ingest_log`
- `lib/full_circle_web/controllers/punch_attendance_controller.ex` — use `http_status_for/1`
- `lib/full_circle_web/router.ex` — live + photo GET
- `lib/full_circle_web/live/punch_ingest_log_live/index.ex` (+ index_component if the row markup needs it)
- `lib/full_circle_web/controllers/punch_ingest_log_photo_controller.ex`
- `lib/full_circle_web/live/dashboard_live/dashboard_live.ex` — Payroll link
- `config/config.exs` — retention + enabled defaults
- `config/test.exs` — prune disabled
- tests as above
- `.claude/skills/qr-gate-punch.md` — short section so the next session does not treat Punch IO as the only place a gate POST is visible

## Key decisions

1. **Separate table, not CRUD `logs`** — device POSTs have no ERP user; we need outcome/reason/http_status/photo, not entity deltas.
2. **Log every authenticated ingest, not rejects only** — "green icon, nothing on Punch IO" is diagnosed by missing `accepted`/`replayed` rows, not only by rejects.
3. **Log revoked-device 401s** — a revoked token is the one 401 class that is attributable to a company. The phone drops 4xx, so a POST after revoke currently vanishes. Unknown-token 401s stay unlogged — there is no company to scope them to. Health 401 wipes the local queue without POSTing remaining rows; those never-sent punches still will not appear (phone unchanged).
4. **JPEG on usable rejects/duplicates only** — the picture you cannot see today; accepted faces already live on TimeAttend for 24 months.
5. **Best-effort log after the punch transaction** — payroll ingest must not fail because logging failed.
6. **Clerk can view, still cannot pair or edit punches** — ops visibility without widening `:manage_punch_device` or `:create_time_attendence`.
7. **3 calendar months, PhotoPruner-shaped GenServer** — no Oban; ships in the release.
8. **Phone unchanged** — diagnosis is a server gap; the APK already sends everything this table needs.

## Implementation order (for the later plan)

1. Migration + schema + `http_status_for/1` + `log_ingest` inside `ingest_punch` + context tests (curl/ingest proves rows without UI).
2. `authenticate_device/1` + the `PunchDeviceAuth` revoked branch + `log_revoked_attempt/2` + tests.
3. Pruner + prune tests; config defaults; disable in `test.exs`.
4. List LiveView + auth + dashboard link + photo route + LiveView tests.
5. Skill paragraph on `qr-gate-punch.md`.
