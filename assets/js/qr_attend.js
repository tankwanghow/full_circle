import { Html5QrcodeScanner } from "../vendor/html5-qrcode/src/html5-qrcode-scanner"

let phx_liveview
let camera
let long
let lat

const dom = {
  clock: document.getElementById("clock"),
  camera: document.getElementById("camera"),
  decodedText: document.getElementById("decodedText"),
  msg: document.getElementById("msg"),
  scannedResult: document.getElementById("scanned-result"),
  goodSound: document.getElementById('good-sound'),
  badSound: document.getElementById('bad-sound'),
  inOut: document.getElementById("in_out"),
  inBtn: document.getElementById("inBtn"),
  outBtn: document.getElementById("outBtn"),
  spinner: document.getElementById("spinner"),
  backBtn: document.getElementById("backBtn")
}

export async function initPunchCamera(lv) {
  phx_liveview = lv

  setInterval(async () => { showClock() }, 1000)

  setStatusBgColor('bg-orange-200', 'bg-green-400')

  phx_liveview.handleEvent('returnScanResult', (data) => scanResult(data))
  phx_liveview.handleEvent('punchResult', (data) => punchResult(data))

  dom.inBtn.addEventListener('click', async () => {
    phx_liveview.pushEvent('punch_in', {employee_id: dom.decodedText.innerHTML, gps_long: long, gps_lat: lat})
  })

  dom.outBtn.addEventListener('click', async () => {
    phx_liveview.pushEvent('punch_out', {employee_id: dom.decodedText.innerHTML, gps_long: long, gps_lat: lat})
  })

  dom.badSound.play()
  dom.goodSound.play()

  await initCamera()
}

async function rescan() {
  dom.camera.style.display = ''
  dom.scannedResult.style.display = 'none'
  dom.inOut.style.display = 'none'
  dom.backBtn.style.display = ''
  dom.spinner.style.display = 'none'
  setStatusBgColor('bg-orange-200', 'bg-green-400')
  camera.resume()
}

async function showClock() {
  var x = new Date()
  var hours = addZero(x.getHours())
  var date = x.getFullYear() + "-" + addZero((x.getMonth() + 1)) + "-" + addZero(x.getDate())
  var time = hours + ":" + addZero(x.getMinutes()) + ":" + addZero(x.getSeconds())

  clock.innerHTML = `${date} ${time}`
}

function addZero(i) {
  if (i < 10) { i = "0" + i }  // add zero in front of numbers < 10
  return i
}


async function initCamera() {
  camera = new Html5QrcodeScanner(
    'camera',
    { fps: 30, aspectRatio: 1 },
    false
  )

  if (navigator.geolocation) {
    navigator.geolocation.watchPosition(
      (pos) => {
        long = pos.coords.longitude
        lat = pos.coords.latitude
      },
      () => {
        long = 182
        lat = 182
      },
      { maximumAge: 60000, enableHighAccuracy: true })
  } else {
    long = 182
    lat = 182
  }

  function onScanSuccess(decodedText, decodedResult) {
    decodedResult.gps_long = long
    decodedResult.gps_lat = lat
    camera.pause()
    phx_liveview.pushEvent("qr-code-scanned", decodedResult)
  }

  camera.render(onScanSuccess)
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
      setTimeout(async () => { await rescan() }, 3000)
      break;
    case 'success':
      setStatusBgColor('bg-green-200', 'bg-green-400')
      showResult(data)
      dom.backBtn.style.display = "none"
      dom.spinner.style.display = 'none'
      dom.goodSound.play()
      dom.inOut.style.display = ''
      break;
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
      setTimeout(async () => { await rescan() }, 3000)
      break;
    case 'success':
      setStatusBgColor('bg-green-200', 'bg-green-400')
      showResult(data)
      dom.backBtn.style.display = "none"
      dom.spinner.style.display = ''
      dom.goodSound.play()
      dom.inOut.style.display = ''
      setTimeout(async () => { await rescan() }, 2000)
      break;
  }
}

function showResult(data) {
  dom.camera.style.display = 'none'
  dom.scannedResult.style.display = ''
  dom.msg.innerHTML = data.msg
  dom.decodedText.innerHTML = data.decodedText
}

export function destroyScanner(camera) { camera.clear() }

function setStatusBgColor(BgColor, ResColor) {
  var r = /bg\-[a-z]+\-[0-9]+/
  document.body.classList.forEach(function (c) { if (r.test(c)) { document.body.classList.remove(c) } })
  document.body.classList.add(BgColor)
  dom.scannedResult.classList.forEach(function (c) { if (r.test(c)) { dom.scannedResult.classList.remove(c) } })
  dom.scannedResult.classList.add(ResColor)
}