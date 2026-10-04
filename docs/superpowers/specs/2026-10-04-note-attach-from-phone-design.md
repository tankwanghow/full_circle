# Note attachments: tray, multi-file, and "Add from phone"

Date: 2026-10-04 · Status: approved in conversation, awaiting spec review

## Why

Attaching a document to a note takes about ten steps today. You save the note first,
leave FullCircle for a camera or scanner app, come back, press ✎ Edit and 📎 Attach,
then dig through a file browser, one file per pick. The documents come from
**paper mail photographed on a phone** (often several pages), **WhatsApp**, and
**email**. The office scanner is out: walking to it is the problem.

FullCircle stays **desktop-first**. The 2026-09-29 Notes & Tasks spec says "No web
mobile UI", and this design keeps that rule. The phone gets one single-purpose
upload page reached by QR code, not a phone version of FullCircle. A native app
(sub-project 4 of that spec) is still possible later and can post to the same
endpoints.

## Decisions (from the brainstorm)

| # | Decision |
|---|---|
| 1 | Phone capture goes through a **QR handoff** to a small upload-only page, with no login on the phone |
| 2 | **Hold until Save:** files added while a write box is open belong to what you Save; Cancel discards them. This applies to new notes, edits and replies alike, and **changes** today's edit behaviour, where an upload attaches immediately and survives Cancel |
| 3 | A saved post's 📎 Attach (outside a write box) keeps attaching **immediately**, and gains 📱 From phone |
| 4 | Scans default to **Clean colour**; B&W and Original are a per-scan toggle |
| 5 | The phone link expires after **10 minutes idle**, counted from the last upload |
| 6 | A scan is uploaded **page by page** and the **server** builds the PDF when the person presses **Done**. A page reload mid-scan loses nothing, and the person decides where each PDF ends |
| 7 | Cancel **hard-deletes** tray files; a daily job deletes tray files and scan folders older than **24 hours** |

Out of scope: auto edge-detection and perspective crop (OpenCV.js is ~8 MB), an
installable PWA or Android share target, emailing documents in, phone layouts for
any other page, and new file types (still JPEG/PNG/WebP/PDF, 10 MB).

## What people see

### Desktop: the write box (new note, ✎ Edit, reply)

A **file tray** sits under the body, above visibility:

- **📎 Files** opens the picker with `multiple`, so several files go in one pick.
- **Drag and drop** files onto the write box, or **Ctrl+V** a screenshot or a copied
  file.
- **📱 From phone** opens a small dialog with a QR code, the text "Scan with your
  phone camera. Works for 10 minutes", and a ✕.
- Tray files show as `file_thumb/1` tiles, each with ✕ (hard delete). On ✎ Edit
  the note's existing files still show above them as today, and their ✕ still
  removes immediately (soft remove). Only *new* files wait for Save.
- **Save** attaches the tray. **Cancel** empties it.

### Desktop: a saved post's 📎 Attach

Unchanged, plus `multiple`, plus **📱 From phone**, whose QR targets that note:
uploads attach immediately, exactly like 📎.

### Phone: the upload page

The person scans the QR with the phone's own camera app, which opens
`/up/<token>`. The page is plain HTML and JS, not LiveView, because the camera
backgrounds the page and kills sockets. It shows:

- the header "Adding to: *‹note title›*", or "Adding to: a new note on the desktop";
- three large buttons:
  - **📄 Scan**: the camera opens (`capture="environment"`). Each page shows as a
    thumbnail strip as it uploads. **↺ Retake** replaces the last page. A toggle
    switches between **Clean colour** (the default), **B&W** and **Original**.
    **Done** asks the server to build one PDF named
    `Scan YYYY-MM-DD HHMM.pdf`. The person can then start the next scan, so one
    letter becomes one PDF.
  - **📷 Photo**: one photo becomes one JPEG attachment (re-encoded as
    `note_attach.js` does today).
  - **📎 Files**: the phone's picker with `multiple`, which reaches WhatsApp
    media, Downloads and saved email attachments.
- a list of everything sent, each ✓ or ✕ with a reason, and **↻ Retry** after a
  network failure.

The page remembers the scan in progress (scan id and page list) in
`localStorage`. After a reload it asks the server for that scan's pages and
carries on.

## How it works

### Data: the tray is attachments without a note

A small `note_trays` table (`id, company_id, user_id, note_id, closed_at`)
names each tray: its owner, and after Save the note it became. Amended during
planning: without it, a phone upload arriving after Save or Cancel had nowhere
to go. Late phone uploads now follow a saved tray to its note, and are refused
("closed on the desktop") after Cancel.

Migration on `note_attachments`:

- `note_id` becomes nullable;
- add `tray_id` referencing `note_trays`, nullable and indexed;
- add a check constraint: exactly one of `note_id` and `tray_id` is set.

A write box generates its `tray_id` (UUID) when it opens. Tray files are stored at
`<company>/notes/tray/<tray_id>/<uuid>.<ext>` under `uploads_dir`. `path` is
opaque, so claiming a file never moves it on disk.

`FullCircle.Notes.Attachments` gains:

- `attach_to_tray(tray_id, upload, company, user)`: the same size check and magic-byte
  sniff as `attach/4`. A tray belongs to the user who opened it, and only that
  user, or a phone token carrying their id, may add to it. The tray row records
  its owner; an upload into another user's tray id is refused. Combined with a random UUID
  `tray_id`, nobody else can add to a tray.
- `list_tray(tray_id, company, user)` returns the tray's files.
- `discard_tray(tray_id, company, user)` and `discard(att, company, user)` hard-delete rows and files.
- `claim_tray(multi, tray_id, note)`, an `Ecto.Multi` step, sets `note_id` and
  clears `tray_id`. `Notes.create_note` / `update_note` / the reply path accept a
  `tray_id` option and run this step **in the note's own transaction**. A failed or
  stale save (`{:error, :stale}`) leaves the tray as it was, just as typed text
  survives today.
- `prune_trays_before(datetime)` deletes tray rows and files plus scan folders
  older than the cutoff.

Removing a file from a *saved* note keeps today's soft remove (`removed_at`).
Hard delete applies only to files that never belonged to a note.

### Phone link token

`FullCircleWeb.PhoneUpload` (the same pattern as `FullCircleWeb.SharedDocument`):

- `sign(target, company_id, user_id)` creates a `Phoenix.Token` with its own salt.
  `target` is `{:tray, tray_id}` or `{:note, note_id}`.
- `verify(token)` accepts a token up to `max_age: 600` (10 minutes).
- Every successful upload response returns a **fresh token**, and the page stores
  it. That is how the 10-minute idle expiry slides.
- On every request the server reloads the user and company, and for a `{:note, _}`
  target re-runs `Notes.may_edit?/3`. A token never outlives the user's rights.

### Routes and controllers

Public scope (no session; the token *is* the auth), browser pipeline for the page
and an API-style pipeline (no CSRF; the token is the credential) for the posts:

| Route | Does |
|---|---|
| `GET /up/:token` | Renders the phone page (its own minimal layout and its own esbuild entry, `phone_upload.js`), or an "expired" page |
| `GET /up/:token/state` | JSON: the target's label, the files sent so far and any scan in progress |
| `POST /up/:token/files` | One file. Goes to the tray or to the note. Returns `{id, token}` |
| `POST /up/:token/scans/:scan_id/pages` | One JPEG page into `<uploads_dir>/scans/<scan_id>/NNN.jpg`. Returns `{page, token}` |
| `DELETE /up/:token/scans/:scan_id/pages/:n` | ↺ Retake: drop the last page |
| `POST /up/:token/scans/:scan_id/done` | Builds the PDF, attaches it like a file, deletes the folder. Returns `{id, token}` |

`scan_id` is a UUID made by the phone and validated as one, and a scan folder is
namespaced by `company_id`. A scan is capped at **30 pages**, and the built PDF
must still pass the 10 MB limit.

The desktop tray uses the existing logged-in upload controller, extended with a
`POST /companies/:company_id/note_trays/:tray_id/files` route beside
`/notes/:note_id/attachments`, and the same JSON contract.

### Building the PDF

`FullCircle.Notes.ScanPdf.build(jpeg_paths, out_path)` is pure Elixir with no new
dependency. It writes a PDF 1.4 file: one page per JPEG, each image embedded
as-is through `/DCTDecode`, with the page size taken from the JPEG's SOF dimensions
at 150 dpi and capped to fit A4. Pages are already JPEG, so nothing is re-encoded.

### Clean colour and B&W (on the phone, before upload)

These run in a `<canvas>` after downscaling to 1920 px on the long edge:

- **Clean colour**: take the 2nd and 98th luminance percentiles, apply a linear
  levels stretch on each channel so the paper goes white and the ink dark, keep
  the hue, and encode as JPEG at quality 0.8.
- **B&W**: greyscale plus a local adaptive threshold (mean over a ~31 px window
  minus a small constant), so shadows across the page don't swallow text; JPEG at
  quality 0.75.
- **Original**: downscale only.

### Desktop live updates

Every tray or note upload, from any source, broadcasts
`{:note_files_changed, target}` on `"note_files:#{company_id}"`.

- The composer, when it has a tray, and the notes panel / note page, for the
  notes they show, subscribe in their LiveView process, and register
  `{module, id, target}` in the process dictionary under `:note_files_listeners`.
- A new `on_mount` hook, `{FullCircleWeb.NoteFiles, :route}`, is added to the
  logged-in `live_session`s. It `attach_hook`s `handle_info`, matches
  `{:note_files_changed, target}`, and calls `send_update` on each registered
  listener whose target matches. This is the same idea as
  `RecordAside`'s `:refresh_tasks_panel` hook, so **no host LiveView needs
  code** for it.
- The desktop's own 📎 uploads use the same broadcast, which replaces today's
  `note-attach:done` → `attachment_uploaded` round trip for tray uploads.

### Cleanup

`FullCircle.Notes.TrayPruner` copies `PunchGate.PhotoPruner`: a supervised
GenServer that runs 5 minutes after boot and then daily, calling
`prune_trays_before(now - 24h)`.

## Errors

| Case | Phone shows | Desktop |
|---|---|---|
| Expired or invalid token | "This link has expired — show a new QR on the desktop" | — |
| User may no longer edit the note | "You can't add files to this note any more" | — |
| Too big or wrong type | That item is ✕ with the reason; the others carry on | — |
| Network drop | That item shows ↻ Retry; nothing already sent is lost | — |
| Write box cancelled while the phone is still sending | "This note was closed on the desktop" (the tray is gone) | Late files are pruned |
| Save fails or is stale | — | The tray stays as it was |
| Scan Done with 0 pages, or over 30 | "Take at least one page" / "Up to 30 pages per PDF" | — |
| PDF over 10 MB | "Too large — split into two scans" | — |

## Testing

- **Context** (`test/full_circle/notes/`):
  - a tray claim on create, update and reply, and a failed or stale save not
    claiming;
  - `discard_tray` removing files and rows;
  - the prune cutoff touching only tray rows and scan folders older than 24h,
    never claimed files;
  - the check constraint;
  - `ScanPdf.build` producing a valid PDF: `pdftoppm` renders page N, tagged
    `:pdftoppm` like the thumbnail tests.
- **Token**: rejected after 600 s idle, for the wrong company, the wrong note, or
  after the user loses edit rights; a refreshed token extends the window.
- **Controllers**: phone upload to a tray and to a note; scan pages → retake →
  done giving one PDF; every error row above.
- **LiveView**: write-box tray (upload shows a tile, ✕ hard-deletes, Save attaches,
  Cancel discards); a broadcast from a simulated phone upload making a file appear
  in an open write box and on a panel post with no reload; the multi-file picker
  attribute; edit mode still soft-removing existing files.
- **Browser**: the phone page in Chrome phone emulation (layout, state restore
  after a reload). **The real camera is checked by hand on an Android phone and an
  iPhone** before rollout.

## Docs to update in the same work

- `.claude/skills/notes.md`, *Attachments*: the tray, hold-until-Save, the phone
  token, and the `note_files` hook. Remove "Files attach after the first save".
- `CLAUDE.md`: nothing beyond the skill list, unless a new skill is split out.
