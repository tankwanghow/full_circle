# QR Gate production build (release APK) — Design

**Date:** 2026-09-08
**Status:** Draft
**App:** Android scanner APK (`android/qr_gate`)
**Related:** `.claude/skills/qr-gate-punch.md`, `docs/superpowers/specs/2026-09-06-qr-gate-punch-design.md`
**Scope:** turning `app-debug.apk` into a shippable release build. No scanner behaviour changes.

## Problem

The APK running on the gate phone is a **debug** build. Verified against the installed artifact:

| Property | Value | Consequence |
|---|---|---|
| `android:debuggable` | `true` | `adb shell run-as com.fullcircle.qrgate` reads `shared_prefs` — **the device Bearer token in plain text** |
| Signing cert | `CN=Android Debug` | The universal public debug keystore; anyone can build an "update" over it |
| `usesCleartextTraffic` | `true` | Punch uploads may travel unencrypted |
| Network security config | debug variant | **Trusts user-installed CAs** — a MITM on the LAN can capture the token |
| `versionCode` | `1`, never bumped | Cannot tell builds apart or reason about upgrades |

The first row is the serious one. A person with a few minutes of physical access to a wall-mounted phone can extract the device token and then POST punches for **any employee in that company, from anywhere**. That is exactly the buddy-punching the badge-and-face rule exists to prevent, only easier and leaving no photo. Debug builds are fine for a piloted gate on a trusted LAN; they should not be screwed to a wall unattended, and should not go to a second site.

## Decisions taken during brainstorming

| Topic | Decision |
|---|---|
| Upload target | **Production domain over the internet.** Phones POST to the Linode host on 443 using the existing Let's Encrypt cert (`deploy_to_linode/setup_certbot_at_server.sh`). |
| TLS work | **None.** The release build's system-CA-only trust already works against a publicly-trusted cert. No bundled cert, no private CA, no VPN. |
| Internet outages | Covered by the **existing offline queue**. Punches sit in Room and upload when the line returns; `punched_at` is capture time, so late delivery is harmless. |
| Distribution | **Manual `adb install` per phone.** No OTA endpoint, no Play Console. Right for ~1–10 wall phones that are physically owned. |
| Keystore custody | **`~/keystores/qr_gate.jks`**, credentials in `~/.gradle/gradle.properties`. Nothing secret in the repo. Backup is the user's responsibility and is **mandatory**. |
| Minify / size | **Deferred.** Not in scope. |

### Rejected during brainstorming

- **LAN-local Phoenix with a bundled self-signed cert** — would have meant generating, pinning and rotating a cert inside the APK. Unnecessary once punches go to the public domain.
- **VPN back to Linode** — a VPN client that must auto-reconnect unattended on a kiosk phone, for no gain over plain HTTPS.
- **Self-hosted APK + in-app updater / Play Console** — a subsystem each, for a handful of phones the user physically handles.
- **git-derived `versionCode`** — breaks under history rewrites and makes a build non-reproducible from a tag.

## Design

### 1. Signing configuration

Keystore created once, outside the repo:

```bash
keytool -genkeypair -v -keystore ~/keystores/qr_gate.jks -alias qr_gate \
  -keyalg RSA -keysize 4096 -validity 10000 -storetype PKCS12
```

`~/.gradle/gradle.properties` (never committed):

```properties
QR_GATE_STORE_FILE=/home/tankwanghow/keystores/qr_gate.jks
QR_GATE_STORE_PASSWORD=…
QR_GATE_KEY_ALIAS=qr_gate
QR_GATE_KEY_PASSWORD=…
```

`app/build.gradle.kts` gains a `signingConfigs.release` reading those four properties, wired to `buildTypes.release`.

**`assembleRelease` must fail loudly when the properties are absent**, naming the missing property. Today the release block has no `signingConfig` at all, so it silently emits `app-release-unsigned.apk` — an artifact that cannot be installed and whose failure surfaces only at `adb install` time.

### 2. Cutover: the first release install wipes each phone's app data

A release-signed APK carries a different certificate from the debug build now installed. Android refuses the upgrade with `INSTALL_FAILED_UPDATE_INCOMPATIBLE`; the only path is uninstall first.

**Scope of the wipe: the `com.fullcircle.qrgate` package only.** Other apps, photos, contacts, Wi-Fi, accounts and the OS are untouched. Lost is the app's own state: `SharedPreferences` (pairing token + base URL), `punch_queue.db`, `filesDir/punch_photos/`, and the camera permission grant. Punches already accepted by Full Circle are safe on the server.

Per phone, once:

1. **Drain the queue.** Phone online; confirm recent punches appear in Punch IO. Anything still queued is lost at step 3.
2. **Revoke the device** in Punch Devices, so the token being discarded is dead.
3. `adb uninstall com.fullcircle.qrgate`
4. `adb install app/build/outputs/apk/release/app-release.apk`
5. **Pair fresh** from Punch Devices, against the production domain. Grant camera permission.

Every later release upgrade is a plain `adb install -r` and preserves pairing. Only this first crossing costs a re-pair.

`adb uninstall -k` is **not** a shortcut here: with a changed signature the retained data is orphaned rather than reused.

### 3. Reject cleartext pairing at pair time

Release builds forbid cleartext, but pairing only *stores* the URL — nothing fails until a punch tries to upload, and then it fails as an `IOException` that WorkManager retries indefinitely. The field symptom is a phone that says "OK" on every scan while delivering nothing, with no visible error.

`PairingActivity.analyze` must therefore validate the decoded URL before saving: parse the host and call `NetworkSecurityPolicy.getInstance().isCleartextTrafficPermitted(host)`. If the pairing URL is cleartext and the build forbids it, refuse the QR and show a message naming the problem, rather than storing it.

This keeps debug builds working against `http://<lan-ip>:4000` unchanged, because the policy returns true there.

### 4. Versioning and field identification

`versionCode` and `versionName` are bumped deliberately in `app/build.gradle.kts` per release; `versionCode` increases monotonically.

`versionName` is also rendered small and low-contrast in a corner of the scanner screen, so the build on a wall-mounted phone can be read off the glass without unmounting it or attaching adb. This is the only user-visible scanner change in this spec.

### 5. Verification

Scripted checks on the release artifact, all of which currently **fail** on the debug APK:

```bash
aapt2 dump badging  app-release.apk | grep -q application-debuggable && echo FAIL
apksigner verify --print-certs app-release.apk   # DN must NOT be CN=Android Debug
aapt2 dump xmltree --file AndroidManifest.xml app-release.apk \
  | grep usesCleartextTraffic                     # must be false
```

Then the live check: install per §2, pair against the production domain, punch once, and confirm the row **and its photo** in Punch IO. A release build that pairs but cannot upload is the specific failure §3 exists to prevent, so this step is not optional.

### 6. Documentation

`.claude/skills/qr-gate-punch.md` gains the release build command, the §2 cutover procedure, and the keystore-loss warning, alongside the existing debug build section.

## Risks

| Risk | Mitigation |
|---|---|
| **Keystore lost** → no further updates to installed apps, ever; recovery is uninstall + re-pair on every phone | Backup is mandatory and is the user's call; called out in the skill |
| Queue not drained before uninstall → silent loss of un-uploaded punches | §2 step 1 makes draining an explicit precondition |
| Phone paired against a cleartext URL in release → silent non-delivery | §3 refuses it at pair time |
| Debug and release APKs confused during the transition | Distinct filenames; §5 checks are cheap and definitive |

## Out of scope

- **Size.** The 63 MB is bundled ML Kit models and per-ABI native libs, not code, so `minify` buys little and risks ProGuard rules across ML Kit / CameraX / Room. An `arm64-v8a` filter would roughly halve it but would make a 32-bit phone fail to install confusingly. Both are known levers; neither is a current problem.
- **OTA updates**, Play Console distribution, and any in-app update check.
- Scanner behaviour: the badge/face rule, thresholds, flash and queue semantics are unchanged.
