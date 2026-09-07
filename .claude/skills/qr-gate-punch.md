---
name: qr-gate-punch
description: Use when working on QR gate attendance — paired Android scanners, POST /api/punch/attendances, punch_devices, fcqa: badge QR, audit face photos on time_attendences, Punch IO photo link, or IN/OUT flag rebuild for a calendar day.
---

# QR Gate Punch

Company wall-mounted Android phones capture **one still** that contains a printed badge (`fcqa:<employee_id>`) **and** an unobstructed face (detection only, no matching), then POST to `/api/punch/attendances` with a **device** Bearer token. Full Circle inserts `time_attendences` (`input_medium: QRGate`, `user_id` nil) and rebuilds that employee's IN/OUT flags for the local calendar day.

Pairing QR must use the **browser origin** (open Punch Devices as `http://<lan-ip>:4000`, not localhost). `Endpoint.url()` is `https://localhost:4001` in dev and the phone cannot upload to that.

Do **not** revive `/PunchCamera`, `punch_camera` role, Face ID, or employee self-service QR.

Fingerprint import is unchanged until the gate is proven.

Pairing: `PunchGate.create_device/3` returns `{device, plain_token}` once. QR `fcpair:<id>:<token>:<url>`. Clerks cannot pair (`:manage_punch_device` = admin/manager/supervisor).

Badge must not occlude the face: the phone compares the QR bounding box against the **largest** face box and rejects at **>5%** coverage (`ScanActivity.badgeOccludesFace`), in both the live gate and the still re-check. Do **not** switch to `LANDMARK_MODE_ALL` and test for a missing nose/mouth landmark instead — ML Kit *estimates* landmarks for covered features and reports no per-landmark occlusion confidence. This is a client-side guard only; the server runs no detection, so the stored audit JPEG stays the real backstop.

Photos: `{uploads_dir}/{company_id}/punch_photos/{yyyy}/{mm}/{id}.jpg`. Serve via `GET /companies/:id/TimeAttend/:id/photo`.
