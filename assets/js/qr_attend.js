import { BarcodeDetector as ZXingBarcodeDetector } from "../vendor/barcode-detector/pure.js"

let phx_liveview
let camera
let long = 182
let lat = 182
let scanning = false
let facingMode = 'environment'
let hasAutofocus = false // true only if camera supports continuous autofocus

const dom = {
  clock: document.getElementById("clock"),
  video: document.getElementById("camera-video"),
  decodedText: document.getElementById("decodedText"),
  msg: document.getElementById("msg"),
  scannedResult: document.getElementById("scanned-result"),
  goodSound: document.getElementById('good-sound'),
  badSound: document.getElementById('bad-sound'),
  inOut: document.getElementById("in_out"),
  inBtn: document.getElementById("inBtn"),
  outBtn: document.getElementById("outBtn"),
  spinner: document.getElementById("spinner"),
  backBtn: document.getElementById("backBtn"),
  cameraView: document.getElementById("camera-view"),
  flipCameraBtn: document.getElementById("flipCameraBtn")
}

export async function initPunchCamera(lv) {
  phx_liveview = lv

  setInterval(() => showClock(), 1000)
  setStatusBgColor('bg-orange-200', 'bg-green-400')

  phx_liveview.handleEvent('returnScanResult', (data) => scanResult(data))
  phx_liveview.handleEvent('punchResult', (data) => punchResult(data))

  dom.inBtn.addEventListener('click', () =>
    phx_liveview.pushEvent('punch_in', { employee_id: dom.decodedText.innerHTML, gps_long: long, gps_lat: lat })
  )
  dom.outBtn.addEventListener('click', () =>
    phx_liveview.pushEvent('punch_out', { employee_id: dom.decodedText.innerHTML, gps_long: long, gps_lat: lat })
  )
  dom.flipCameraBtn.addEventListener('click', () => flipCamera())

  dom.badSound.play()
  dom.goodSound.play()

  watchGPS()
  await initCamera()
}

function watchGPS() {
  if (!navigator.geolocation) return
  navigator.geolocation.watchPosition(
    (pos) => { long = pos.coords.longitude; lat = pos.coords.latitude },
    () => { long = 182; lat = 182 },
    { maximumAge: 60000, enableHighAccuracy: true }
  )
}

async function rescan() {
  dom.cameraView.style.display = ''
  dom.scannedResult.style.display = 'none'
  dom.inOut.style.display = 'none'
  dom.backBtn.style.display = ''
  dom.spinner.style.display = 'none'
  setStatusBgColor('bg-orange-200', 'bg-green-400')
  scanning = false
  camera.resume()
}

async function showClock() {
  const x = new Date()
  const date = x.getFullYear() + "-" + addZero(x.getMonth() + 1) + "-" + addZero(x.getDate())
  const time = addZero(x.getHours()) + ":" + addZero(x.getMinutes()) + ":" + addZero(x.getSeconds())
  clock.innerHTML = `${date} ${time}`
}

function addZero(i) { return i < 10 ? "0" + i : i }

async function flipCamera() {
  facingMode = facingMode === 'environment' ? 'user' : 'environment'
  camera.destroy()
  await initCamera()
}

// --- Camera init ---

async function initCamera() {
  scanning = false
  hasAutofocus = false

  // Try requested facingMode; fall back to any camera (e.g. laptop with no back camera)
  let stream
  try {
    stream = await navigator.mediaDevices.getUserMedia({
      video: { facingMode, width: { ideal: 640 }, height: { ideal: 640 } }
    })
  } catch {
    stream = await navigator.mediaDevices.getUserMedia({
      video: { width: { ideal: 640 }, height: { ideal: 640 } }
    })
  }

  dom.video.srcObject = stream
  await dom.video.play()

  await applyAutofocus(stream)

  // Fixed-focus cameras (front / webcam): upgrade resolution so QR codes
  // cover more pixels and the detector has enough data to work with
  if (!hasAutofocus) {
    try {
      await stream.getVideoTracks()[0].applyConstraints({
        width: { ideal: 9999 }, height: { ideal: 9999 }
      })
      await new Promise(resolve => setTimeout(resolve, 300))
    } catch { /* ignore if not supported */ }
  }

  initScanner(stream)
}

async function applyAutofocus(stream) {
  try {
    const track = stream.getVideoTracks()[0]
    const capabilities = track.getCapabilities()
    if (!capabilities.focusMode) return

    if (capabilities.focusMode.includes('continuous')) {
      // Best case: camera continuously refocuses on its own
      await track.applyConstraints({ advanced: [{ focusMode: 'continuous' }] })
      hasAutofocus = true

    } else if (capabilities.focusMode.includes('manual') && capabilities.focusDistance) {
      // Manual focus supported: set to minimum distance (closest focal point)
      // so QR codes held near the camera are as sharp as possible
      await track.applyConstraints({
        advanced: [{ focusMode: 'manual', focusDistance: capabilities.focusDistance.min }]
      })

    } else if (capabilities.focusMode.includes('single-shot')) {
      // Trigger a refocus every 2 seconds
      await track.applyConstraints({ advanced: [{ focusMode: 'single-shot' }] })
      setInterval(async () => {
        try { await track.applyConstraints({ advanced: [{ focusMode: 'single-shot' }] }) }
        catch { }
      }, 2000)
    }
  } catch { /* focus not supported on this device */ }
}

// --- Frame processing ---

// Offscreen canvas for scan-region crop, de-mirroring, and contrast boost
const decodeCanvas = document.createElement('canvas')
const decodeCtx = decodeCanvas.getContext('2d')

// Returns the center square crop region in video pixel coordinates.
// Matches the 66% CSS overlay shown to the user (close enough for a guide).
function getScanRegion() {
  const vw = dom.video.videoWidth
  const vh = dom.video.videoHeight
  const size = Math.round(Math.min(vw, vh) * 0.7)
  return { x: Math.round((vw - size) / 2), y: Math.round((vh - size) / 2), size }
}

function prepareDecodeCanvas() {
  const { x, y, size } = getScanRegion()
  const needsFlip = facingMode === 'user'
  const needsProcessing = !hasAutofocus

  // Decode canvas is exactly the scan region — the barcode fills more pixels
  // which directly improves detection accuracy, especially on low-res cameras.
  decodeCanvas.width = size
  decodeCanvas.height = size
  decodeCtx.save()
  // contrast(4) grayscale(1): sharpens blurry edges on fixed-focus cameras
  if (needsProcessing) decodeCtx.filter = 'contrast(4) grayscale(1)'
  if (needsFlip) {
    // Flip horizontally so QR code text orientation is correct for decoder
    decodeCtx.translate(size, 0)
    decodeCtx.scale(-1, 1)
  }
  // Crop to scan region only
  decodeCtx.drawImage(dom.video, x, y, size, size, 0, 0, size, size)
  decodeCtx.restore()
  decodeCtx.filter = 'none'
}

function getDecodeSource() {
  // Always decode from the cropped scan region canvas.
  // Smaller image = faster WASM decode; barcode fills more pixels = better accuracy.
  prepareDecodeCanvas()
  return decodeCanvas
}

// --- Scanner init (ZXing-WASM always, native BarcodeDetector on supporting browsers) ---

// How often to attempt a decode. Native BarcodeDetector is fast (hardware),
// so 20fps is fine. ZXing-WASM takes 20-80ms per call, so 10fps avoids
// queueing calls faster than they complete and keeps the UI smooth.
const NATIVE_SCAN_INTERVAL_MS = 50  // ~20fps
const WASM_SCAN_INTERVAL_MS = 100   // ~10fps

function startScanLoop(detector, intervalMs) {
  let lastScan = 0
  let detecting = false

  async function tick(now) {
    if (!scanning && !detecting && now - lastScan >= intervalMs &&
        dom.video.readyState === dom.video.HAVE_ENOUGH_DATA) {
      detecting = true
      lastScan = now
      try {
        const barcodes = await detector.detect(getDecodeSource())
        if (barcodes.length > 0) onScanSuccess(barcodes[0].rawValue)
      } catch { }
      detecting = false
    }
    requestAnimationFrame(tick)
  }

  requestAnimationFrame(tick)
}

function initScanner(stream) {
  // Use native BarcodeDetector if available (Chrome Android, fast hardware path)
  // otherwise fall back to ZXing-WASM which works on all browsers and handles
  // low-resolution / fixed-focus cameras much better than jsQR
  const useNative = 'BarcodeDetector' in window
  const DetectorClass = useNative ? window.BarcodeDetector : ZXingBarcodeDetector
  const intervalMs = useNative ? NATIVE_SCAN_INTERVAL_MS : WASM_SCAN_INTERVAL_MS

  camera = {
    resume: () => { scanning = false },
    pause: () => { scanning = true },
    destroy: () => { stream.getTracks().forEach(t => t.stop()); dom.video.srcObject = null }
  }

  // Get supported formats asynchronously then start the loop
  DetectorClass.getSupportedFormats().then(formats => {
    startScanLoop(new DetectorClass({ formats }), intervalMs)
  }).catch(() => {
    // Last-resort: ZXing-WASM with common formats hardcoded
    const detector = new ZXingBarcodeDetector({
      formats: ['qr_code', 'code_128', 'code_39', 'ean_13', 'ean_8', 'upc_a', 'upc_e', 'data_matrix', 'pdf417', 'aztec']
    })
    startScanLoop(detector, WASM_SCAN_INTERVAL_MS)
  })
}

// --- Scan result handling ---

function onScanSuccess(decodedText) {
  if (scanning) return
  scanning = true
  camera.pause()
  phx_liveview.pushEvent("qr-code-scanned", { decodedText, gps_long: long, gps_lat: lat })
}

function scanResult(data) {
  switch (data.status) {
    case 'error':
      showResult(data)
      dom.inOut.style.display = 'none'
      setStatusBgColor('bg-rose-200', 'bg-rose-400')
      dom.badSound.play()
      dom.backBtn.style.display = "none"
      dom.spinner.style.display = ''
      setTimeout(() => rescan(), 3000)
      break
    case 'success':
      setStatusBgColor('bg-green-200', 'bg-green-400')
      showResult(data)
      dom.backBtn.style.display = "none"
      dom.spinner.style.display = 'none'
      dom.goodSound.play()
      dom.inOut.style.display = ''
      break
  }
}

function punchResult(data) {
  switch (data.status) {
    case 'error':
      showResult(data)
      dom.inOut.style.display = 'none'
      setStatusBgColor('bg-rose-200', 'bg-rose-400')
      dom.backBtn.style.display = "none"
      dom.spinner.style.display = ''
      dom.badSound.play()
      setTimeout(() => rescan(), 3000)
      break
    case 'success':
      setStatusBgColor('bg-green-200', 'bg-green-400')
      showResult(data)
      dom.backBtn.style.display = "none"
      dom.spinner.style.display = ''
      dom.goodSound.play()
      dom.inOut.style.display = ''
      setTimeout(() => rescan(), 2000)
      break
  }
}

function showResult(data) {
  dom.cameraView.style.display = 'none'
  dom.scannedResult.style.display = ''
  dom.msg.innerHTML = data.msg
  dom.decodedText.innerHTML = data.decodedText
}

export function destroyScanner() { camera.destroy() }

function setStatusBgColor(BgColor, ResColor) {
  var r = /bg\-[a-z]+\-[0-9]+/
  document.body.classList.forEach(c => { if (r.test(c)) document.body.classList.remove(c) })
  document.body.classList.add(BgColor)
  dom.scannedResult.classList.forEach(c => { if (r.test(c)) dom.scannedResult.classList.remove(c) })
  dom.scannedResult.classList.add(ResColor)
}
