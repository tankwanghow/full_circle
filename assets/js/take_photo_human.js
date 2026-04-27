import * as H from "../vendor/human-main/dist/human.esm.js" // equivalent of @vladmandic/Human

const humanConfig = {
  // user configuration for human, used to fine-tune behavior
  backend: navigator.gpu ? 'webgpu' : 'webgl',
  cacheSensitivity: 0.1,
  modelBasePath: "/human-models/",
  filter: { enabled: false, equalization: true }, // lets run with histogram equilizer
  debug: true,
  face: {
    enabled: true,
    mesh: { enabled: true },
    detector: { maxDetected: 1, rotation: true, return: true, mask: false }, // return tensor is used to get detected face image
    description: { enabled: false },
    insightface: { enabled: true, modelPath: 'insightface-mobilenet-swish.json' },
    mobilefacenet: { enabled: false },
    iris: { enabled: false }, // needed to determine gaze direction
    emotion: { enabled: false }, // not needed
    antispoof: { enabled: false }, // enable optional antispoof module
    liveness: { enabled: false } // enable optional liveness module
  },
  body: { enabled: false },
  hand: { enabled: false },
  object: { enabled: false },
  gesture: { enabled: false } // parses face and iris gestures
}

const options = {
  minConfidence: 0.7, // overal face confidence for box, face, gender, real, live
  minSize: 200, // min input to face descriptor model before degradation (stricter for enrollment quality)
  mask: humanConfig.face.detector.mask,
  rotation: humanConfig.face.detector.rotation
}

const current = { face: null }

const human = new H.Human(humanConfig) // create instance of human with overrides from user configuration

human.env.perfadd = false // is performance data showing instant or total values
human.draw.options.lineHeight = 20
human.draw.options.drawLabels = false
human.draw.options.drawPolygons = false
human.draw.options.drawGaze = false
human.draw.options.drawGestures = false
human.draw.options.drawBoxes = true


// Re-resolved on every initTakePhoto() call — LiveView navigation creates new
// DOM nodes, so module-level references would point to detached elements
// after the first navigation.
let dom = {}
function resolveDom() {
  dom = {
    video: document.getElementById("video"),
    canvas: document.getElementById("canvas"),
    log: document.getElementById("log"),
    fps: document.getElementById("fps"),
    videoSelect: document.getElementById("videoSelect"),
    zoomSelect: document.getElementById("zoomSelect"),
    zoom: document.getElementById("zoom"),
    employee_info: document.getElementById("employee_info"),
    employee_name: document.getElementById("employee_name"),
    employee_id: document.getElementById("employee_id"),
    autoEnrollBtn: document.getElementById("autoEnrollBtn"),
    enrollPrompt: document.getElementById("enrollPrompt"),
    enrollStatus: document.getElementById("enrollStatus"),
    shutterSound: document.getElementById("shutter-sound")
  }
}

function playShutter() {
  try {
    if (!dom.shutterSound) return
    dom.shutterSound.currentTime = 0
    dom.shutterSound.play().catch(() => { })
  } catch { }
}
const timestamp = { detect: 0, draw: 0 } // holds information used to calculate performance and possible memory leaks
let startTime = 0

// Offscreen canvas to normalize camera input to a consistent resolution
const normalizedCanvas = document.createElement('canvas')
normalizedCanvas.width = 640
normalizedCanvas.height = 640
const normalizedCtx = normalizedCanvas.getContext('2d')

const log = (...msg) => {
  // helper method to output messages
  dom.log.innerText += msg.join(" ") + "\n"
  console.log(...msg) // eslint-disable-line no-console
}

let phx_liveview;
// Bumped on every (re)initialization. Running rAF loops compare against this
// and exit when it changes — prevents stale loops from the previous mount
// from competing with the freshly mounted camera.
let runId = 0
let currentStream = null

function stopCurrentStream() {
  try {
    if (currentStream) currentStream.getTracks().forEach(t => t.stop())
  } catch { }
  currentStream = null
}

async function webCam() {
  // initialize webcam
  // @ts-ignore resizeMode is not yet defined in tslib
  const videoSource = dom.videoSelect.value
  const cameraOptions = {
    audio: false,
    video: {
      deviceId: videoSource ? { exact: videoSource } : undefined,
      width: { ideal: 640 },
      height: { ideal: 640 }
    }
  }
  stopCurrentStream()
  const stream = await navigator.mediaDevices.getUserMedia(cameraOptions)
  currentStream = stream
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

async function detectionLoop(myRunId) {
  if (myRunId !== runId) return // stale loop from previous mount
  if (dom.video && !dom.video.paused) {
    normalizedCtx.drawImage(dom.video, 0, 0, 640, 640)
    await human.detect(normalizedCanvas)
    timestamp.detect = human.now()
  }
  requestAnimationFrame(() => detectionLoop(myRunId))
}

async function drawLoop(myRunId) {
  if (myRunId !== runId) return
  if (dom.video && !dom.video.paused) {
    const interpolated = human.next(human.result)
    human.draw.canvas(dom.video, dom.canvas)
    await human.draw.all(dom.canvas, interpolated)
    timestamp.draw = human.now()
  }
  requestAnimationFrame(() => drawLoop(myRunId))
}

async function main() {
  await webCam()
  startTime = human.now()
  const myRunId = runId
  detectionLoop(myRunId)
  drawLoop(myRunId)
}

export function teardownTakePhoto() {
  runId++ // invalidate any rAF loops still in flight
  stopCurrentStream()
  try { window.speechSynthesis.cancel() } catch { }
  autoEnrollRunning = false
}

export async function initTakePhoto(phx_this) {
  // Bump runId first so any leftover loops from the previous mount stop on
  // their next tick before we start new ones.
  runId++
  stopCurrentStream()
  resolveDom()

  phx_liveview = phx_this

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
  dom.autoEnrollBtn.addEventListener("click", autoEnroll)

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

// --- Auto Enroll: capture diverse poses across ~30s ---

const AE = {
  TARGET: 20,             // hard cap on photos
  TIMEOUT_MS: 40000,      // total enrollment duration
  MAX_SIM_VS_LATEST: 0.97, // skip if essentially identical to previous capture
  MIN_FACE_SIZE: 140,     // profile views have narrower boxes — be lenient
  MIN_CONFIDENCE: 0.55,   // profile views score lower than frontal
  PROMPT_MS: 5000,        // total time per prompt (settle + capture window)
  SETTLE_MS: 2500,        // pause capture this long after each new prompt
  // [text shown on screen, text spoken aloud]
  PROMPTS: [
    ["Look STRAIGHT at camera",      "Look straight at the camera"],
    ["Turn head slightly LEFT",      "Turn your head to the left"],
    ["Turn head slightly RIGHT",     "Turn your head to the right"],
    ["Tilt head UP",                 "Tilt your head up"],
    ["Tilt head DOWN",               "Tilt your head down"],
    ["Remove glasses (if wearing)",  "Remove your glasses"],
    ["Slight smile",                 "Give a slight smile"],
    ["Put glasses back on",          "Put your glasses back on"]
  ]
}

function speak(text) {
  try {
    if (!('speechSynthesis' in window)) return
    window.speechSynthesis.cancel() // drop any queued prompt so we don't lag behind
    const u = new SpeechSynthesisUtterance(text)
    u.rate = 1.0
    u.pitch = 1.0
    u.volume = 1.0
    u.lang = 'en-US'
    window.speechSynthesis.speak(u)
  } catch { /* speech not supported */ }
}

let autoEnrollRunning = false

async function autoEnroll() {
  if (autoEnrollRunning) return
  if (!dom.employee_id.value) {
    log("Select an employee first")
    return
  }

  autoEnrollRunning = true
  const captured = [] // { embedding, photo }
  const startedAt = performance.now()

  dom.autoEnrollBtn.style = "display: none;"
  dom.enrollPrompt.style = ""
  dom.enrollStatus.style = ""

  // Make sure camera is running
  if (dom.video.paused) await dom.video.play()

  // Rotate prompts (text + voice). Voice matters because the user is posing,
  // not looking at the screen.
  speak("Auto enrollment starting. Follow the spoken instructions.")
  let promptIdx = 0
  // Block capture for SETTLE_MS after each prompt so the user has time to
  // actually move / put on / remove glasses before we sample frames.
  let settleUntil = performance.now() + AE.SETTLE_MS
  // One photo per prompt — reset on every prompt change so each pose is
  // represented by exactly one capture, guaranteeing variety.
  let capturedThisPrompt = false
  // Track why we rejected frames in the current capture window so we can log
  // a useful reason if the prompt rolls over without a capture.
  let lastRejectReason = "no face seen"
  let rejectCounts = {}
  const showPrompt = () => {
    const [shown, spoken] = AE.PROMPTS[promptIdx]
    dom.enrollPrompt.innerText = shown
    speak(spoken)
    settleUntil = performance.now() + AE.SETTLE_MS
    capturedThisPrompt = false
    lastRejectReason = "no face seen"
    rejectCounts = {}
  }
  showPrompt()
  const promptTimer = setInterval(() => {
    if (!capturedThisPrompt) {
      log(`Auto enroll: missed "${AE.PROMPTS[promptIdx][0]}" — ${lastRejectReason} (rejects: ${JSON.stringify(rejectCounts)})`)
    }
    promptIdx = (promptIdx + 1) % AE.PROMPTS.length
    showPrompt()
  }, AE.PROMPT_MS)

  const updateStatus = () => {
    const now = performance.now()
    const remaining = Math.max(0, Math.ceil((AE.TIMEOUT_MS - (now - startedAt)) / 1000))
    const settling = now < settleUntil
    const phase = settling ? "Hold the pose…" : "Capturing"
    dom.enrollStatus.innerText = `${phase}  ·  Captured ${captured.length}  ·  ${remaining}s left`
  }
  updateStatus()
  const statusTimer = setInterval(updateStatus, 250)

  // Sanity check: skip a candidate if it's essentially identical to the
  // most recent capture (e.g. same exact frame). Different-pose captures
  // from different prompts are guaranteed by the one-per-prompt gate.
  const tooSimilarToLatest = (embedding) => {
    const last = captured[captured.length - 1]
    if (!last) return false
    return human.match.similarity(embedding, last.embedding) >= AE.MAX_SIM_VS_LATEST
  }

  // Snapshot canvas for cropped face capture (separate from main render canvas)
  const snapCanvas = document.createElement('canvas')

  // Consume frames produced by the existing detectionLoop / validationLoop —
  // do not call human.detect() here or the two pipelines will fight.
  let lastSeenFace = null
  while (autoEnrollRunning &&
         captured.length < AE.TARGET &&
         (performance.now() - startedAt) < AE.TIMEOUT_MS) {

    // During the settle window, drain frames without capturing so the user
    // has time to move / change glasses before we sample.
    if (performance.now() < settleUntil) {
      await new Promise(r => requestAnimationFrame(r))
      continue
    }
    // Already grabbed this prompt's photo — wait for the next prompt.
    if (capturedThisPrompt) {
      await new Promise(r => requestAnimationFrame(r))
      continue
    }

    const face = human.result?.face?.[0]
    if (!face || human.result.face.length !== 1) {
      lastRejectReason = "no face / multiple faces"
      rejectCounts.noFace = (rejectCounts.noFace || 0) + 1
    } else if (face !== lastSeenFace && face.embedding) {
      lastSeenFace = face
      const conf = face.faceScore || face.boxScore || 0
      const size = Math.min(face.box[2], face.box[3])

      if (conf < AE.MIN_CONFIDENCE) {
        lastRejectReason = `low confidence ${conf.toFixed(2)} < ${AE.MIN_CONFIDENCE}`
        rejectCounts.lowConf = (rejectCounts.lowConf || 0) + 1
      } else if (size < AE.MIN_FACE_SIZE) {
        lastRejectReason = `face too small ${Math.round(size)}px < ${AE.MIN_FACE_SIZE}`
        rejectCounts.tooSmall = (rejectCounts.tooSmall || 0) + 1
      } else if (tooSimilarToLatest(face.embedding)) {
        lastRejectReason = "too similar to last capture"
        rejectCounts.tooSimilar = (rejectCounts.tooSimilar || 0) + 1
      }

      if (conf >= AE.MIN_CONFIDENCE && size >= AE.MIN_FACE_SIZE && !tooSimilarToLatest(face.embedding)) {
        // Snapshot the cropped face tensor to its own canvas so we don't trample the live preview
        let photoData
        if (face.tensor) {
          snapCanvas.width = face.tensor.shape[1]
          snapCanvas.height = face.tensor.shape[0]
          await human.draw.tensor(face.tensor, snapCanvas)
          photoData = snapCanvas.toDataURL('image/png')
        } else {
          photoData = dom.canvas.toDataURL('image/png')
        }
        captured.push({ embedding: face.embedding, photo: photoData })
        capturedThisPrompt = true
        playShutter()

        const prev = dom.enrollPrompt.innerText
        dom.enrollPrompt.innerText = `✓ Captured ${captured.length}/${AE.TARGET}`
        setTimeout(() => {
          if (dom.enrollPrompt.innerText.startsWith("✓")) dom.enrollPrompt.innerText = prev
        }, 400)
      }
    }

    await new Promise(r => requestAnimationFrame(r))
  }

  clearInterval(promptTimer)
  clearInterval(statusTimer)
  autoEnrollRunning = false

  try { window.speechSynthesis.cancel() } catch { }

  dom.enrollPrompt.style = "display: none;"
  dom.enrollStatus.style = "display: none;"
  dom.autoEnrollBtn.style = ""

  if (captured.length === 0) {
    speak("No usable frames captured. Please try again.")
    log("Auto enroll: no usable frames captured")
    return
  }

  speak(`Done. Captured ${captured.length} photos.`)
  log(`Auto enroll: sending ${captured.length} photos`)
  phx_liveview.pushEvent('save_photos_batch', {
    photos: captured.map(c => ({ discriptor: c.embedding, photo: c.photo }))
  })
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
