---
name: qr-gate-punch
description: Use when working on QR gate attendance — paired Android scanners, building or installing the android/qr_gate APK, POST /api/punch/attendances, punch_devices, fcqa: badge QR, audit face photos on time_attendences, Punch IO photo link, or IN/OUT flag rebuild for a calendar day.
---

# QR Gate Punch

Company wall-mounted Android phones capture **one still** that contains a printed badge (`fcqa:<employee_id>`) **and** an unobstructed face (detection only, no matching), then POST to `/api/punch/attendances` with a **device** Bearer token. Full Circle inserts `time_attendences` (`input_medium: QRGate`, `user_id` nil) and rebuilds that employee's IN/OUT flags for the local calendar day.

Pairing QR must use the **browser origin** (open Punch Devices as `http://<lan-ip>:4000`, not localhost). `Endpoint.url()` is `https://localhost:4001` in dev and the phone cannot upload to that.

Do **not** revive `/PunchCamera`, `punch_camera` role, Face ID, or employee self-service QR.

Fingerprint import is unchanged until the gate is proven.

Pairing: `PunchGate.create_device/3` returns `{device, plain_token}` once. QR `fcpair:<id>:<token>:<url>`. Clerks cannot pair (`:manage_punch_device` = admin/manager/supervisor).

Badge must not occlude the face: the phone compares the QR bounding box against the **largest** face box and rejects at **>5%** coverage (`ScanActivity.badgeOccludesFace`), in both the live gate and the still re-check. Do **not** switch to `LANDMARK_MODE_ALL` and test for a missing nose/mouth landmark instead — ML Kit *estimates* landmarks for covered features and reports no per-landmark occlusion confidence. This is a client-side guard only; the server runs no detection, so the stored audit JPEG stays the real backstop.

Photos: `{uploads_dir}/{company_id}/punch_photos/{yyyy}/{mm}/{id}.jpg`. Serve via `GET /companies/:id/TimeAttend/:id/photo`.

## Building & installing the APK

`./gradlew` needs **JDK 17**; the default `java` on this box is a JDK 8 mise shim, so a bare invocation fails. `ANDROID_HOME` is unset but `local.properties` carries `sdk.dir`, so JAVA_HOME is the only missing piece (re-derive the path with `mise where java <version>` if mise is upgraded):

```bash
cd android/qr_gate
JAVA_HOME=~/.local/share/mise/installs/java/temurin-17.0.20+8 ./gradlew assembleDebug
adb install -r app/build/outputs/apk/debug/app-debug.apk
```

`-r` keeps app data, so the device pairing token survives an upgrade — the app comes straight up in `ScanActivity` instead of asking for a new pairing QR. Verified on an OPPO CPH2699, 2026-09-07 (badge-over-face rejected, clean hold punched, flash legible at gate distance).

Gate phone is OPPO/ColorOS: USB debugging is off by default and the toggle is gated behind SIM + network + HeyTap account. `lsusb -d 22d9:2764 -v` tells you which state it is in — an Imaging/MTP interface alone means debugging is off; the ADB interface is class 255 / subclass 66 / protocol 1. There are no Android udev rules on this box, so expect `no permissions` once ADB does appear. Wireless debugging (`adb pair` / `adb connect`) sidesteps both and suits a phone screwed to a wall.

Two gotchas that each cost a build:

- A bare apostrophe in `strings.xml` fails AAPT2 with a misleading *"Invalid unicode escape sequence"*. Use `\'`, not `&#39;`.
- `android.graphics.Rect` is stubbed in local JVM unit tests and throws *"not mocked"*. Geometry that needs testing uses `ScanActivity.Box` instead, converted at the call sites via `Rect.toBox()`.
