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

async function downscale(file, maxEdge = 1920, quality = 0.85) {
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

export const NoteAttach = {
  mounted() {
    // The upload can outlive this element: the panel may re-render while the
    // XHR runs. The finished upload is announced to whichever element carries
    // this id *now*, and that element's hook pushes to its own component.
    // Pushing from a detached element would reach the host LiveView instead,
    // which has no handler for it and would crash, losing unsaved input.
    this.el.addEventListener(DONE_EVENT, e => {
      this.pushEventTo(this.el, "attachment_uploaded", e.detail || {})
    })
    this.el.addEventListener("click", e => {
      e.preventDefault()
      const input = document.createElement("input")
      input.type = "file"
      input.accept = "image/*,application/pdf"
      input.style.display = "none"
      document.body.appendChild(input)
      input.addEventListener("change", () => {
        const file = input.files && input.files[0]
        input.remove()
        if (file) this.upload(file)
      })
      input.click()
    })
  },

  message(text) {
    const el = document.getElementById(`${this.el.id}-msg`)
    if (el) el.textContent = text || ""
  },

  async upload(original) {
    const file = await downscale(original)
    const max = parseInt(this.el.dataset.maxBytes, 10)
    if (file.size > max) {
      this.message(`File is larger than ${Math.floor(max / 1000000)} MB.`)
      return
    }
    this.message("Uploading…")
    const form = new FormData()
    form.append("file", file, file.name)
    const xhr = new XMLHttpRequest()
    xhr.open("POST", this.el.dataset.url)
    xhr.setRequestHeader("x-csrf-token", document.querySelector("meta[name='csrf-token']").content)
    xhr.onload = () => {
      let body = {}
      try { body = JSON.parse(xhr.responseText) } catch (_e) {}
      if (xhr.status === 200) {
        this.message("")
        const current = document.getElementById(this.el.id)
        if (current && this.liveSocket.isConnected()) {
          current.dispatchEvent(new CustomEvent(DONE_EVENT, { detail: { id: body.id } }))
        }
        // Otherwise the file is saved and the page shows it on its next
        // (re)load. No forced reload: that would throw away unsaved input.
      } else {
        this.message(body.error || `Upload failed (${xhr.status}).`)
      }
    }
    xhr.onerror = () => this.message("Upload failed — check the connection and try again.")
    xhr.send(form)
  }
}
