// Plain-HTTP attachment upload for notes. Why not LiveView uploads: on phones
// the camera/file picker backgrounds the page, the socket can time out, and a
// remount throws away an in-flight socket upload. A transient <input> in
// document.body survives a remount; an XHR survives the socket dying.
const IMAGE_EXT = new Set(["jpg", "jpeg", "png", "webp", "heic", "heif", "bmp", "avif"])

function ext(name) {
  const i = name.lastIndexOf(".")
  return i >= 0 ? name.slice(i + 1).toLowerCase() : ""
}

async function downscale(file, maxEdge = 1920, quality = 0.85) {
  const isImage = IMAGE_EXT.has(ext(file.name)) || (file.type || "").startsWith("image/")
  if (!isImage || file.size < 50000 || file.type === "image/gif") return file
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
        if (this.liveSocket.isConnected()) {
          this.pushEventTo(this.el, "attachment_uploaded", { id: body.id })
        } else {
          window.location.reload()
        }
      } else {
        this.message(body.error || `Upload failed (${xhr.status}).`)
      }
    }
    xhr.onerror = () => this.message("Upload failed — check the connection and try again.")
    xhr.send(form)
  }
}
