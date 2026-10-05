# Note video & audio recordings — design

Date: 2026-10-05 · Status: approved in chat (decisions below are the user's)

## Goal

Let people put a short video or voice recording on a note, recorded **inside
the app**, small enough to upload in seconds on a phone and to keep forever.

## Decisions (from the user)

| Question | Decision |
|---|---|
| Native Android app? | No — web only. |
| How clips get in | **In-app recording only** (⏺ Video, 🎙 Audio). No picking existing media files. |
| Length | Video **≤ 60 s**, audio **≤ 180 s**. The recorder stops itself at the limit, with a countdown. |
| After stop | **Preview first**: play it back, then **Send** or **Retake** (or Cancel). |
| Quality | Video 480p (854×480 ideal), ~1 Mbit/s; audio ~64 kbit/s. Recorded at that quality — no transcoding step, no JS library. |

Photos and PDFs are unchanged (10 MB, existing flow).

## Size limits (per kind)

| Kind | Max bytes | Why |
|---|---|---|
| image / pdf | 10 MB (unchanged) | |
| video | 15 MB | 60 s × ~1.1 Mbit/s ≈ 8.5 MB, plus encoder overshoot |
| audio | 5 MB | 180 s × 64 kbit/s ≈ 1.5 MB, plus slack |

`Plug.Parsers` multipart `length` in `endpoint.ex` rises from 12 MB to
17 MB (15 MB + overhead). Prod nginx is already `client_max_body_size 50M`
at server level — no change.

No server-side duration check: the size cap is what protects the disk; the
duration limit is enforced by the recorder (YAGNI on parsing mp4/webm
headers).

## Recording (browser)

New JS module `assets/js/note_record.js`, a LiveView hook `NoteRecord` on a
new `record_buttons/1` component (in `NoteComponents`), rendered **next to
every `attach_button/1`** (composer tray, note form ×2, notes panel) and on
the 📱 phone page (`phone_upload.js` + its template).

- Feature detection: hide the buttons when `navigator.mediaDevices?.getUserMedia`
  or `window.MediaRecorder` is missing. Camera/mic need a secure context
  (HTTPS or localhost); on plain-HTTP dev over LAN the buttons stay hidden.
- The recorder is an overlay appended to `document.body` (outside every
  LiveView container, like the file viewer and `NoteAttach`'s transient
  input), so a re-render cannot destroy a recording in progress.
- Video: `getUserMedia({video: {facingMode: "environment", width: {ideal: 854},
  height: {ideal: 480}}, audio: true})`; live preview muted + `playsinline`.
  Audio: `getUserMedia({audio: true})`, big timer.
- `MediaRecorder` mime: first of `isTypeSupported` in
  video: `video/mp4;codecs=avc1,mp4a`, `video/mp4`, `video/webm;codecs=vp9,opus`,
  `video/webm`; audio: `audio/mp4`, `audio/webm;codecs=opus`, `audio/webm`,
  `audio/ogg;codecs=opus`. **Prefer mp4**: MediaRecorder WebM has no duration
  / cues, so its seek bar is broken in many browsers.
  `videoBitsPerSecond: 1_000_000`, `audioBitsPerSecond: 64_000`.
- States: idle (⏺ Record) → recording (■ Stop, "0:42 left", auto-stop at the
  limit) → preview (`<video>`/`<audio controls>` of the blob; **Send**,
  **Retake**, **Cancel**) → uploading. Always stop all tracks on
  close/cancel/send (camera light off).
- Send builds `new File([blob], "Video 2026-10-05 1432.mp4"|"Audio … .m4a"/.webm/.ogg)`
  and uploads through the **existing** path: `send()`/`uploadFiles` in
  `note_attach.js` (desktop: the button's `data-url`; phone: `call("POST",
  "/files", …)`), with progress. It adds form field `kind=video|audio` so the
  server can type a WebM correctly (see sniffing). No downscale step for media.
- Client checks the blob against `data-max-bytes` for its kind before
  sending (message, not a silent drop).
- Errors shown in the overlay: permission denied, no camera/mic, recorder
  error. Finishing announces `note-attach:done` exactly like `NoteAttach`.

## Server

### Types (`Attachments.sniff/1` + `kind/1`)

Read the first 32 bytes. New accepted containers:

| Magic | Container |
|---|---|
| bytes 4..8 = `ftyp` | mp4 (brand `M4A ` → audio) |
| `1A 45 DF A3` | webm |
| `OggS` | ogg |

Content type = `"#{kind}/#{sub}"` where `sub` is `mp4`/`webm`/`ogg` and
`kind` is: `audio` for brand `M4A ` and for ogg; otherwise the client's
`kind` field **when it is `"audio"` or `"video"`**, defaulting to `video`.
The client's hint only picks between two inert media types for a container
the server already verified — it never makes a non-media file acceptable.
Extensions: `.mp4`, `.webm`, `.ogg`, `.m4a` (audio/mp4).

`kind/1` gains `:video` (`"video/" <> _`) and `:audio` (`"audio/" <> _`).
`thumb_file/1`: no preview for both (404 on `?variant=thumb`).
`max_bytes/1` per kind (above); `max_bytes/0` stays the image/PDF 10 MB.
`assert_size` checks against the limit for the sniffed kind (sniff first,
then size — sniff reads 32 bytes only).

The kind hint reaches `store/4` through the upload map (`"kind"`) from
`NoteAttachmentController` (both `create` and `create_tray`) and
`PhoneUploadController`.

### Serving (`NoteAttachmentController.show/2`)

Add HTTP **Range** support (iPhone Safari will not play video without it;
seeking needs it everywhere): always `accept-ranges: bytes`; a single
`bytes=a-b`, `bytes=a-` or `bytes=-n` → `206` + `content-range`, 
`send_file(conn, 206, path, offset, length)`; unsatisfiable → `416` with
`content-range: bytes */size`; multiple ranges or junk → ignore and send the
full `200`. Applies to every file (harmless for images/PDF).

## Display

- `file_thumb/1`: `:video` → dark tile with ▶ and the name; `:audio` → tile
  with 🎙 and the name. (No posters — no server ffmpeg.)
- `file_grid/1`: video/audio are **not** `data-viewer` items. Render them as
  players in place of the link: `<video controls playsinline
  preload="metadata" src={url <> "#t=0.1"}>` (the fragment makes iOS show a
  first frame) and `<audio controls preload="metadata">` with the file name
  above it. The ✕ remove button and name bar keep working for them.
- Same in the tray (before Save) so the writer can check what they sent.
- Phone page sent list: 🎬 / 🎙 tiles (`thumbFor`).

## Tests (ExUnit)

- `Attachments`: sniffing each new magic (tiny header fixtures written to tmp
  files), the kind hint rules (`M4A ` and ogg force audio; webm honours the
  hint; a bad hint → video; a non-media file with a hint is still rejected),
  per-kind size caps (a 12 MB video accepted, a 6 MB audio refused, an 11 MB
  JPEG refused).
- Controller: Range → 206 with correct `content-range` and body slice; open
  and suffix ranges; 416 beyond EOF; no Range → 200 + `accept-ranges`.
- Components/LiveView: a note with a video and an audio attachment renders
  `<video>` / `<audio>` with the file URL; the record buttons render with
  `data-max-bytes`/`data-max-seconds` for each kind next to 📎.
- JS has no test runner here: verify by hand (below).

## Manual verification (user, on real phones)

Android Chrome and iPhone Safari, on prod-like HTTPS (dev `https://<LAN-IP>:4001`):
record video → auto-stop at 60 s → preview → Send → appears in tray → Save →
plays and **seeks** on both phones and desktop Chrome/Firefox. Same for audio
at 180 s. Deny permission → readable message. Check which mime each phone
chose (logged to console).

## Out of scope

Off-site backup of `uploads/` (separate task, B2 planned), picking existing
media, transcoding, posters, server-side duration parsing, company settings
for media limits, native app.

## Docs

Update `.claude/skills/notes.md` (Attachments: kinds, limits, Range, recorder)
and the size-limits paragraph.
