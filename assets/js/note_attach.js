// Plain-HTTP attachment upload for notes. Why not LiveView uploads: on phones
// the camera/file picker backgrounds the page, the socket can time out, and a
// remount throws away an in-flight socket upload. A transient <input> in
// document.body survives a remount; an XHR survives the socket dying.
// Only photo formats are re-encoded to JPEG. PNG/WebP/GIF can carry
// transparency (logos, screenshots) that JPEG would paint black.
const PHOTO_EXT = new Set(["jpg", "jpeg", "heic", "heif", "bmp", "avif"])
const PHOTO_TYPES = new Set(["image/jpeg", "image/heic", "image/heif", "image/bmp", "image/avif"])
const DONE_EVENT = "note-attach:done"

function ext(name) {
  const i = name.lastIndexOf(".")
  return i >= 0 ? name.slice(i + 1).toLowerCase() : ""
}

// maxEdge/quality come from the company's photo settings via data-max-edge
// and data-quality (quality as a percentage). See Attachments.photo_settings/1.
export function photoOpts(el) {
  return {
    maxEdge: parseInt(el.dataset.maxEdge, 10) || 1600,
    quality: (parseInt(el.dataset.quality, 10) || 75) / 100
  }
}

export async function downscale(file, { maxEdge = 1600, quality = 0.75 } = {}) {
  const isPhoto = PHOTO_EXT.has(ext(file.name)) || PHOTO_TYPES.has(file.type || "")
  if (!isPhoto || file.size < 50000) return file
  let bitmap
  try { bitmap = await createImageBitmap(file) } catch (_e) { return file }
  const scale = Math.min(1, maxEdge / Math.max(bitmap.width, bitmap.height))
  const canvas = document.createElement("canvas")
  canvas.width = Math.round(bitmap.width * scale)
  canvas.height = Math.round(bitmap.height * scale)
  canvas.getContext("2d").drawImage(bitmap, 0, 0, canvas.width, canvas.height)
  bitmap.close()
  const blob = await new Promise(r => canvas.toBlob(r, "image/jpeg", quality))
  if (!blob || blob.size >= file.size) return file
  const base = file.name.replace(/\.[^.]+$/, "") || "upload"
  return new File([blob], `${base}.jpg`, { type: "image/jpeg" })
}

// XHR, not fetch: fetch cannot report upload progress. Resolves
// `{status, body}` (body = parsed JSON or {}), or `{status: 0}` when the
// connection failed. `onProgress(pct)` gets whole percents, each once.
export function send(method, url, { body, headers = {}, onProgress } = {}) {
  return new Promise(resolve => {
    const xhr = new XMLHttpRequest()
    xhr.open(method, url)
    for (const [k, v] of Object.entries(headers)) xhr.setRequestHeader(k, v)
    if (onProgress) {
      let last = -1
      xhr.upload.onprogress = e => {
        if (!e.lengthComputable) return
        const pct = Math.floor((e.loaded / e.total) * 100)
        if (pct !== last) onProgress((last = pct))
      }
    }
    xhr.onload = () => {
      let parsed = {}
      try { parsed = JSON.parse(xhr.responseText) } catch (_e) {}
      resolve({ status: xhr.status, body: parsed })
    }
    xhr.onerror = () => resolve({ status: 0, body: {} })
    xhr.send(body)
  })
}

// `fields` go with the file (the recorder sends `kind`).
export async function postFile(url, file, { fields = {}, onProgress } = {}) {
  const form = new FormData()
  form.append("file", file, file.name)
  for (const [k, v] of Object.entries(fields)) form.append(k, v)
  const csrf = document.querySelector("meta[name='csrf-token']").content
  const { status, body } = await send("POST", url, { body: form, headers: { "x-csrf-token": csrf }, onProgress })
  if (status === 200) return { ok: true, body }
  if (status === 0) return { ok: false, error: "Upload failed — check the connection and try again." }
  if (status === 413) return { ok: false, error: "File is too large for the server." }
  return { ok: false, error: body.error || `Upload failed (${status}).` }
}

// Desktop video/audio files (📎, drop, paste) — not recorded, not shrunk —
// get the phone recorder's limits, from `NoteComponents.media_limits/0`.
const VIDEO_EXT = new Set(["mp4", "m4v", "mov", "webm"])
const AUDIO_EXT = new Set(["m4a", "mp3", "ogg", "oga", "opus"])

export function mediaLimits(el) {
  const n = key => parseInt(el.dataset[key], 10)
  return {
    video: { bytes: n("maxVideoBytes"), seconds: n("maxVideoSeconds") },
    audio: { bytes: n("maxAudioBytes"), seconds: n("maxAudioSeconds") }
  }
}

function mediaKind(file) {
  const type = file.type || ""
  if (type.startsWith("video/")) return "video"
  if (type.startsWith("audio/")) return "audio"
  if (VIDEO_EXT.has(ext(file.name))) return "video"
  if (AUDIO_EXT.has(ext(file.name))) return "audio"
  return null
}

// The clip's length in seconds, or null when this browser cannot tell (a
// codec it cannot play, a WebM without a duration): the server's size cap
// still applies then.
function duration(file, kind) {
  return new Promise(resolve => {
    const el = document.createElement(kind)
    const src = URL.createObjectURL(file)
    const timer = setTimeout(() => done(null), 10000)
    function done(value) {
      clearTimeout(timer)
      el.removeAttribute("src")
      URL.revokeObjectURL(src)
      resolve(value)
    }
    el.preload = "metadata"
    el.onloadedmetadata = () => done(Number.isFinite(el.duration) ? el.duration : null)
    el.onerror = () => done(null)
    el.src = src
  })
}

const clock = s => `${Math.floor(s / 60)}:${String(s % 60).padStart(2, "0")}`
const mb = bytes => Math.floor(bytes / 1000000)

// What to send for one picked file, or `{error}`: media is checked against
// its kind's limits and sent as is with a `kind` field (so an Android .m4a
// is stored as audio, not as a video with no picture); anything else is a
// photo/PDF, downscaled when it is a photo.
async function prepare(file, { maxBytes, photo, media }) {
  const kind = media && mediaKind(file)
  if (kind) {
    const limit = media[kind]
    if (file.size > limit.bytes) return { error: `larger than ${mb(limit.bytes)} MB` }
    const secs = await duration(file, kind)
    // A second of slack: a "1:00" clip is often 60.4 s.
    if (secs !== null && secs > limit.seconds + 1) return { error: `longer than ${clock(limit.seconds)}` }
    return { file, fields: { kind } }
  }
  const shrunk = await downscale(file, photo)
  if (shrunk.size > maxBytes) return { error: `larger than ${mb(maxBytes)} MB` }
  return { file: shrunk, fields: {} }
}

// One file at a time, so a slow line shows steady progress and one bad file
// does not stop the rest.
export async function uploadFiles(files, { url, maxBytes, photo, media, onMessage }) {
  const list = Array.from(files)
  let ok = 0
  const failed = []
  for (let i = 0; i < list.length; i++) {
    const n = list.length > 1 ? ` ${i + 1} of ${list.length}` : ""
    onMessage(`Uploading${n}…`)
    const { file, fields, error } = await prepare(list[i], { maxBytes, photo, media })
    if (error) {
      failed.push(`${list[i].name}: ${error}`)
      continue
    }
    // At 100% the bytes are sent; the server still checks and stores the file.
    const res = await postFile(url, file, { fields, onProgress: pct => onMessage(pct < 100 ? `Uploading${n}… ${pct}%` : `Saving${n}…`) })
    if (res.ok) ok++
    else failed.push(`${list[i].name}: ${res.error}`)
  }
  onMessage(failed.join(" · "))
  return { ok, failed }
}

// Announce to the element carrying this id *now*: the upload can outlive a
// re-render, and pushing from a detached element would reach the host
// LiveView instead of the component, which has no handler and would crash.
// No forced reload when the socket is down: that would lose unsaved input.
export function announce(hook) {
  const current = document.getElementById(hook.el.id)
  if (current && hook.liveSocket.isConnected()) current.dispatchEvent(new CustomEvent(DONE_EVENT))
}

export function listenDone(hook) {
  hook.el.addEventListener(DONE_EVENT, () => hook.pushEventTo(hook.el, "attachment_uploaded", {}))
}

export const NoteAttach = {
  mounted() {
    listenDone(this)
    this.el.addEventListener("click", e => {
      e.preventDefault()
      const input = document.createElement("input")
      input.type = "file"
      input.accept = "image/*,application/pdf,video/*,audio/*"
      input.multiple = this.el.dataset.multiple === "true"
      input.style.display = "none"
      document.body.appendChild(input)
      input.addEventListener("change", async () => {
        const files = Array.from(input.files || [])
        input.remove()
        if (files.length === 0) return
        const msg = document.getElementById(`${this.el.id}-msg`)
        const { ok } = await uploadFiles(files, {
          url: this.el.dataset.url,
          maxBytes: parseInt(this.el.dataset.maxBytes, 10),
          photo: photoOpts(this.el),
          media: mediaLimits(this.el),
          onMessage: t => { if (msg) msg.textContent = t || "" }
        })
        if (ok > 0) announce(this)
      })
      input.click()
    })
  }
}

// The write box's tray: drop files onto the box, or paste a screenshot /
// copied file anywhere in it. Plain-text paste is left alone.
export const NoteDrop = {
  mounted() {
    listenDone(this)
    const box = this.el.closest("[id$='-box']") || this.el
    const send = async files => {
      const msgEl = this.el.querySelector("[id$='-attach-msg']")
      const { ok } = await uploadFiles(files, {
        url: this.el.dataset.url,
        maxBytes: parseInt(this.el.dataset.maxBytes, 10),
        photo: photoOpts(this.el),
        media: mediaLimits(this.el),
        onMessage: t => { if (msgEl) msgEl.textContent = t || "" }
      })
      if (ok > 0) announce(this)
    }
    this.onDragOver = e => {
      if (!e.dataTransfer || !Array.from(e.dataTransfer.types).includes("Files")) return
      e.preventDefault()
      box.classList.add("ring-2", "ring-sky-400")
    }
    this.onDragLeave = () => box.classList.remove("ring-2", "ring-sky-400")
    this.onDrop = e => {
      if (!e.dataTransfer || e.dataTransfer.files.length === 0) return
      e.preventDefault()
      box.classList.remove("ring-2", "ring-sky-400")
      send(e.dataTransfer.files)
    }
    this.onPaste = e => {
      const files = e.clipboardData ? Array.from(e.clipboardData.files) : []
      if (files.length === 0) return
      e.preventDefault()
      send(files)
    }
    box.addEventListener("dragover", this.onDragOver)
    box.addEventListener("dragleave", this.onDragLeave)
    box.addEventListener("drop", this.onDrop)
    box.addEventListener("paste", this.onPaste)
    this.box = box
  },
  destroyed() {
    if (!this.box) return
    this.box.removeEventListener("dragover", this.onDragOver)
    this.box.removeEventListener("dragleave", this.onDragLeave)
    this.box.removeEventListener("drop", this.onDrop)
    this.box.removeEventListener("paste", this.onPaste)
  }
}
