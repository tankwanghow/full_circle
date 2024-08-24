import * as H from "../vendor/human-main/dist/human.esm" // equivalent of @vladmandic/Human
import * as indexDb from "./indexdb" // methods to deal with indexdb

const humanConfig = {
  // user configuration for human, used to fine-tune behavior
  backend: 'webgpu',
  cacheSensitivity: 0,
  modelBasePath: "/human-models",
  filter: { enabled: true, equalization: true }, // lets run with histogram equilizer
  debug: false,
  face: {
    enabled: true,
    mesh: { enabled: true },
    detector: { maxDetected: 1, rotation: true, return: true, mask: false }, // return tensor is used to get detected face image
    description: { enabled: true }, // default model for face descriptor extraction is faceres
    // mobilefacenet: { enabled: true, modelPath: 'https://vladmandic.github.io/human-models/models/mobilefacenet.json' }, // alternative model
    // insightface: { enabled: true, modelPath: 'https://vladmandic.github.io/insightface/models/insightface-mobilenet-swish.json' }, // alternative model
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

// const matchOptions = { order: 2, multiplier: 1000, min: 0.0, max: 1.0 }; // for embedding model
const matchOptions = { order: 2, multiplier: 25, min: 0.2, max: 0.8 }; // for faceres model

const options = {
  minConfidence: 0.5, // overal face confidence for box, face, gender, real, live
  minSize: 150, // min input to face descriptor model before degradation
  blinkMin: 10, // minimum duration of a valid blink
  blinkMax: 800, // maximum duration of a valid blink
  threshold: 0.7, // minimum similarity
  mask: humanConfig.face.detector.mask,
  rotation: humanConfig.face.detector.rotation,
  ...matchOptions
}

const current = { face: null, record: null } // current face record and matched database record

// let db: Array<{ name: string, source: string, embedding: number[] }> = []; // holds loaded face descriptor database
const human = new H.Human(humanConfig) // create instance of human with overrides from user configuration

human.env.perfadd = false // is performance data showing instant or total values
human.draw.options.lineHeight = 20
human.draw.options.drawLabels = false
human.draw.options.drawPolygons = false
human.draw.options.drawGaze = false
human.draw.options.drawGestures = false
human.draw.options.drawBoxes = true

let db
let descriptors
let detectFPS = 0
let drawFPS = 0
const matches = { list: [], times: 5 }
const timestamp = { detect: 0, draw: 0 } // holds information used to calculate performance and possible memory leaks

const dom = {
  // grab instances of dom objects so we dont have to look them up later
  video: document.getElementById("video"),
  canvas: document.getElementById("canvas"),
  log: document.getElementById("log"),
  videoSelect: document.getElementById("videoSelect"),
  zoom: document.getElementById("zoom"),
  inBtn: document.getElementById("inBtn"),
  outBtn: document.getElementById("outBtn"),
  scanResultName: document.getElementById("scanResultName"),
  scanResultPhotos: document.getElementById("scanResultPhotos"),
}

const log = (...msg) => {
  // helper method to output messages
  dom.log.innerText += msg.join(" ") + "\n"
  console.log(...msg) // eslint-disable-line no-console
}

async function webCam() {
  // initialize webcam
  // @ts-ignore resizeMode is not yet defined in tslib
  const videoSource = dom.videoSelect.value
  const cameraOptions = {
    audio: false,
    video: {
      deviceId: videoSource ? { exact: videoSource } : undefined,
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
}

async function detectionLoop() {
  // main detection loop
  if (!dom.video.paused) {
    if (current.face?.tensor) human.tf.dispose(current.face.tensor) // dispose previous tensor
    await human.detect(dom.video) // actual detection; were not capturing output in a local variable as it can also be reached via human.result
    const now = human.now()
    detectFPS = Math.round(10000 / (now - timestamp.detect)) / 10
    timestamp.detect = now
    requestAnimationFrame(detectionLoop) // start new frame immediately
  }

  const interpolated = human.next(human.result) // smoothen result using last-known results
  human.draw.canvas(dom.video, dom.canvas) // draw canvas to screen
  await human.draw.all(dom.canvas, interpolated) // draw labels, boxes, lines, etc.

  current.face = human.result.face[0]
  await detectFace()
}

async function drawPerformance() {
  const now = human.now()
  drawFPS = Math.round(10000 / (now - timestamp.draw)) / 10
  timestamp.draw = now

  const ctx = canvas.getContext('2d', { willReadFrequently: true })
  if (!ctx) return
  ctx.font = "bold 15px sans"
  ctx.fillStyle = "#AAFF00"
  ctx.fillText(`detectFPS: ${detectFPS}`, 5, 20)
  ctx.fillText(`drawFPS: ${drawFPS}`, 5, 40)

  requestAnimationFrame(drawPerformance)
}

async function detectFace() {
  if (!current?.face?.tensor || !current?.face?.embedding) return false
  if ((await indexDb.count()) === 0) {
    return false
  }

  const res = human.match.find(
    current.face.embedding,
    descriptors,
    matchOptions
  )

  current.record = db[res.index] || null

  if (current.record && (res.similarity > options.threshold)) {
    dom.scanResultPhotos.style.display = ""
    if (matched(current.record.employee_id, current.record.image, Math.round(1000 * res.similarity) / 10)) {
      await dom.video.pause()
      dom.scanResultName.innerHTML = current.record.name
      setBodyBgColor("bg-green-300")
      dom.inBtn.classList.remove("invisible")
      dom.outBtn.classList.remove("invisible")
    }
  }
  return res.similarity > options.threshold
}

function insertMatchedImg(photo, similarity) {
  const div = document.createElement('div')
  const img = document.createElement('img')
  const span = document.createElement('span')
  span.innerHTML = `${Math.round(similarity)}%`
  img.setAttribute('src', photo)
  img.setAttribute('class', 'rounded-xl')
  div.setAttribute('class', 'w-1/5')
  dom.scanResultPhotos.appendChild(div)
  div.appendChild(img)
  div.appendChild(span)
}

async function main() {
  // main entry point
  setNoMatch()
  db = await indexDb.load()
  descriptors = db
    .map(rec => rec.descriptor)
    .filter(desc => desc.length > 0)
  await webCam()
  await detectionLoop() // start detection loop
  await drawPerformance()
}

function setBodyBgColor(color) {
  document.body.classList.forEach(function (c) { if (c != color) { document.body.classList.remove(c) } })
  document.body.classList.add(color)
}

function setNoMatch() {
  dom.scanResultName.innerHTML = "No Match !!!"
  dom.scanResultPhotos.style.display = "none"
  setBodyBgColor("bg-red-300")
  dom.inBtn.classList.add("invisible")
  dom.outBtn.classList.add("invisible")
  matches.list = []
  dom.scanResultPhotos.textContent = ''
}

function matched(id, image, similarity) {
  if (matches.list.length < matches.times) {
    matches.list.push(id)
    insertMatchedImg(image, similarity)
    return false
  }
  if (matches.list.filter((v, i, ar) => ar.indexOf(v) === i).length == 1) {
    return true
  }
  else {
    matches.list = []
    return false
  }
}

export async function initFaceID(lv) {
  phx_liveview = lv
  log(
    "human version:",
    human.version,
    "| tfjs version:",
    human.tf.version["tfjs-core"]
  )
  log(
    "options:",
    JSON.stringify(options)
      .replace(/{|}|"|\[|\]/g, "")
      .replace(/,/g, " ")
  )
  log("loading face database...")
  refreshFaceIdDB()
  log("known face records:", await indexDb.count())
  log("initializing webcam...")
  log(human.env)

  await webCam()// start webcam

  await human.load() // preload all models

  log("initializing human...")
  log(
    "face embedding model:",
    humanConfig.face.description.enabled ? "faceres" : "",
    humanConfig.face["mobilefacenet"]?.enabled ? "mobilefacenet" : "",
    humanConfig.face["insightface"]?.enabled ? "insightface" : ""
  )

  await getDevices().then(gotDevices)
  dom.inBtn.addEventListener('click', async () => { await main() })
  dom.outBtn.addEventListener('click', async () => { await main() })

  dom.videoSelect.addEventListener('change', function (ev) {
    webCam();
    ev.preventDefault();
  }, false);
  await human.warmup(); // warmup function to initialize backend for future faster detection
  setBodyBgColor("bg-white")
  dom.log.style = "display: none;"
  await main()
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

let phx_liveview

async function refreshFaceIdDB() {
  log("refreshing FaceID Database....")
  phx_liveview.pushEvent("get_face_id_photos")
  phx_liveview.handleEvent('faceIDPhotos', async function (results) {
    indexDb.clear()
    for (const photo of results['photos']) {
      await indexDb.save(photo)
    }
  })
}