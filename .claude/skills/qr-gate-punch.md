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
