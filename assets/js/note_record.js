// In-app recording for notes: ⏺ Video (≤ 60 s) and 🎙 Audio (≤ 180 s).
// Record → preview → Send / Retake / Cancel. Send uploads through the same
// plain-HTTP path as 📎 (note_attach.js), with a `kind` field so the server
// can type a WebM, which holds either. No transcoding and no library:
// MediaRecorder records at the target quality (480p ~1 Mbit/s, 64 kbit/s).
//
// The overlay lives on document.body, outside every LiveView container, so a
// re-render cannot destroy a recording in progress. Every exit path stops the
// camera/mic tracks (the camera light goes off).
import { announce, listenDone, postFile } from "./note_attach"

// mp4 first: MediaRecorder's WebM has no duration or cues, so its seek bar is
// broken in many browsers. Firefox only offers WebM/Ogg.
const MIME = {
  video: ["video/mp4;codecs=avc1,mp4a", "video/mp4", "video/webm;codecs=vp9,opus", "video/webm"],
  audio: ["audio/mp4", "audio/webm;codecs=opus", "audio/webm", "audio/ogg;codecs=opus"]
}

const CONSTRAINTS = {
  video: { video: { facingMode: "environment", width: { ideal: 854 }, height: { ideal: 480 } }, audio: true },
  audio: { audio: true }
}

const BTN = {
  primary: "rounded-full bg-sky-600 px-4 py-2 font-semibold text-white hover:bg-sky-700 disabled:opacity-40 dark:bg-sky-500 dark:hover:bg-sky-600",
  stop: "rounded-full bg-rose-600 px-4 py-2 font-semibold text-white hover:bg-rose-700 disabled:opacity-40 dark:bg-rose-500 dark:hover:bg-rose-600",
  plain: "rounded-full border border-gray-300 px-4 py-2 hover:bg-gray-100 disabled:opacity-40 dark:border-gray-600 dark:hover:bg-gray-800"
}

const MSG = {
  info: "mt-2 min-h-5 text-sm text-gray-600 dark:text-gray-300",
  error: "mt-2 min-h-5 text-sm text-rose-600 dark:text-rose-400"
}

// Camera and microphone exist only in secure contexts (HTTPS, localhost).
export function canRecord() {
  return !!(navigator.mediaDevices?.getUserMedia && window.MediaRecorder)
}

// The ⏺/🎙 buttons are CSS-hidden until <html> carries `can-record`. <html>
// is outside LiveView, so no re-render can hide them again.
export function markCanRecord() {
  if (canRecord()) document.documentElement.classList.add("can-record")
}

function pickMime(kind) {
  return MIME[kind].find(m => MediaRecorder.isTypeSupported(m)) || ""
}

// "Video 2026-10-05 1432.mp4"; Safari's audio/mp4 is an .m4a.
function fileFor(blobs, kind, mime) {
  const type = mime.split(";")[0] || `${kind}/webm`
  const ext = type.endsWith("/mp4") ? (kind === "audio" ? "m4a" : "mp4") : type.endsWith("/ogg") ? "ogg" : "webm"
  const now = new Date()
  const p = n => String(n).padStart(2, "0")
  const stamp = `${now.getFullYear()}-${p(now.getMonth() + 1)}-${p(now.getDate())} ${p(now.getHours())}${p(now.getMinutes())}`
  const name = `${kind === "video" ? "Video" : "Audio"} ${stamp}.${ext}`
  return new File(blobs, name, { type })
}

const clock = sec => {
  const s = Math.max(0, Math.ceil(sec))
  return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, "0")}`
}

const mb = bytes => (bytes / 1000000).toFixed(1)

function errorText(e, kind) {
  const dev = kind === "video" ? "camera or microphone" : "microphone"
  switch (e && e.name) {
    case "NotAllowedError":
    case "SecurityError":
      return `Permission to use the ${dev} was denied. Allow it in the browser's site settings, then try again.`
    case "NotFoundError":
    case "OverconstrainedError":
      return `No ${dev} found on this device.`
    case "NotReadableError":
    case "AbortError":
      return `The ${dev} is busy in another app. Close it, then try again.`
    default:
      return `Could not start the ${dev}: ${(e && e.message) || e}`
  }
}

// `send(file, onProgress)` resolves `{ok, error}`; the overlay closes on ok
// and calls `onDone`.
export function openRecorder({ kind, maxSeconds, maxBytes, send, onDone }) {
  let stream = null
  let rec = null
  let chunks = []
  let timer = null
  let url = null
  let file = null
  let closed = false
  let uploading = false

  const overlay = document.createElement("div")
  overlay.className = "fixed inset-0 z-50 flex items-center justify-center bg-black/70 p-4"
  overlay.setAttribute("role", "dialog")
  overlay.setAttribute("aria-modal", "true")
  overlay.innerHTML = `
    <div class="w-full max-w-lg rounded-2xl bg-white p-4 text-gray-900 shadow-xl dark:bg-gray-900 dark:text-gray-100">
      <div class="flex items-center justify-between gap-2">
        <h2 class="font-bold"></h2>
        <span data-r="clock" class="font-mono tabular-nums"></span>
      </div>
      <div data-r="stage" class="mt-3"></div>
      <p data-r="msg" class="${MSG.info}"></p>
      <div data-r="buttons" class="mt-3 flex flex-wrap justify-end gap-2"></div>
    </div>`
  overlay.querySelector("h2").textContent = kind === "video" ? "⏺ Record a video" : "🎙 Record a voice note"
  const $ = name => overlay.querySelector(`[data-r=${name}]`)
  document.body.appendChild(overlay)
  const scroll = document.documentElement.style.overflow
  document.documentElement.style.overflow = "hidden"

  function say(text, level = "info") {
    $("msg").className = MSG[level]
    $("msg").textContent = text
  }

  function buttons(list) {
    const box = $("buttons")
    box.replaceChildren()
    for (const [label, style, onClick] of list) {
      const b = document.createElement("button")
      b.type = "button"
      b.className = BTN[style]
      b.textContent = label
      b.onclick = onClick
      box.appendChild(b)
    }
  }

  function stage(node) {
    $("stage").replaceChildren(...(node ? [node] : []))
  }

  function media(tag, attrs) {
    const m = document.createElement(tag)
    Object.assign(m, attrs)
    m.setAttribute("playsinline", "")
    m.className = tag === "video" ? "max-h-[60vh] w-full rounded-lg bg-black" : "w-full"
    return m
  }

  // Audio has no picture: a big countdown instead.
  function bigClock(text) {
    const d = document.createElement("div")
    d.className = "py-10 text-center text-5xl font-semibold tabular-nums"
    d.textContent = text
    return d
  }

  function stopTracks() {
    if (stream) stream.getTracks().forEach(t => t.stop())
    stream = null
  }

  // Drops a recorder without producing a preview.
  function dropRecorder() {
    clearInterval(timer)
    timer = null
    if (rec) {
      rec.onstop = null
      rec.ondataavailable = null
      if (rec.state !== "inactive") try { rec.stop() } catch (_e) {}
    }
    rec = null
  }

  function close() {
    closed = true
    dropRecorder()
    stopTracks()
    if (url) URL.revokeObjectURL(url)
    document.removeEventListener("keydown", onKey)
    document.documentElement.style.overflow = scroll
    overlay.remove()
  }

  const onKey = e => { if (e.key === "Escape" && !uploading) close() }
  document.addEventListener("keydown", onKey)

  function fail(text) {
    dropRecorder()
    stopTracks()
    stage(null)
    $("clock").textContent = ""
    say(text, "error")
    buttons([["Try again", "plain", open], ["Close", "plain", close]])
  }

  async function open() {
    if (url) URL.revokeObjectURL(url)
    url = null
    file = null
    stage(null)
    $("clock").textContent = clock(maxSeconds)
    say(kind === "video" ? "Starting the camera…" : "Starting the microphone…")
    buttons([["Cancel", "plain", close]])
    try {
      stream = await navigator.mediaDevices.getUserMedia(CONSTRAINTS[kind])
    } catch (e) {
      if (!closed) fail(errorText(e, kind))
      return
    }
    // Cancelled while the permission prompt was up.
    if (closed) return stopTracks()
    if (kind === "video") {
      const live = media("video", { srcObject: stream, muted: true, autoplay: true })
      stage(live)
      live.play().catch(() => {})
    } else {
      stage(bigClock("🎙"))
    }
    say(`Up to ${clock(maxSeconds)}. It stops by itself.`)
    buttons([["⏺ Record", "stop", record], ["Cancel", "plain", close]])
  }

  function record() {
    const mime = pickMime(kind)
    const opts = { audioBitsPerSecond: 64000 }
    if (mime) opts.mimeType = mime
    if (kind === "video") opts.videoBitsPerSecond = 1000000
    try {
      rec = new MediaRecorder(stream, opts)
    } catch (e) {
      return fail(`This browser cannot record here: ${e.message || e}`)
    }
    chunks = []
    rec.ondataavailable = e => { if (e.data && e.data.size) chunks.push(e.data) }
    rec.onstop = preview
    rec.onerror = e => fail(`Recording failed: ${(e.error && e.error.message) || "unknown error"}`)
    rec.start(1000)
    // So the user can tell which format each phone chose.
    console.info(`note recorder: ${kind} as ${rec.mimeType || mime || "browser default"}`)

    const t0 = performance.now()
    const tick = () => {
      const left = maxSeconds - (performance.now() - t0) / 1000
      $("clock").textContent = `${clock(left)} left`
      if (kind === "audio") $("stage").firstChild.textContent = clock(left)
      if (left <= 0) stop()
    }
    timer = setInterval(tick, 250)
    tick()
    say("Recording…")
    buttons([["■ Stop", "stop", stop], ["Cancel", "plain", close]])
  }

  function stop() {
    clearInterval(timer)
    timer = null
    if (rec && rec.state !== "inactive") rec.stop()
  }

  function preview() {
    // Camera light off while they watch it back; Retake asks again.
    stopTracks()
    file = fileFor(chunks, kind, rec.mimeType || pickMime(kind))
    rec = null
    chunks = []
    url = URL.createObjectURL(file)
    stage(media(kind, { src: url, controls: true }))
    $("clock").textContent = `${mb(file.size)} MB`
    if (file.size > maxBytes) {
      say(`This recording is ${mb(file.size)} MB, over the ${Math.floor(maxBytes / 1000000)} MB limit. Record a shorter one.`, "error")
      buttons([["↺ Retake", "plain", open], ["Cancel", "plain", close]])
    } else {
      say("Play it back, then send it or record again.")
      buttons([["Send", "primary", upload], ["↺ Retake", "plain", open], ["Cancel", "plain", close]])
    }
  }

  async function upload() {
    uploading = true
    for (const b of $("buttons").children) b.disabled = true
    say("Uploading…")
    const res = await send(file, pct => say(pct < 100 ? `Uploading… ${pct}%` : "Saving…"))
    uploading = false
    if (res.ok) {
      close()
      if (onDone) onDone()
      return
    }
    for (const b of $("buttons").children) b.disabled = false
    say(res.error || "Upload failed.", "error")
  }

  open()
}

// On `record_buttons/1`: one hook for both buttons, which carry their kind's
// limits. Finishing announces `note-attach:done` like NoteAttach, so the
// component holding the buttons refreshes its files.
export const NoteRecord = {
  mounted() {
    listenDone(this)
    this.el.addEventListener("click", e => {
      const btn = e.target.closest("button[data-kind]")
      if (!btn) return
      e.preventDefault()
      const kind = btn.dataset.kind
      // The address as of now, like 📎: a box that is saved meanwhile
      // forwards its tray's files to the note.
      const url = this.el.dataset.url
      openRecorder({
        kind,
        maxSeconds: parseInt(btn.dataset.maxSeconds, 10),
        maxBytes: parseInt(btn.dataset.maxBytes, 10),
        send: (file, onProgress) => postFile(url, file, { fields: { kind }, onProgress }),
        onDone: () => announce(this)
      })
    })
  }
}
