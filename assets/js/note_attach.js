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

export async function downscale(file, maxEdge = 1920, quality = 0.85) {
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

function post(url, file) {
  return new Promise(resolve => {
    const form = new FormData()
    form.append("file", file, file.name)
    const xhr = new XMLHttpRequest()
    xhr.open("POST", url)
    xhr.setRequestHeader("x-csrf-token", document.querySelector("meta[name='csrf-token']").content)
    xhr.onload = () => {
      let body = {}
      try { body = JSON.parse(xhr.responseText) } catch (_e) {}
      resolve(xhr.status === 200 ? { ok: true, body } : { ok: false, error: body.error || `Upload failed (${xhr.status}).` })
    }
    xhr.onerror = () => resolve({ ok: false, error: "Upload failed — check the connection and try again." })
    xhr.send(form)
  })
}

// One file at a time, so a slow line shows steady progress and one bad file
// does not stop the rest.
export async function uploadFiles(files, { url, maxBytes, onMessage }) {
  const list = Array.from(files)
  let ok = 0
  const failed = []
  for (let i = 0; i < list.length; i++) {
    onMessage(list.length > 1 ? `Uploading ${i + 1} of ${list.length}…` : "Uploading…")
    const file = await downscale(list[i])
    if (file.size > maxBytes) {
      failed.push(`${list[i].name}: larger than ${Math.floor(maxBytes / 1000000)} MB`)
      continue
    }
    const res = await post(url, file)
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
function announce(hook) {
  const current = document.getElementById(hook.el.id)
  if (current && hook.liveSocket.isConnected()) current.dispatchEvent(new CustomEvent(DONE_EVENT))
}

function listenDone(hook) {
  hook.el.addEventListener(DONE_EVENT, () => hook.pushEventTo(hook.el, "attachment_uploaded", {}))
}

export const NoteAttach = {
  mounted() {
    listenDone(this)
    this.el.addEventListener("click", e => {
      e.preventDefault()
      const input = document.createElement("input")
      input.type = "file"
      input.accept = "image/*,application/pdf"
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
