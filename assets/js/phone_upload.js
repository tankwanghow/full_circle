// The phone upload page (/up/:token): scan pages into one PDF, take a photo,
// or pick files (WhatsApp media, Downloads, saved email attachments). Plain
// HTTP to the endpoints in PhoneUploadController. Every success returns a
// fresh token; it replaces the one in the URL so a reload keeps working
// within the 10-minute idle window. A scan in progress is remembered in
// localStorage and resumed from the server's page count after a reload.
import { downscale, photoOpts, send } from "./note_attach"

const root = document.getElementById("phone-upload")
if (root) start(root)

// crypto.randomUUID exists only in secure contexts (https, localhost); the
// dev phone test runs over http on the LAN.
function uuid() {
  if (crypto.randomUUID) return crypto.randomUUID()
  const b = crypto.getRandomValues(new Uint8Array(16))
  b[6] = (b[6] & 0x0f) | 0x40
  b[8] = (b[8] & 0x3f) | 0x80
  const h = Array.from(b, x => x.toString(16).padStart(2, "0")).join("")
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-${h.slice(12, 16)}-${h.slice(16, 20)}-${h.slice(20)}`
}

function start(root) {
  let token = root.dataset.token
  const maxBytes = parseInt(root.dataset.maxBytes, 10)
  const photo = photoOpts(root)
  const scanKey = `phoneUpload:scan:${root.dataset.targetKey}`
  const sentKey = `phoneUpload:sent:${root.dataset.targetKey}`
  const $ = id => document.getElementById(id)
  let scan = null // {id, pages}
  let busy = false // one scan request at a time: pages must not race each other

  function setBusy(on) {
    busy = on
    for (const id of ["pu-next", "pu-retake", "pu-done"]) $(id).disabled = on
  }

  const store = {
    get(k) { try { return JSON.parse(localStorage.getItem(k)) } catch (_e) { return null } },
    set(k, v) { try { localStorage.setItem(k, JSON.stringify(v)) } catch (_e) {} },
    del(k) { try { localStorage.removeItem(k) } catch (_e) {} }
  }

  function banner(text) {
    $("pu-banner").textContent = text
    $("pu-banner").classList.remove("hidden")
    for (const id of ["pu-scan", "pu-photo", "pu-files", "pu-next", "pu-retake", "pu-done"]) $(id).disabled = true
  }

  function refresh(body) {
    if (body && body.token) {
      token = body.token
      history.replaceState(null, "", `/up/${token}`)
    }
  }

  async function call(method, path, form, onProgress) {
    const { status, body } = await send(method, `/up/${token}${path}`, { body: form, onProgress })
    if (status === 0) return { ok: false, retry: true, error: "No connection — tap ↻ to retry." }
    if (status >= 200 && status < 300) { refresh(body); return { ok: true, body } }
    if (body.code === "expired" || body.code === "closed" || body.code === "forbidden") banner(body.error)
    if (status === 413) return { ok: false, retry: false, error: "Too large for the server." }
    return { ok: false, retry: false, error: body.error || `Failed (${status}).` }
  }

  // --- sent list -----------------------------------------------------------

  // `thumb`: an image URL (photo, scan page), "pdf" for a 📄 tile, or none
  // (names restored after a reload have no picture left).
  function addSent(name, thumb) {
    const li = document.createElement("li")
    li.className = "flex items-center gap-2 rounded bg-white p-2 dark:bg-gray-900"
    li.innerHTML = `<span class="pu-mark">⏳</span><span class="pu-name truncate"></span><span class="pu-err ml-auto text-rose-600 dark:text-rose-400"></span>`
    li.querySelector(".pu-name").textContent = name
    if (thumb) {
      const tile = document.createElement(thumb === "pdf" ? "span" : "img")
      tile.className = "h-12 w-12 shrink-0 rounded border border-gray-300 object-cover dark:border-gray-600"
      if (thumb === "pdf") {
        tile.className += " flex items-center justify-center text-2xl"
        tile.textContent = "📄"
      } else {
        tile.src = thumb
        tile.alt = ""
      }
      li.querySelector(".pu-mark").after(tile)
    }
    $("pu-sent").prepend(li)
    return li
  }

  function thumbFor(file) {
    if ((file.type || "").startsWith("image/")) return URL.createObjectURL(file)
    if (file.type === "application/pdf" || /\.pdf$/i.test(file.name)) return "pdf"
    return null
  }

  function markSent(li, res, retry) {
    li.querySelector(".pu-mark").textContent = res.ok ? "✓" : "✕"
    li.querySelector(".pu-err").textContent = res.ok ? "" : res.error
    if (res.ok) {
      const names = store.get(sentKey) || []
      store.set(sentKey, [li.querySelector(".pu-name").textContent, ...names].slice(0, 30))
    } else if (res.retry && retry) {
      const b = document.createElement("button")
      b.type = "button"
      b.textContent = "↻"
      b.className = "ml-2 rounded bg-gray-200 px-2 dark:bg-gray-800"
      b.onclick = async () => { b.remove(); li.querySelector(".pu-mark").textContent = "⏳"; markSent(li, await retry(), retry) }
      li.appendChild(b)
    }
  }

  for (const name of (store.get(sentKey) || []).slice().reverse()) {
    const li = addSent(name)
    li.querySelector(".pu-mark").textContent = "✓"
  }

  // --- pickers -------------------------------------------------------------

  function pick({ capture, multiple, accept }, onFiles) {
    const input = document.createElement("input")
    input.type = "file"
    input.accept = accept
    if (capture) input.capture = "environment"
    input.multiple = !!multiple
    input.style.display = "none"
    document.body.appendChild(input)
    input.addEventListener("change", () => {
      const files = Array.from(input.files || [])
      input.remove()
      if (files.length) onFiles(files)
    })
    input.click()
  }

  async function sendFile(file) {
    const ready = await downscale(file, photo)
    const li = addSent(file.name, thumbFor(ready))
    const attempt = async () => {
      if (ready.size > maxBytes) return { ok: false, error: `Larger than ${Math.floor(maxBytes / 1000000)} MB.` }
      const form = new FormData()
      form.append("file", ready, ready.name)
      const mark = li.querySelector(".pu-mark")
      return call("POST", "/files", form, pct => { mark.textContent = pct < 100 ? `⏳ ${pct}%` : "⏳" })
    }
    markSent(li, await attempt(), attempt)
  }

  $("pu-photo").onclick = () => pick({ capture: true, accept: "image/*" }, files => sendFile(files[0]))
  $("pu-files").onclick = () =>
    pick({ multiple: true, accept: "image/*,application/pdf" }, async files => { for (const f of files) await sendFile(f) })

  // --- scanning ------------------------------------------------------------

  function showScan() {
    $("pu-scanning").classList.toggle("hidden", !scan)
    $("pu-pages").textContent = scan ? `${scan.pages} ${scan.pages === 1 ? "page" : "pages"}` : ""
  }

  function startScan() {
    scan = { id: uuid(), pages: 0 }
    store.set(scanKey, scan)
    $("pu-thumbs").innerHTML = ""
    showScan()
    takePage()
  }

  function alertLine(text) {
    const li = addSent(text)
    li.querySelector(".pu-mark").textContent = "✕"
  }

  function takePage() {
    if (busy) return
    pick({ capture: true, accept: "image/*" }, files => addPage(files[0]))
  }

  async function addPage(file) {
    if (busy) return
    setBusy(true)
    try { await sendPage(file) } finally { setBusy(false) }
  }

  async function sendPage(file) {
    const blob = await enhance(file, $("pu-look").value)
    const thumb = document.createElement("img")
    thumb.src = URL.createObjectURL(blob)
    thumb.className = "h-20 rounded border border-gray-300 opacity-50 dark:border-gray-600"
    $("pu-thumbs").appendChild(thumb)
    const form = new FormData()
    form.append("file", blob, "page.jpg")
    const res = await call("POST", `/scans/${scan.id}/pages`, form)
    if (res.ok) {
      thumb.classList.remove("opacity-50")
      scan.pages = res.body.pages
      store.set(scanKey, scan)
    } else {
      thumb.remove()
      alertLine(res.error)
    }
    showScan()
  }

  $("pu-scan").onclick = () => (scan ? takePage() : startScan())
  $("pu-next").onclick = () => takePage()

  $("pu-retake").onclick = async () => {
    if (busy || !scan || scan.pages === 0) return
    setBusy(true)
    const res = await call("DELETE", `/scans/${scan.id}/pages/last`)
    setBusy(false)
    if (!res.ok) return alertLine(res.error)
    scan.pages = res.body.pages
    store.set(scanKey, scan)
    const last = $("pu-thumbs").lastElementChild
    if (last) last.remove()
    showScan()
    takePage()
  }

  $("pu-done").onclick = async () => {
    if (busy || !scan) return
    setBusy(true)
    const now = new Date()
    const p = n => String(n).padStart(2, "0")
    const name = `Scan ${now.getFullYear()}-${p(now.getMonth() + 1)}-${p(now.getDate())} ${p(now.getHours())}${p(now.getMinutes())}.pdf`
    const first = $("pu-thumbs").querySelector("img")
    const pages = `${scan.pages} ${scan.pages === 1 ? "page" : "pages"}`
    const li = addSent(`${name} (${pages})`, first ? first.src : "pdf")
    const form = new FormData()
    form.append("name", name)
    const res = await call("POST", `/scans/${scan.id}/done`, form)
    setBusy(false)
    markSent(li, res, null)
    if (res.ok) {
      scan = null
      store.del(scanKey)
      $("pu-thumbs").innerHTML = ""
      showScan()
    }
  }

  // ✓ Close: end the link now (not after 10 idle minutes) and say all is
  // sent. The page stays: no window.close(), no navigation.
  $("pu-close").onclick = async () => {
    if (scan && scan.pages > 0 &&
        !confirm(`${scan.pages} scanned ${scan.pages === 1 ? "page is" : "pages are"} not sent as a PDF yet. Close anyway?`)) return
    $("pu-close").disabled = true
    const res = await call("POST", "/finish")
    // Expired/closed already shows the banner; a dropped connection lets them retry.
    if (!res.ok) { $("pu-close").disabled = !res.retry; return }
    store.del(scanKey)
    scan = null
    showScan()
    $("pu-finished").classList.remove("hidden")
    for (const id of ["pu-scan", "pu-photo", "pu-files", "pu-next", "pu-retake", "pu-done", "pu-close"]) $(id).disabled = true
    $("pu-finished").scrollIntoView({ behavior: "smooth", block: "center" })
  }

  // Resume a scan the page was reloaded in the middle of.
  const saved = store.get(scanKey)
  if (saved && saved.id) {
    call("GET", `/state?scan_id=${encodeURIComponent(saved.id)}`).then(res => {
      if (res.ok && res.body.pages > 0) {
        scan = { id: saved.id, pages: res.body.pages }
        showScan()
      } else {
        store.del(scanKey)
      }
    })
  }

  // For checking the page without a camera (DevTools): window.__phoneUpload.
  window.__phoneUpload = { addPage, sendFile, startScan: () => { scan = { id: uuid(), pages: 0 }; store.set(scanKey, scan); showScan() }, uuid }
}

// --- page look ---------------------------------------------------------------

async function enhance(file, look, maxEdge = 1920) {
  const bitmap = await createImageBitmap(file)
  const scale = Math.min(1, maxEdge / Math.max(bitmap.width, bitmap.height))
  const w = Math.round(bitmap.width * scale)
  const h = Math.round(bitmap.height * scale)
  const canvas = document.createElement("canvas")
  canvas.width = w
  canvas.height = h
  const ctx = canvas.getContext("2d", { willReadFrequently: true })
  ctx.drawImage(bitmap, 0, 0, w, h)
  bitmap.close()
  if (look === "clean") cleanColour(ctx, w, h)
  if (look === "bw") blackWhite(ctx, w, h)
  const quality = look === "bw" ? 0.75 : look === "clean" ? 0.8 : 0.85
  return await new Promise(r => canvas.toBlob(r, "image/jpeg", quality))
}

const luma = (d, i) => (d[i] * 77 + d[i + 1] * 150 + d[i + 2] * 29) >> 8

// Levels stretch from the 2nd to the 98th luminance percentile: grey paper
// turns white, ink turns dark, colours (stamps, signatures) keep their hue.
function cleanColour(ctx, w, h) {
  const img = ctx.getImageData(0, 0, w, h)
  const d = img.data
  const hist = new Uint32Array(256)
  for (let i = 0; i < d.length; i += 4) hist[luma(d, i)]++
  const total = w * h
  const pct = p => {
    let acc = 0
    for (let v = 0; v < 256; v++) { acc += hist[v]; if (acc >= total * p) return v }
    return 255
  }
  const lo = pct(0.02)
  const hi = Math.max(pct(0.98), lo + 1)
  const lut = new Uint8ClampedArray(256)
  for (let v = 0; v < 256; v++) lut[v] = ((v - lo) * 255) / (hi - lo)
  for (let i = 0; i < d.length; i += 4) {
    d[i] = lut[d[i]]
    d[i + 1] = lut[d[i + 1]]
    d[i + 2] = lut[d[i + 2]]
  }
  ctx.putImageData(img, 0, 0)
}

// Local adaptive threshold (mean of a 31px window minus 10), via an integral
// image, so a shadow across the page does not swallow the text under it.
function blackWhite(ctx, w, h) {
  const img = ctx.getImageData(0, 0, w, h)
  const d = img.data
  const gray = new Uint8Array(w * h)
  for (let p = 0, i = 0; p < w * h; p++, i += 4) gray[p] = luma(d, i)
  const W = w + 1
  const integral = new Uint32Array(W * (h + 1))
  for (let y = 1; y <= h; y++) {
    let row = 0
    for (let x = 1; x <= w; x++) {
      row += gray[(y - 1) * w + (x - 1)]
      integral[y * W + x] = integral[(y - 1) * W + x] + row
    }
  }
  const r = 15
  const C = 10
  for (let y = 0; y < h; y++) {
    const y0 = Math.max(0, y - r)
    const y1 = Math.min(h, y + r + 1)
    for (let x = 0; x < w; x++) {
      const x0 = Math.max(0, x - r)
      const x1 = Math.min(w, x + r + 1)
      const sum = integral[y1 * W + x1] - integral[y0 * W + x1] - integral[y1 * W + x0] + integral[y0 * W + x0]
      const mean = sum / ((x1 - x0) * (y1 - y0))
      const v = gray[y * w + x] < mean - C ? 0 : 255
      const i = (y * w + x) * 4
      d[i] = d[i + 1] = d[i + 2] = v
    }
  }
  ctx.putImageData(img, 0, 0)
}
