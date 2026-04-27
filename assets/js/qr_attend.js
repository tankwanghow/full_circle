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

// Offscreen canvas for de-mirroring and contrast boost on fixed-focus cameras
const decodeCanvas = document.createElement('canvas')
const decodeCtx = decodeCanvas.getContext('2d')

function prepareDecodeCanvas() {
  const needsFlip = facingMode === 'user'
  const needsProcessing = !hasAutofocus

  decodeCanvas.width = dom.video.videoWidth
  decodeCanvas.height = dom.video.videoHeight
  decodeCtx.save()
  // contrast(4) grayscale(1): converts blurry grey QR edges to hard black/white
  if (needsProcessing) decodeCtx.filter = 'contrast(4) grayscale(1)'
  if (needsFlip) {
    decodeCtx.scale(-1, 1)
    decodeCtx.drawImage(dom.video, -decodeCanvas.width, 0)
  } else {
    decodeCtx.drawImage(dom.video, 0, 0)
  }
  decodeCtx.restore()
  decodeCtx.filter = 'none'
}

function getDecodeSource() {
  // Back camera with autofocus: decode directly from video (fastest path)
  if (hasAutofocus && facingMode !== 'user') return dom.video
  prepareDecodeCanvas()
  return decodeCanvas
}

// --- Scanner init (ZXing-WASM always, native BarcodeDetector on supporting browsers) ---

function initScanner(stream) {
  // Use native BarcodeDetector if available (Chrome Android, fast hardware path)
  // otherwise fall back to ZXing-WASM which works on all browsers and handles
  // low-resolution / fixed-focus cameras much better than jsQR
  const DetectorClass = ('BarcodeDetector' in window) ? window.BarcodeDetector : ZXingBarcodeDetector

  // Get supported formats asynchronously then start the loop
  DetectorClass.getSupportedFormats().then(formats => {
    const detector = new DetectorClass({ formats })

    async function tick() {
      if (!scanning && dom.video.readyState === dom.video.HAVE_ENOUGH_DATA) {
        try {
          const barcodes = await detector.detect(getDecodeSource())
          if (barcodes.length > 0) onScanSuccess(barcodes[0].rawValue)
        } catch { }
      }
      requestAnimationFrame(tick)
    }

    camera = {
      resume: () => { scanning = false },
      pause: () => { scanning = true },
      destroy: () => { stream.getTracks().forEach(t => t.stop()); dom.video.srcObject = null }
    }

    requestAnimationFrame(tick)
  }).catch(() => {
    // Last-resort: ZXing-WASM with all common formats
    const detector = new ZXingBarcodeDetector({
      formats: ['qr_code', 'code_128', 'code_39', 'ean_13', 'ean_8', 'upc_a', 'upc_e', 'data_matrix', 'pdf417', 'aztec']
    })

    async function tick() {
      if (!scanning && dom.video.readyState === dom.video.HAVE_ENOUGH_DATA) {
        try {
          const barcodes = await detector.detect(getDecodeSource())
          if (barcodes.length > 0) onScanSuccess(barcodes[0].rawValue)
        } catch { }
      }
      requestAnimationFrame(tick)
    }

    camera = {
      resume: () => { scanning = false },
      pause: () => { scanning = true },
      destroy: () => { stream.getTracks().forEach(t => t.stop()); dom.video.srcObject = null }
    }

    requestAnimationFrame(tick)
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
