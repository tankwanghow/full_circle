import * as H from "../vendor/human-main/dist/human.esm.js" // equivalent of @vladmandic/Human
import * as indexDb from "./indexdb" // methods to deal with indexdb

const humanConfig = {
  // user configuration for human, used to fine-tune behavior
  backend: navigator.gpu ? 'webgpu' : 'webgl',
  cacheSensitivity: 0.1,
  modelBasePath: "/human-models",
  filter: { enabled: false, equalization: true }, // lets run with histogram equilizer
  debug: false,
  face: {
    enabled: true,
    mesh: { enabled: false },
    detector: { maxDetected: 1, rotation: false, return: true, mask: false }, // return tensor is used to get detected face image
    description: { enabled: true, modelPath: 'faceres-deep.json', },
    mobilefacenet: { enabled: true, modelPath: 'mobilefacenet.json' }, // alternative model
    insightface: { enabled: true, modelPath: 'insightface-mobilenet-swish.json' }, // alternative model
    iris: { enabled: false }, // needed to determine gaze direction
    emotion: { enabled: false }, // not needed
    antispoof: { enabled: true }, // enable optional antispoof module
    liveness: { enabled: true } // enable optional liveness module
  },
  body: { enabled: false },
  hand: { enabled: false },
  object: { enabled: false },
  gesture: { enabled: false } // parses face and iris gestures
}

// const matchOptions = { order: 2, multiplier: 1000, min: 0.0, max: 1.0 }; // for embedding model
const matchOptions = { order: 2, multiplier: 20, min: 0.3, max: 0.7 }; // for faceres model

const options = {
  minConfidence: 0.6, // overal face confidence for box, face, gender, real, live
  minSize: 224, // min input to face descriptor model before degradation
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
let frameSkip = 0; // Add frame skipping
const MATCH_INTERVAL = 3; // Process matching every 3 frames
let inOutFlag = ''
const matches = { list: [], times: 3 }
const timestamp = { detect: 0, draw: 0 } // holds information used to calculate performance and possible memory leaks

const dom = {
  // grab instances of dom objects so we dont have to look them up later
  clock: document.getElementById("clock"),
  video: document.getElementById("video"),
  canvas: document.getElementById("canvas"),
  log: document.getElementById("log"),
  videoSelect: document.getElementById("videoSelect"),
  zoom: document.getElementById("zoom"),
  inBtn: document.getElementById("inBtn"),
  outBtn: document.getElementById("outBtn"),
  scanFace: document.getElementById("scanFace"),
  statusBar: document.getElementById("statusBar"),
  in_out: document.getElementById("in_out"),
  scanResultPhotos: document.getElementById("scanResultPhotos")
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
      width: { ideal: 640 },
      height: { ideal: 640 }
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
  if (dom.video.paused) return;
  
  const now = performance.now();
  detectFPS = Math.round(10000 / (now - timestamp.detect)) / 10;
  timestamp.detect = now;

  // Skip frames to improve performance
  frameSkip = (frameSkip + 1) % MATCH_INTERVAL;
  
  if (current.face?.tensor) human.tf.dispose(current.face.tensor);
  const result = await human.detect(dom.video, { skipFrames: MATCH_INTERVAL - 1 });
  current.face = result.face[0];

  // Only process matching on every MATCH_INTERVAL frames
  if (frameSkip === 0 && current.face?.embedding) {
    await detectFace();
  }

  const interpolated = human.next(result);
  const ctx = dom.canvas.getContext('2d', { willReadFrequently: true });
  human.draw.canvas(dom.video, dom.canvas);
  await human.draw.all(dom.canvas, interpolated);
  
  // Draw FPS
  ctx.font = "bold 20px sans";
  ctx.fillStyle = "#AAFF00";
  ctx.fillText(`FPS: ${detectFPS}`, 10, 20);

  requestAnimationFrame(detectionLoop);
}

async function drawPerformance() {
  if (!dom.video.paused) {
    const ctx = canvas.getContext('2d', { willReadFrequently: true })
    if (!ctx) return
    ctx.font = "bold 20px sans"
    ctx.fillStyle = "#AAFF00"
    ctx.fillText(`detectFPS: ${detectFPS}`, 10, 20)
    requestAnimationFrame(drawPerformance)
  }
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
    if (matched(dom.scanResultPhotos, current.record.employee_id, current.record.image, Math.round(1000 * res.similarity) / 10)) {
      await dom.video.pause()
      dom.statusBar.classList.remove('text-[color:#FFFF00]')
      dom.statusBar.classList.remove('text-[color:#FF0000]')
      dom.statusBar.classList.add('text-[color:#00FF00]')
      dom.statusBar.innerHTML = current.record.name
      dom.in_out.style.display = ''
      setBodyBgColor("bg-green-300")
    }
  }
  return res.similarity > options.threshold
}

function insertMatchedImg(el, photo, similarity, klass) {
  const div = document.createElement('div')
  const img = document.createElement('img')
  const span = document.createElement('span')
  span.innerHTML = `${Math.round(similarity)}%`
  img.setAttribute('src', photo)
  img.setAttribute('class', 'rounded-xl')
  div.setAttribute('class', klass)
  el.appendChild(div)
  div.appendChild(img)
  div.appendChild(span)
}

async function main() {
  // main entry point
  setNoMatch()
  await webCam()
  await detectionLoop() // start detection loop
  await drawPerformance()
}

function setBodyBgColor(color) {
  document.body.classList.forEach(function (c) { if (c != color) { document.body.classList.remove(c) } })
  document.body.classList.add(color)
}

function setNoMatch() {
  dom.scanResultPhotos.style.display = "none"
  setBodyBgColor("bg-red-300")
  dom.in_out.style.display = 'none'
  matches.list = []
  dom.scanResultPhotos.textContent = ''
}

function matched(el, id, image, similarity) {
  if (matches.list.length < matches.times) {
    matches.list.push(id)
    insertMatchedImg(el, image, similarity, "w-1/3 text-xs")
    return false
  }
  if (matches.list.filter((v, i, ar) => ar.indexOf(v) === i).length == 1) {
    return true
  }
  else {
    matches.list = []
    setNoMatch()
    return false
  }
}

export async function initFaceID(lv) {
  phx_liveview = lv
  db = await indexDb.load()
  descriptors = db
    .map(rec => rec.descriptor)
    .filter(desc => desc.length > 0)
  setInterval(async () => { showClock() }, 1000)
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

  log("initializing human...")
  log(
    "face embedding model:",
    humanConfig.face.description.enabled ? "faceres" : "",
    humanConfig.face["mobilefacenet"]?.enabled ? "mobilefacenet" : "",
    humanConfig.face["insightface"]?.enabled ? "insightface" : ""
  )

  await human.load()
  await human.warmup()
  await webCam()

  await getDevices().then(gotDevices)

  dom.inBtn.addEventListener('click', async () => { await inBtnClicked() })
  dom.outBtn.addEventListener('click', async () => { await outBtnClicked() })
  dom.scanFace.addEventListener('click', async () => { await startScanFace() })

  phx_liveview.handleEvent('saveAttendenceResult', async function (result) {
    if (result.status == 'success') {
      dom.statusBar.innerHTML = `Saved (${result.msg}). OK!`
      dom.statusBar.classList.remove('text-[color:#FFFF00]')
      dom.statusBar.classList.remove('text-[color:#FF0000]')
      dom.statusBar.classList.add('text-[color:#00FF00]')
      dom.in_out.style.display = 'none'
      dom.scanResultPhotos.textContent = ''
      playSingleBeep()
    }
    if (result.status != 'success') {
      dom.statusBar.classList.remove('text-[color:#FFFF00]')
      dom.statusBar.classList.remove('text-[color:#00FF00]')
      dom.statusBar.classList.add('text-[color:#FF0000]')
      dom.statusBar.innerHTML = `Error! ${result.msg}`
      playDoubleBeep()
    }
  })

  dom.videoSelect.addEventListener('change', function (ev) {
    webCam();
    ev.preventDefault();
  }, false);

  setBodyBgColor("bg-white")
  dom.log.style = "display: none;"
  dom.scanFace.style.display = ""
  dom.statusBar.style.display = ""
}

async function startScanFace() {
  dom.statusBar.innerHTML = "Scanning...."
  dom.statusBar.classList.add('text-[color:#FFFF00]')
  dom.statusBar.classList.remove('text-[color:#FF0000]')
  dom.statusBar.classList.remove('text-[color:#00FF00]')
  await main()
}

async function inBtnClicked() {
  dom.statusBar.innerHTML = "Saving Attendence (IN)..."
  inOutFlag = "IN"
  phx_liveview.pushEvent("save_attendence", { employee_id: current.record.employee_id, flag: inOutFlag, stamp: new Date })
}

async function outBtnClicked() {
  dom.statusBar.innerHTML = "Saving Attendence (OUT)..."
  inOutFlag = "OUT"
  phx_liveview.pushEvent("save_attendence", { employee_id: current.record.employee_id, flag: inOutFlag, stamp: new Date })
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

const beepContext = new (window.AudioContext || window.webkitAudioContext)();

function playSingleBeep() {
  const oscillator = beepContext.createOscillator();
  oscillator.type = 'sine';
  oscillator.frequency.setValueAtTime(440, beepContext.currentTime); // A4 note

  const gainNode = beepContext.createGain();
  gainNode.gain.setValueAtTime(10, beepContext.currentTime);
  gainNode.gain.linearRampToValueAtTime(10, beepContext.currentTime + 0.01);
  gainNode.gain.linearRampToValueAtTime(0, beepContext.currentTime + 0.1); // Short beep

  oscillator.connect(gainNode);
  gainNode.connect(beepContext.destination);

  oscillator.start(beepContext.currentTime);
  oscillator.stop(beepContext.currentTime + 0.1); // Stop after 0.1 seconds
}

function playDoubleBeep() {
  playSingleBeep();
  setTimeout(playSingleBeep, 200); // 200 milliseconds delay for the second beep
}