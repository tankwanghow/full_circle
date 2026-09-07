# QR Gate scanner (Android)

Wall-mounted kiosk: scan a printed employee badge (`fcqa:<uuid>` or a bare UUID), take an audit face JPEG, queue offline, POST to Full Circle.

No ERP login. Config is only the pairing QR: token + API base URL in `SharedPreferences`.

## Requirements

- **JDK 17+** (Android Gradle Plugin 8.7 needs it; a JRE 8 install is not enough)
- **Android SDK** with `platforms;android-35`, `build-tools;35.0.0`, `platform-tools`
- `ANDROID_HOME` (or `sdk.dir` in `local.properties`)
- A phone/tablet with a **front camera** (min API 26)

This repo includes the Gradle wrapper (`./gradlew`, `gradle/wrapper/`). To regenerate it on a machine that already has Gradle:

```bash
gradle wrapper --gradle-version 8.11.1 --distribution-type bin
```

### SDK on a fresh Linux box

```bash
# 1. JDK 17
sudo apt install openjdk-17-jdk

# 2. Command-line tools → https://developer.android.com/studio#command-tools
mkdir -p "$HOME/Android/Sdk/cmdline-tools"
unzip commandlinetools-linux-*.zip -d "$HOME/Android/Sdk/cmdline-tools"
mv "$HOME/Android/Sdk/cmdline-tools/cmdline-tools" "$HOME/Android/Sdk/cmdline-tools/latest"

export ANDROID_HOME="$HOME/Android/Sdk"
export PATH="$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools:$PATH"

yes | sdkmanager --licenses
sdkmanager "platform-tools" "platforms;android-35" "build-tools;35.0.0"
```

## Assemble debug APK

```bash
cd android/qr_gate
printf 'sdk.dir=%s\n' "$ANDROID_HOME" > local.properties   # gitignored
./gradlew assembleDebug
```

APK: `app/build/outputs/apk/debug/app-debug.apk`

`./gradlew assembleDebug` **cannot run in the SDD worktree environment**: there is `/usr/bin/java` (OpenJDK 8 JRE, no `javac`) and `/usr/bin/adb`, but **no `ANDROID_HOME` / `sdkmanager`**. Source is complete; build on a machine that meets the requirements above.

## Install

```bash
adb install -r app/build/outputs/apk/debug/app-debug.apk
# or
adb install -r app/build/outputs/apk/debug/app-debug.apk && adb shell am start -n com.fullcircle.qrgate/.PairingActivity
```

Allow camera permission on first launch.

## Pair from Full Circle

1. Admin / manager / supervisor: **Punch Devices** → name the gate → **Pair new phone**.
2. Point the **phone** at that pairing QR (`fcpair:<device_id>:<token>:<url>`). Pairing uses the back camera when present.
3. The app stores token + base URL and switches to scanner mode (front camera, lock-task when the OS allows).

**Wi-Fi only is enough** — no SIM / mobile data. The pairing URL must be reachable on that Wi-Fi (the farm LAN or a VPN), not `localhost` on the phone.

If the QR encodes `http://localhost:4000`, the phone cannot reach your PC. Before pairing, make `FullCircleWeb.Endpoint.url()` a LAN address, e.g. in `config/dev.exs`:

```elixir
url: [host: "192.168.1.50", port: 4000],
http: [ip: {0, 0, 0, 0}, port: 4000],
```

then restart Phoenix and create the device again.

## Scan a badge

1. Square overlay: hold the printed employee badge in the box (`fcqa:` payload, or a bare UUID from older cards).
2. Oval overlay + “Look at the camera”: ML Kit **face detection** on live frames, then a still. **Zero faces → reject beep, no JPEG, no queue row; keep the oval.** At least one face → JPEG (long side 480px, quality 70, recapture if `> 300_000` bytes). Detection only (no matching / enrolment). **No photo → no punch.**
3. If **no face within 8 seconds**, reject beep, clear the pending employee, back to the QR square (no punch).
4. “OK” 1.5s, beep, back to the QR step. After returning to QR, ignore all badges for **2s**. The **same employee** is ignored for **3 minutes** (duplicate window) with a distinct reject beep — no second punch queued. **`punched_at` is badge-scan time** (UTC ISO-8601), not face-capture or upload time.

There is no flip-camera control and no employee list.

## Offline queue

Room + WorkManager. Airplane mode: scan as usual; when the network returns, rows upload in time order with the same `client_id` (server is idempotent).

| Server | Phone |
|---|---|
| 201 | delete queue row |
| 401 | **DELETE the whole queue table** and punch JPEG files, `Prefs.remove(token)` (listener fires) so the scanner returns to pairing immediately |
| 404 / 422 / 409 (and other 4xx, including 413) | delete that queue row; **do not retry forever** |
| network / 5xx | increment `tries`, WorkManager exponential backoff |

## Local HTTPS vs HTTP (dev)

Debug builds set `android:usesCleartextTraffic=true` and trust **user** CAs, so either:

- **HTTP** on port 4000 (`http://<lan-ip>:4000`) — easiest on the LAN, or
- **HTTPS** on port 4001: install `priv/cert/selfsigned.pem` as a user CA on the phone (Settings → Security → Encryption & credentials → Install a certificate), **or** trust the cert some other way.

Release builds do not allow cleartext and trust only system CAs.

## Kiosk

- Screen stays on (`FLAG_KEEP_SCREEN_ON` + `android:keepScreenOn` on the root view).
- `startLockTask()` when the app is pin-allowlisted (Settings → Security → App pinning, or a DPC). Otherwise pin from Recents.
- Back button is ignored on the scanner screen.

## Manual gate check

- Pair phone → scanner mode.
- Print an employee badge (payload `fcqa:<id>`).
- Scan + face → Punch IO shows a 📷 for that slot.
- Airplane mode: scan twice (wait 3+ minutes), restore network → both rows appear in time order with rebuilt flags.
- Revoke device → next upload 401, **entire** local queue + photos wiped, phone returns to pairing (nothing left to upload under the next device).
