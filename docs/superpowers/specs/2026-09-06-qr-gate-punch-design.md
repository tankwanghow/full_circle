# QR Gate Punch (company Android scanner) — Design

**Date:** 2026-09-06
**Status:** Draft
**App:** FullCircle (`full_circle`) + Android scanner APK
**Related:** `.claude/skills/punch-card-payroll.md`, `.claude/skills/finger-print-import.md`
**Replaces (later):** fingerprint machine export → `/import_attend`. Fingerprint import **stays** until QR is proven.
**Does not revive:** web `PunchCamera` LiveView, `punch_camera` role, Face ID / `employee_photos` / face descriptors.

## Problem

Attendance today is captured on **two fingerprint machines**, exported as monthly `.xls`, and imported into `time_attendences`. That works, but the machines are a separate ecosystem (IDs collide across machines, matching is `punch_card_id`, delays until import).

The old in-browser webcam kiosk (`/PunchCamera`) was removed: it was a laptop/webcam UX, always-online, and employees tapped IN/OUT. It is **not** coming back.

Goal: company-owned **wall-mounted Android phones** at the gate, under a roof in daylight, that scan a **printed employee badge QR**, take an **audit face photo** (buddy-punch deterrent, no matching), and land punches in the same `time_attendences` table so Punch IO / Punch Card / PaySlip stay unchanged.

## Decisions taken during brainstorming

| Topic | Decision |
|---|---|
| Physical setup | Phone (or tablet) **wall-mounted at face height**, screen toward the employee. Same role as a fingerprint clock. |
| Who holds the QR | Employee presents a **printed company badge**. Not their own phone. |
| Employee self-service QR | **Forbidden** (standing rule, not “later”). No login that shows a QR; punches only from a **paired company device**. |
| Connectivity | Mostly online; **local queue** so a brief drop does not lose punches. Punch time = **scan time**, not upload time. |
| IN/OUT | **Just scan.** Server infers `1_IN_1` / `1_OUT_1` / … from that employee’s punches that **calendar day** (company timezone), in time order. Clerks fix mistakes on Punch IO / Punch Card. |
| Client | **Dedicated Android app** (Kotlin). Sideload APK. No Play Store for v1. |
| Device auth | Admin **pairs** each phone once. Device token on the phone; **no ERP user login** on the device. |
| Badge QR | `fcqa:<employee_id>` (UUID). No extra token column. Lost badge → face photos + disable employee if needed. Reprint is the same QR. |
| Face photo | **Audit only.** JPEG stored with the punch. No enrolment, no matching, do not restore `employee_photos`. |
| Camera | **Front camera** + live preview. Capture only when **one frame** has a valid badge QR **and** a face. Decode from raw frames, not the mirrored preview. No flip-camera on a fixed mount. |
| Hardware | Consumer/commercial Android phone or tablet, wall cradle, always charging, under a roof, daylight. Not a closed ZKTeco-style terminal. |
| Fingerprint | Import path **unchanged** until QR is successful. Then phase out separately. |
| GPS | Not in v1 (gate is a named device). |

## Existing pieces to reuse

- `time_attendences` — `lib/full_circle/HR/timeattend.ex`. Keep rows; add `punch_device_id` and `photo_path`. `user_id` is already nullable in the create migration; QR punches leave it **nil** (the gate is the actor). `input_medium` = `"QRGate"`.
- Punch IO — `TimeAttendLive.PunchIndex` + `PunchTimeComponent`. Review board for a date range; add photo thumbnail.
- Punch Card — payroll workspace; punch times already editable. Photo on the card is optional (nice-to-have, not required for v1 payroll).
- Employee print — `EmployeeLive.Print` already draws a QR of `emp.id` (`QRCode.create(emp.id, :high)`). Change payload to `fcqa:<id>` and keep name / id_no on the card.
- File storage — `uploads_dir` (`uploads/<company_id>/` in dev). Punch JPEGs live under that tree, not in Postgres bytea.
- `:api` pipeline exists but authenticates **users** via `fetch_api_user` (Bearer user token). Gate phones must **not** use that. New plug: device token → `punch_devices`.

## Non-goals (v1)

- Face matching / enrolment / restoring Face ID.
- Employee QR on a personal phone, PWA, or WebView kiosk.
- Reviving `/PunchCamera` or the `punch_camera` role.
- Play Store, MDM, or iOS.
- GPS, offline-for-days batch file (fingerprint-style monthly dump).
- Rotating badge tokens (would need a new column; revisit if stolen badges become common).
- Auto salary notes / payslips from punches.
- Removing fingerprint import in the same project.

## Architecture

```
[Printed badge] --QR--> [Android app, front camera]
                            | 1. decode fcqa:<uuid>
                            | 2. face JPEG
                            | 3. SQLite queue (scan time + photo)
                            v
                     HTTPS + device token
                            v
[FullCircle Punch API] --> time_attendences + JPEG on disk
                            v
              Punch IO / Punch Card / PaySlip (unchanged math)
```

Two codebases, one product:

| Piece | Where |
|---|---|
| Pairing UI, badge print, ingest, flag rebuild, photo serve, Punch IO thumbnail | this Elixir repo |
| Scanner APK (camera, kiosk, queue, upload) | `android/qr_gate/` in this repo (sideload) |

The APK is useless without the API; keep them versioned together.

## Data model

### `punch_devices`

| Column | Notes |
|---|---|
| `id` | `binary_id` |
| `company_id` | required |
| `name` | e.g. `"Gate 1"`; unique per company |
| `token_hash` | hash of the pairing token (never store plaintext after the pairing screen) |
| `paired_by_user_id` | admin who created it |
| `revoked_at` | nil = active |
| `last_seen_at` | updated on successful ingest |
| timestamps | utc |

Plain token is a long random string, shown **once** (pairing QR). Revoke sets `revoked_at`; the phone then gets 401.

### `time_attendences` additions

- `punch_device_id` — nullable FK to `punch_devices` (nil for fingerprint / user-entry punches).
- `photo_path` — nullable relative path under `uploads_dir` (nil for non-QR punches).

`flag`, `input_medium`, `punch_time`, `employee_id`, `company_id` unchanged. QR rows: `input_medium = "QRGate"`, `user_id = nil`.

### Photo files

Path: `{uploads_dir}/{company_id}/punch_photos/{yyyy}/{mm}/{time_attendence_id}.jpg`

Served only to logged-in company users (`GET /companies/:company_id/TimeAttend/:id/photo`), not a public URL. Do not put JPEGs in LiveView assigns as base64.

## Scan flow (mounted phone)

1. App is the only foreground activity (lock-task / kiosk). Screen stays on. Front camera preview fills the screen.
2. One overlay + “Hold your badge and look at the camera”. Live frames run **barcode and face detection together**. Capture a still only when that **same frame** has a valid badge (`fcqa:<uuid>`, or a bare UUID so older cards still work) **and** at least one face. Prefer `fcqa:` if two codes are in view.
3. Re-check the JPEG: still must contain a face **and** the same employee QR. If either is missing, reject beep, no queue row. JPEG ~480 px on the long side, quality ~70. Detection only (no matching). **No photo → no punch.**
4. Write `{employee_id, punched_at, photo, local_id}` to SQLite immediately. Show a short OK. `punched_at` is that capture instant (UTC ISO-8601), not upload time.
5. Upload when the network is up. Success → delete local row. Failure → retry with backoff. `punched_at` never changes.

## IN/OUT flag assignment

On each successful ingest (and after a late queued punch lands):

1. Take `punched_at` in the **company timezone**, calendar date `D`.
2. Load all `time_attendences` for that `employee_id` + `company_id` whose local date is `D`, ordered by `punch_time`.
3. Assign flags in order: `1_IN_1`, `1_OUT_1`, `2_IN_2`, `2_OUT_2`, `3_IN_3`, `3_OUT_3`, then wrap (`1_IN_1` …).
4. Persist the updated flags. Punch Card hour math already pairs consecutive IN/OUT; an unpaired last IN is 0 hours for that pair.

This rebuild is why offline batches stay correct: a punch uploaded two hours late still slots into chronological order, instead of “whatever IN/OUT the phone guessed.”

**Duplicate:** same `employee_id`, **any** gate of that company, within **3 minutes** of an existing punch → reject (409). Different beep on the phone. No second photo stored. Matches the old kiosk “need 3 minute in between punches” idea; tighter than fingerprint import’s 10-minute cell dedup.

**Inactive / missing employee:** 422 / 404. Phone shows error; if it was already queued (offline), drop after the server rejects (do not retry forever).

## HTTP API (device token, not user session)

Base: `/api/punch` (new pipeline, **not** `fetch_api_user`).

Auth: `Authorization: Bearer <device_token>`. Plug loads `punch_devices` by token hash; 401 if missing or `revoked_at` set. Assigns `current_company` from the device.

### `POST /api/punch/attendances`

Multipart or JSON+base64; multipart preferred (JPEG).

Fields: `employee_id`, `punched_at` (ISO-8601 UTC), `photo` (JPEG), `client_id` (UUID of the SQLite queue row). Required. Retries send the same `client_id`.

Success `201`: `{id, employee_name, flag, punch_time}`.

Errors: `401` revoked/unknown device, `404` unknown employee or wrong company, `422` inactive / missing photo / bad `punched_at` (future > 2 min), `409` duplicate, `413` photo too large (cap ~300 KB after client compress).

Idempotency: same `client_id` + device → return the existing row, do not insert twice.

### Pairing

Admin LiveView creates the device and displays a pairing QR whose payload is
`fcpair:<device_id>:<plain_token>:<api_base_url>`
(plaintext token is only on that screen; the DB keeps the hash. `api_base_url` is the Full Circle origin so the phone is not typed on).

App first-run: “Scan pairing QR”, store token + base URL. No other settings.

`DELETE`/revoke in the LiveView is enough; no unpair API required for v1.

## Full Circle UI

### Punch devices (`/companies/:id/punch_devices`)

Auth: `:update_employee` roles (admin / manager / supervisor) — same people who issue badges.

List: name, last-seen, revoked. Actions: create (name → show pairing QR once), revoke.

Clerks do **not** pair phones; they review photos on Punch IO.

### Employee badge

Update `EmployeeLive.Print` QR payload from `emp.id` to `"fcqa:" <> emp.id`. Layout (name, id_no, card size) can stay. Index/form print buttons already exist.

Scanner accepts:

1. `fcqa:` + UUID (canonical)
2. Bare UUID that `get_employee!` resolves in this company (old cards)

Reject anything else (random barcodes, other documents).

### Punch IO

On each punch time slot that has `photo_path`, show a small thumbnail. Click → modal with larger image, employee name, local time, gate name.

Do not load all full JPEGs in the infinite scroll; thumbnails only (or a dedicated thumb file later if needed — v1 can serve the same JPEG with CSS max-size).

## Android app (`android/qr_gate/`)

- Kotlin, min SDK 26, CameraX + ML Kit barcode (QR).
- Room queue + WorkManager upload.
- Kiosk: lock task, keep screen on, hide system bars as far as the OEM allows.
- Front camera only on the scanner screen.
- Sounds: success / reject (local files).
- No employee directory, no Full Circle menus, no stored ERP password.
- Config: only what the pairing QR provides (token + base URL).

Manual test on a wall-mounted phone is the gate for the APK; Mix tests cover the server.

## Testing (server)

- Pairing: create device, hash stored, plaintext not re-readable; revoke → ingest 401.
- Ingest: active employee → row + photo file + `QRGate` + `punch_device_id`; name returned.
- Inactive / other company / unknown id → no row.
- Duplicate within 3 minutes → 409, one row.
- Idempotent `client_id` retry → one row.
- Flag rebuild: three punches in one day → `1_IN_1`, `1_OUT_1`, `2_IN_2`; inserting a delayed punch in between reorders flags.
- Photo route: authenticated company user 200; logged-out 302; other company 404.
- Print: SVG / payload contains `fcqa:`.
- Existing fingerprint import tests still pass (no change to `punch_card_id` path).

## Key decisions

1. **Native Android + punch API**, not a browser kiosk — local queue and kiosk lock; avoids the removed webcam page.
2. **Paired devices**, not a logged-in user on the phone — no ERP session on a shared gate device; `user_id` nil, `punch_device_id` set.
3. **Infer IN/OUT on the server by calendar day** — no extra tap on a shared screen; late sync still sorts correctly.
4. **QR = `fcqa:` + employee UUID** — print already exists; no rotatable token until stolen badges hurt.
5. **Front camera + same-frame capture** — screen faces the person; punch only when the badge QR and a face are in the same picture (stronger buddy-punch audit than QR-then-oval).
6. **Audit JPEG on disk** — deterrence and review, not Face ID.
7. **No personal-phone QR** — standing rule.
8. **Fingerprint import stays** until this path is proven.

## Implementation order (for the later plan)

1. Schema (`punch_devices`, attendence columns) + ingest + flag rebuild + API (curl-able without the APK).
2. Punch devices LiveView (create / pairing QR / revoke).
3. Badge print payload `fcqa:` + scanner accept list.
4. Photo file write + Punch IO thumbnail/modal.
5. Android APK (camera, queue, pairing, kiosk).
6. Manual gate trial; fingerprint remains until you turn it off.

No code until this spec is reviewed and an implementation plan is written.
