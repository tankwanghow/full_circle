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

The stored JPEG is **cropped to the face** (`ScanActivity.faceCropBox`, face box padded 30%, clamped to the frame) so it is legible as a thumbnail. The badge is verified in the same frame and then **deliberately cropped out** — the stored image proves *who*, not *which badge*. Chosen 2026-09-08 with that trade-off understood; do not "restore" the full frame as if it were a regression.

Punch IO **and Punch Card** have a live **Show photos** toggle (`search[show_photos]` for URL persistence, default off). There is no photo icon: a slot shows a thumbnail or nothing. The binding is `JS.toggle_class("show-punch-photos", to: ...) |> JS.push("toggle_photos")` — the class flip is client-side so it is instant, and the push keeps the server assign in step for later re-renders.

Visibility is **CSS, not markup**: `PunchTimeComponent` always renders the thumbnail with class `punch-photo` (hidden by `app.css`), and the toggle adds `show-punch-photos` to a wrapper around the list. This is deliberate — Punch IO renders rows through a `phx-update="stream"` comprehension, which emits nothing on re-render, so a markup-based toggle would leave already-rendered rows stale unless you re-stream (losing scroll position and re-querying). CSS cascades to rows already in the DOM, so the toggle is instant on both pages and the components need no `show_photos` assign at all.

Two traps when touching this:

- The `show-punch-photos` wrapper must be **outside** `#objects_list`, whose `:if={Enum.count(@streams.objects) > 0 or @page > 1}` is **false on every re-render after the first** — a `LiveStream`'s count is 0 once its inserts are consumed. Put the class on that div and the toggle silently does nothing.
- Both checkboxes pass `phx-debounce={nil}`; without it `.input`'s default makes the toggle wait for blur. See `.claude/skills/liveview-computed-field-gotchas.md` §6.
- `PunchCard`'s filter form is **`phx-change="search"`**, and that handler `push_navigate`s. Without the `handle_event("search", %{"_target" => ["search", "show_photos"]}, ...)` no-op clause, ticking the box remounts the whole page instead of toggling live. `render_click` in tests only exercises `phx-click`, so this is invisible unless you test `render_change` with that `_target`.
- `PunchCard.filter_punches/4` **rebuilds the whole `search` map** on its `is_nil(emp)` branch, so a key added to `search` must be carried through there or the default page (no employee selected) raises `KeyError`.

Face **matching** was considered on 2026-09-08 and deliberately not built: it needs an embedding (a biometric template) whether or not you persist it, there is no Oban or Nx in this project, and a cold-start baseline can be poisoned by an impostor in an employee's first few punches. Thumbnails plus a human eye first; revisit only if mismatches actually turn up.

## Building & installing the APK

`./gradlew` needs **JDK 17**; the default `java` on this box is a JDK 8 mise shim, so a bare invocation fails. `ANDROID_HOME` is unset but `local.properties` carries `sdk.dir`, so JAVA_HOME is the only missing piece (re-derive the path with `mise where java <version>` if mise is upgraded):

```bash
cd android/qr_gate
JAVA_HOME=~/.local/share/mise/installs/java/temurin-17.0.20+8 ./gradlew assembleDebug
adb install -r app/build/outputs/apk/debug/app-debug.apk
```

`-r` keeps app data, so the device pairing token survives an upgrade — the app comes straight up in `ScanActivity` instead of asking for a new pairing QR. Verified on an OPPO CPH2699, 2026-09-07 (badge-over-face rejected, clean hold punched, flash legible at gate distance).

Gate phone is OPPO/ColorOS: USB debugging is off by default and the toggle is gated behind SIM + network + HeyTap account. `lsusb -d 22d9:2764 -v` tells you which state it is in — an Imaging/MTP interface alone means debugging is off; the ADB interface is class 255 / subclass 66 / protocol 1. There are no Android udev rules on this box, so expect `no permissions` once ADB does appear. Wireless debugging (`adb pair` / `adb connect`) sidesteps both and suits a phone screwed to a wall.

### Release (production) APK

Signing comes from `~/.gradle/gradle.properties`, never the repo:

```properties
QR_GATE_STORE_FILE=/home/<you>/keystores/qr_gate.jks
QR_GATE_STORE_PASSWORD=…
QR_GATE_KEY_ALIAS=qr_gate
QR_GATE_KEY_PASSWORD=…
```

Created once with `mkdir -p ~/keystores && chmod 700 ~/keystores` then `keytool -genkeypair -v -keystore ~/keystores/qr_gate.jks -alias qr_gate -keyalg RSA -keysize 4096 -validity 10000 -storetype PKCS12` (keytool does not create the directory). **Back the keystore up.** Lose it and no installed app can ever be updated again — the only recovery is uninstall + re-pair on every phone.

`assembleRelease` fails in ~2s with the missing property names if they are absent, rather than emitting an unsigned APK that only fails at `adb install`.

**The first release install wipes each phone's app data**, because a release signature cannot upgrade a debug-signed install (`INSTALL_FAILED_UPDATE_INCOMPATIBLE`). Per phone, once: drain the queue (confirm recent punches in Punch IO — anything still queued is lost), revoke the device in Punch Devices, `adb uninstall com.fullcircle.qrgate`, install the release APK, then pair fresh. `adb uninstall -k` is not a shortcut: with a changed signature the retained data is orphaned. Later release upgrades are a plain `adb install -r` and keep pairing.

Release builds forbid cleartext, so **pairing refuses a non-https URL** (`PairingActivity.pairingUrlUsable`) instead of storing it and failing later as an endlessly retrying upload. Point release phones at the production domain, which has a real Let's Encrypt cert — no cert bundling needed. Debug builds still pair over `http://<lan-ip>:4000`.

`versionName` is rendered faintly in the scanner's top-right corner so a wall-mounted phone's build can be read without unmounting it. Bump `versionCode`/`versionName` deliberately per release.

Verify a release artifact before shipping it (all three fail on a debug APK):

```bash
aapt2 dump badging app-release.apk | grep application-debuggable   # must print nothing
apksigner verify --print-certs app-release.apk                     # must NOT be CN=Android Debug
aapt2 dump xmltree --file AndroidManifest.xml app-release.apk | grep usesCleartextTraffic
```

Note the app is **multidex** (6 dex files): grepping only `classes.dex` for a symbol gives a false negative.

Two gotchas that each cost a build:

- A bare apostrophe in `strings.xml` fails AAPT2 with a misleading *"Invalid unicode escape sequence"*. Use `\'`, not `&#39;`.
- `android.graphics.Rect` is stubbed in local JVM unit tests and throws *"not mocked"*. Geometry that needs testing uses `ScanActivity.Box` instead, converted at the call sites via `Rect.toBox()`.
