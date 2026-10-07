// Crop and straighten a phone photo before it is sent (phone page: Photo and
// each Scan page). Four corner handles start on the photo's corners; drag
// them onto the paper's corners and ✓ Use straightens that quadrilateral into
// a flat rectangle (a perspective warp, no library). Untouched corners send
// the photo as it was. ↺ Retake resolves null so the caller reopens the camera.

const WORK_EDGE = 2400 // longest edge of the working copy the warp reads from
const OUT_EDGE = 1920 // longest edge of a straightened result
const HANDLE = 22 // handle radius, CSS px (a 44 px touch target)

// --- math (pure; checked by a throwaway Node script, see the plan) ---------

// The 3×3 projective transform taking points `from[i]` to `to[i]` (4 each).
export function homography(from, to) {
  const A = []
  const b = []
  for (let i = 0; i < 4; i++) {
    const [x, y] = from[i]
    const [u, v] = to[i]
    A.push([x, y, 1, 0, 0, 0, -u * x, -u * y]); b.push(u)
    A.push([0, 0, 0, x, y, 1, -v * x, -v * y]); b.push(v)
  }
  const h = solve(A, b)
  return [h[0], h[1], h[2], h[3], h[4], h[5], h[6], h[7], 1]
}

export function project(H, x, y) {
  const w = H[6] * x + H[7] * y + H[8]
  return [(H[0] * x + H[1] * y + H[2]) / w, (H[3] * x + H[4] * y + H[5]) / w]
}

// Gaussian elimination with partial pivoting (8×8).
function solve(A, b) {
  const n = b.length
  const M = A.map((row, i) => [...row, b[i]])
  for (let c = 0; c < n; c++) {
    let p = c
    for (let r = c + 1; r < n; r++) if (Math.abs(M[r][c]) > Math.abs(M[p][c])) p = r;
    [M[c], M[p]] = [M[p], M[c]]
    for (let r = c + 1; r < n; r++) {
      const f = M[r][c] / M[c][c]
      for (let k = c; k <= n; k++) M[r][k] -= f * M[c][k]
    }
  }
  const x = new Array(n).fill(0)
  for (let r = n - 1; r >= 0; r--) {
    let s = M[r][n]
    for (let k = r + 1; k < n; k++) s -= M[r][k] * x[k]
    x[r] = s / M[r][r]
  }
  return x
}

const dist = ([ax, ay], [bx, by]) => Math.hypot(ax - bx, ay - by)

// Size of the straightened page: the longer of each pair of opposite edges,
// scaled down so the longest side is at most `maxEdge`.
export function outputSize([tl, tr, br, bl], maxEdge) {
  const w = Math.max(dist(tl, tr), dist(bl, br))
  const h = Math.max(dist(tl, bl), dist(tr, br))
  const s = Math.min(1, maxEdge / Math.max(w, h))
  return [Math.max(1, Math.round(w * s)), Math.max(1, Math.round(h * s))]
}

export function isFullFrame(quad, w, h) {
  const full = [[0, 0], [w, 0], [w, h], [0, h]]
  return quad.every(([x, y], i) => Math.abs(x - full[i][0]) < 1 && Math.abs(y - full[i][1]) < 1)
}

// Fill an outW×outH image by mapping each pixel centre back into `quad`
// (TL, TR, BR, BL in source pixels) and sampling bilinearly.
export function warp(src, quad, outW, outH) {
  const H = homography([[0, 0], [outW, 0], [outW, outH], [0, outH]], quad)
  const { data: s, width: sw, height: sh } = src
  const out = new Uint8ClampedArray(outW * outH * 4)
  for (let y = 0; y < outH; y++) {
    for (let x = 0; x < outW; x++) {
      let [u, v] = project(H, x + 0.5, y + 0.5)
      u = Math.min(sw - 1, Math.max(0, u - 0.5))
      v = Math.min(sh - 1, Math.max(0, v - 0.5))
      const x0 = Math.floor(u), y0 = Math.floor(v)
      const x1 = Math.min(sw - 1, x0 + 1), y1 = Math.min(sh - 1, y0 + 1)
      const fx = u - x0, fy = v - y0
      const o = (y * outW + x) * 4
      const a = (y0 * sw + x0) * 4, b = (y0 * sw + x1) * 4
      const c = (y1 * sw + x0) * 4, d = (y1 * sw + x1) * 4
      for (let k = 0; k < 4; k++) {
        const top = s[a + k] + (s[b + k] - s[a + k]) * fx
        const bot = s[c + k] + (s[d + k] - s[c + k]) * fx
        out[o + k] = top + (bot - top) * fy + 0.5
      }
    }
  }
  return { data: out, width: outW, height: outH }
}

// --- the crop view -----------------------------------------------------------

// Resolves a File (cropped, or the original when nothing was moved or it
// cannot be decoded) or null for ↺ Retake.
export async function cropPhoto(file) {
  let bitmap
  try { bitmap = await createImageBitmap(file) } catch (_e) { return file }

  const scale = Math.min(1, WORK_EDGE / Math.max(bitmap.width, bitmap.height))
  const W = Math.round(bitmap.width * scale)
  const H = Math.round(bitmap.height * scale)
  const src = document.createElement("canvas")
  src.width = W
  src.height = H
  src.getContext("2d").drawImage(bitmap, 0, 0, W, H)
  bitmap.close()

  const full = () => [[0, 0], [W, 0], [W, H], [0, H]]
  let corners = full()

  return new Promise(resolve => {
    const overlay = document.createElement("div")
    overlay.className = "fixed inset-0 z-50 flex flex-col bg-black text-white"
    overlay.setAttribute("role", "dialog")
    overlay.setAttribute("aria-modal", "true")
    overlay.innerHTML = `
      <p class="px-4 pt-3 text-center text-sm text-gray-300">Drag the corners onto the paper's corners</p>
      <div data-c="stage" class="relative min-h-0 flex-1 p-3">
        <canvas data-c="view" class="h-full w-full touch-none"></canvas>
      </div>
      <p data-c="msg" class="hidden px-4 text-center text-sm text-gray-300">Straightening…</p>
      <div class="flex gap-2 p-3">
        <button type="button" data-c="retake" class="flex-1 rounded-lg border border-gray-500 px-3 py-3 text-base">↺ Retake</button>
        <button type="button" data-c="full" class="flex-1 rounded-lg border border-gray-500 px-3 py-3 text-base">⤢ Full photo</button>
        <button type="button" data-c="use" class="flex-1 rounded-lg bg-sky-600 px-3 py-3 text-base font-bold">✓ Use</button>
      </div>`
    const $ = name => overlay.querySelector(`[data-c=${name}]`)
    document.body.appendChild(overlay)
    const scroll = document.documentElement.style.overflow
    document.documentElement.style.overflow = "hidden"

    const view = $("view")
    const ctx = view.getContext("2d")
    let fit = { s: 1, ox: 0, oy: 0 }

    function layout() {
      const dpr = window.devicePixelRatio || 1
      const cw = view.clientWidth
      const ch = view.clientHeight
      view.width = Math.round(cw * dpr)
      view.height = Math.round(ch * dpr)
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0)
      // Keep a handle's width around the photo so corner handles are whole.
      const s = Math.min((cw - 2 * HANDLE) / W, (ch - 2 * HANDLE) / H)
      fit = { s, ox: (cw - W * s) / 2, oy: (ch - H * s) / 2 }
      draw()
    }

    const toView = ([x, y]) => [fit.ox + x * fit.s, fit.oy + y * fit.s]

    function draw() {
      const { s, ox, oy } = fit
      ctx.clearRect(0, 0, view.clientWidth, view.clientHeight)
      ctx.drawImage(src, ox, oy, W * s, H * s)
      const pts = corners.map(toView)
      // Dim everything outside the quadrilateral.
      ctx.beginPath()
      ctx.rect(ox, oy, W * s, H * s)
      ctx.moveTo(...pts[0])
      for (const p of pts.slice(1)) ctx.lineTo(...p)
      ctx.closePath()
      ctx.fillStyle = "rgba(0,0,0,0.55)"
      ctx.fill("evenodd")
      ctx.beginPath()
      ctx.moveTo(...pts[0])
      for (const p of pts.slice(1)) ctx.lineTo(...p)
      ctx.closePath()
      ctx.lineWidth = 2
      ctx.strokeStyle = "#38bdf8"
      ctx.stroke()
      for (const [x, y] of pts) {
        ctx.beginPath()
        ctx.arc(x, y, HANDLE, 0, Math.PI * 2)
        ctx.fillStyle = "rgba(56,189,248,0.25)"
        ctx.fill()
        ctx.lineWidth = 3
        ctx.strokeStyle = "#ffffff"
        ctx.stroke()
      }
    }

    let dragging = -1
    const pointer = e => {
      const r = view.getBoundingClientRect()
      return [e.clientX - r.left, e.clientY - r.top]
    }

    view.addEventListener("pointerdown", e => {
      const [px, py] = pointer(e)
      let best = -1
      let bestD = HANDLE * 2
      corners.forEach((c, i) => {
        const d = dist(toView(c), [px, py])
        if (d < bestD) { best = i; bestD = d }
      })
      if (best < 0) return
      dragging = best
      view.setPointerCapture(e.pointerId)
      e.preventDefault()
    })
    view.addEventListener("pointermove", e => {
      if (dragging < 0) return
      const [px, py] = pointer(e)
      const x = Math.min(W, Math.max(0, (px - fit.ox) / fit.s))
      const y = Math.min(H, Math.max(0, (py - fit.oy) / fit.s))
      corners[dragging] = [x, y]
      draw()
    })
    const release = () => { dragging = -1 }
    view.addEventListener("pointerup", release)
    view.addEventListener("pointercancel", release)

    const onResize = () => layout()
    window.addEventListener("resize", onResize)

    function close(result) {
      window.removeEventListener("resize", onResize)
      document.documentElement.style.overflow = scroll
      overlay.remove()
      resolve(result)
    }

    $("retake").onclick = () => close(null)
    $("full").onclick = () => { corners = full(); draw() }
    $("use").onclick = () => {
      if (isFullFrame(corners, W, H)) return close(file)
      for (const b of overlay.querySelectorAll("button")) b.disabled = true
      $("msg").classList.remove("hidden")
      // Let "Straightening…" paint before the warp blocks the thread.
      setTimeout(() => {
        const [ow, oh] = outputSize(corners, OUT_EDGE)
        const img = warp(src.getContext("2d").getImageData(0, 0, W, H), corners, ow, oh)
        const out = document.createElement("canvas")
        out.width = ow
        out.height = oh
        out.getContext("2d").putImageData(new ImageData(img.data, ow, oh), 0, 0)
        out.toBlob(blob => {
          if (!blob) return close(file)
          const base = (file.name || "photo").replace(/\.[^.]+$/, "") || "photo"
          close(new File([blob], `${base}.jpg`, { type: "image/jpeg" }))
        }, "image/jpeg", 0.9)
      }, 30)
    }

    requestAnimationFrame(layout)
  })
}
