import * as H from "../vendor/human-main/dist/human.esm" // equivalent of @vladmandic/Human

const humanConfig = {
  // user configuration for human, used to fine-tune behavior
  backend: 'webgpu',
  cacheSensitivity: 0,
  modelBasePath: "/human-models",
  filter: { enabled: true, equalization: true }, // lets run with histogram equilizer
  debug: true,
  face: {
    enabled: true,
    detector: { rotation: true, return: true, mask: false }, // return tensor is used to get detected face image
    description: { enabled: true }, // default model for face descriptor extraction is faceres
    iris: { enabled: true }, // needed to determine gaze direction
    emotion: { enabled: false }, // not needed
    antispoof: { enabled: true }, // enable optional antispoof module
    liveness: { enabled: true } // enable optional liveness module
  },
  body: { enabled: false },
  hand: { enabled: false },
  object: { enabled: false },
  gesture: { enabled: true } // parses face and iris gestures
}

const options = {
  minConfidence: 0.5, // overal face confidence for box, face, gender, real, live
  minSize: 150, // min input to face descriptor model before degradation
  mask: humanConfig.face.detector.mask,
  rotation: humanConfig.face.detector.rotation
}

const ok = {
  // must meet all rules
  faceCount: { status: false, val: 0 },
  faceConfidence: { status: false, val: 0 },
  facingCenter: { status: false, val: 0 },
  faceSize: { status: false, val: 0 },
  antispoofCheck: { status: false, val: 0 },
  livenessCheck: { status: false, val: 0 },
  age: { status: false, val: 0 },
  gender: { status: false, val: 0 },
  descriptor: { status: false, val: 0 },
  detectFPS: { status: undefined, val: 0 }, // mark detection fps performance
  drawFPS: { status: undefined, val: 0 }, // mark redraw fps performance
  snapClicked: { status: false, val: 0 }
}

const allOk = () =>
  ok.faceCount.status &&
  ok.faceSize.status &&
  ok.facingCenter.status &&
  ok.faceConfidence.status &&
  ok.antispoofCheck.status &&
  ok.livenessCheck.status &&
  ok.descriptor.status &&
  ok.age.status &&
  ok.gender.status &&
  ok.snapClicked.status

const current = { face: null }

const human = new H.Human(humanConfig) // create instance of human with overrides from user configuration

human.env.perfadd = false // is performance data showing instant or total values
human.draw.options.lineHeight = 20
human.draw.options.drawLabels = false
human.draw.options.drawPolygons = false
human.draw.options.drawGaze = false
human.draw.options.drawGestures = false
human.draw.options.drawBoxes = true


const dom = {
  // grab instances of dom objects so we dont have to look them up later
  video: document.getElementById("video"),
  canvas: document.getElementById("canvas"),
  log: document.getElementById("log"),
  fps: document.getElementById("fps"),
  retry: document.getElementById("retry"),
  videoSelect: document.getElementById("videoSelect"),
  zoomSelect: document.getElementById("zoomSelect"),
  zoom: document.getElementById("zoom"),
  snapBtn: document.getElementById("snapBtn"),
  employee_info: document.getElementById("employee_info"),
  employee_name: document.getElementById("employee_name"),
  employee_id: document.getElementById("employee_id"),
  saveBtn: document.getElementById("saveBtn"),
  photos: document.getElementById("photos")
}
const timestamp = { detect: 0, draw: 0 } // holds information used to calculate performance and possible memory leaks
let startTime = 0

const log = (...msg) => {
  // helper method to output messages
  dom.log.innerText += msg.join(" ") + "\n"
  console.log(...msg) // eslint-disable-line no-console
}

let phx_view;

async function webCam() {
  // initialize webcam
  // @ts-ignore resizeMode is not yet defined in tslib
  const videoSource = dom.videoSelect.value
  const cameraOptions = {
    audio: false,
    video: {
      deviceId: videoSource ? { exact: videoSource } : undefined
      ,
      width: { min: 240, ideal: 300 },
      height: { min: 240, ideal: 300 }
    }
  }
  const stream = await navigator.mediaDevices.getUserMedia(cameraOptions)
  const ready = new Promise(resolve => {
    dom.video.onloadeddata = () => resolve(true)
  })
  dom.video.srcObject = stream
  void dom.video.play()
  await ready
  dom.canvas.width = dom.video.videoWidth
  dom.canvas.height = dom.video.videoHeight
  if (human.env.initial)
    log(
      "video:",
      dom.video.videoWidth,
      dom.video.videoHeight,
      "|",
      stream.getVideoTracks()[0].label
    )
  checkCameraCapabilities()
}

async function detectionLoop() {
  // main detection loop
  if (!dom.video.paused) {
    if (current.face?.tensor) human.tf.dispose(current.face.tensor) // dispose previous tensor
    await human.detect(dom.video) // actual detection; were not capturing output in a local variable as it can also be reached via human.result
    const now = human.now()
    ok.detectFPS.val = Math.round(10000 / (now - timestamp.detect)) / 10
    timestamp.detect = now
    requestAnimationFrame(detectionLoop) // start new frame immediately
  }
}

function drawValidationTests() {
  let y = 10
  const ctx = canvas.getContext('2d', { willReadFrequently: true })
  if (!ctx) return
  ctx.font = "bold 8px sans"
  for (const [key, val] of Object.entries(ok)) {
    if (typeof val.status === "boolean")
      ctx.fillStyle = val.status ? "#AAFF00" : "#FF5733"
    const status = val.status ? "ok" : "fail"
    var txt = `${key}: ${val.val === 0 ? status : val.val}`
    y += 10
    ctx.fillText(`${txt}`, 5, y)
  }
  ctx.fillStyle = "#AAFF00"
  ctx.fillText(`Backends: ${human.env.backends}`, 5, y + 10)
  ctx.fillText(`Backend: ${human.config.backend}`, 5, y + 20)
}

async function validationLoop() {
  // main screen refresh loop
  const interpolated = human.next(human.result) // smoothen result using last-known results
  human.draw.canvas(dom.video, dom.canvas) // draw canvas to screen
  await human.draw.all(dom.canvas, interpolated) // draw labels, boxes, lines, etc.
  const now = human.now()
  ok.drawFPS.val = Math.round(10000 / (now - timestamp.draw)) / 10
  timestamp.draw = now
  ok.faceCount.val = human.result.face.length
  ok.faceCount.status = ok.faceCount.val === 1 // must be exactly detected face
  if (ok.faceCount.status) {
    // skip the rest if no face
    const gestures = Object.values(human.result.gesture).map(
      gesture => gesture.gesture
    ) // flatten all gestures
    if (
      gestures.includes("blink left eye") ||
      gestures.includes("blink right eye")
    )
    ok.facingCenter.status = gestures.includes("facing center")
    ok.faceConfidence.val =
      human.result.face[0].faceScore || human.result.face[0].boxScore || 0
    ok.faceConfidence.status = ok.faceConfidence.val >= options.minConfidence
    ok.antispoofCheck.val = human.result.face[0].real || 0
    ok.antispoofCheck.status = ok.antispoofCheck.val >= options.minConfidence
    ok.livenessCheck.val = human.result.face[0].live || 0
    ok.livenessCheck.status = ok.livenessCheck.val >= options.minConfidence
    ok.faceSize.val = Math.min(
      human.result.face[0].box[2],
      human.result.face[0].box[3]
    )
    ok.faceSize.status = ok.faceSize.val >= options.minSize
    ok.descriptor.val = human.result.face[0].embedding?.length || 0
    ok.descriptor.status = ok.descriptor.val > 0
    ok.age.val = human.result.face[0].age || 0
    ok.age.status = ok.age.val > 0
    ok.gender.val = human.result.face[0].genderScore || 0
    ok.gender.status = ok.gender.val >= options.minConfidence
  }
  // run again

  drawValidationTests()
  if (allOk()) {
    // all criteria met
    dom.video.pause()
    return human.result.face[0]
  }

  return new Promise(resolve => {
    setTimeout(async () => {
      await validationLoop() // run validation loop until conditions are met
      resolve(human.result.face[0]) // recursive promise resolve
    }, 100) // use to slow down refresh from max refresh rate to target of 30 fps
  })
}

async function detectFace() {
  dom.canvas.style.height = ""
  dom.canvas.getContext("2d")?.clearRect(0, 0, options.minSize, options.minSize)
  if (!current?.face?.tensor || !current?.face?.embedding) return false
  await human.tf.browser.draw(current.face.tensor, dom.canvas)
  phx_view.pushEvent("got_photo", { discriptor: current.face?.embedding, photo: dom.canvas.toDataURL('image/png') });
}

async function main() {
  // main entry point
  ok.faceCount.status = false
  ok.faceConfidence.status = false
  ok.facingCenter.status = false
  ok.faceSize.status = false
  ok.antispoofCheck.status = false
  ok.livenessCheck.status = false
  ok.age.status = false
  ok.gender.status = false
  ok.snapClicked.status = false

  dom.retry.style = "display: none;"
  buttonsToggle()

  await webCam()
  await detectionLoop() // start detection loop
  startTime = human.now()

  current.face = await validationLoop() // start validation loop

  dom.canvas.width = current.face?.tensor?.shape[1] || options.minSize
  dom.canvas.height = current.face?.tensor?.shape[0] || options.minSize
  dom.canvas.style.width = ""

  dom.retry.style = "display: block;"
  buttonsToggle()

  ok.snapClicked.status = true

  if (!allOk()) {
    // is all criteria met?
    log("did not find valid face")
    return false
  }
  return detectFace()
}

export async function initTakePicture(phx_this) {
  phx_view = phx_this
  phx_view.handleEvent('retry_from_lv', () => main())

  log(
    "human version:",
    human.version,
    "| tfjs version:",
    human.tf.version["tfjs-core"]
  )
  log("initializing webcam...")
  checkBrowserCapabilities()
  await webCam()// start webcam

  await human.load() // preload all models

  log(
    "face embedding model:",
    humanConfig.face.description.enabled ? "faceres" : "",
    humanConfig.face["mobilefacenet"]?.enabled ? "mobilefacenet" : "",
    humanConfig.face["insightface"]?.enabled ? "insightface" : ""
  )
  dom.retry.addEventListener("click", main)
  dom.snapBtn.addEventListener("click", snap)
  dom.saveBtn.addEventListener("click", save)

  await getDevices().then(gotDevices)
  dom.videoSelect.addEventListener('change', function (ev) {
    webCam()
    ev.preventDefault()
  }, false)
  dom.zoomSelect.addEventListener('change', function (ev) {
    zoomChange()
    ev.preventDefault()
  }, false)
  await human.warmup() // warmup function to initialize backend for future faster detection
  dom.log.style = "display: none;"
  await main()
}

function snap() {
  ok.snapClicked.status = true
}

function save() {
  phx_view.pushEvent('save_photo', null)
  main()
}

function zoomChange() {
  const videoTracks = dom.video.srcObject.getVideoTracks()
  var track = videoTracks[0]
  const constraints = { advanced: [{ zoom: dom.zoomSelect.value }] }
  track.applyConstraints(constraints)
}

function getDevices() {
  // AFAICT in Safari this only gets default devices until gUM is called :/
  return navigator.mediaDevices.enumerateDevices()
}

function gotDevices(deviceInfos) {
  for (const deviceInfo of deviceInfos) {
    const option = document.createElement('option');
    option.value = deviceInfo.deviceId;
    if (deviceInfo.kind === 'videoinput') {
      option.text = deviceInfo.label || `Camera ${dom.videoSelect.length + 1}`
      dom.videoSelect.appendChild(option)
    }
  }
}

function checkBrowserCapabilities() {
  if (navigator.mediaDevices.getSupportedConstraints().zoom) {
    dom.zoom.style = "display: block;"
  } else {
    dom.zoom.style = "display: none;"
  }
}

function checkCameraCapabilities() {
  const videoTracks = dom.video.srcObject.getVideoTracks();
  dom.zoomSelect.innerHTML = ''
  if (videoTracks.length > 0) {
    var track = videoTracks[0]
    let capabilities = track.getCapabilities();
    if ('zoom' in capabilities) {
      dom.zoom.classList.remove('invisible');
      let min = capabilities["zoom"]["min"];
      let max = capabilities["zoom"]["max"];

      for (let step = min; step <= max; step++) {
        const option = document.createElement('option')
        option.text = step
        option.value = step
        dom.zoomSelect.appendChild(option)
      }
      dom.zoom.style = "display: block;"
    }
    else {
      dom.zoom.style = "display: none;"
    }
  }
}

function buttonsToggle() {
  if (dom.employee_id.value == '') {
    dom.saveBtn.style = "display: none;"
    dom.snapBtn.style = "display: none;"
  }
  else {
    if (!ok.snapClicked.status) {
      dom.saveBtn.style = "display: none;"
      dom.snapBtn.style = "display: block;"
    }
    else {
      if (current?.face?.tensor || current?.face?.embedding) {
        dom.saveBtn.style = "display: block;"
        dom.snapBtn.style = "display: none;"
      }
      else {
        dom.saveBtn.style = "display: none;"
        dom.snapBtn.style = "display: none;"
      }
    }

  }
}