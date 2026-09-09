package com.fullcircle.qrgate

import android.Manifest
import android.content.Intent
import android.content.SharedPreferences
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.Matrix
import android.graphics.PorterDuff
import android.graphics.Rect
import android.widget.ImageView
import android.widget.TextView
import android.media.AudioManager
import android.media.ToneGenerator
import android.os.Bundle
import android.os.SystemClock
import android.text.InputType
import android.util.Log
import android.view.View
import android.view.ViewGroup
import android.view.WindowManager
import android.widget.EditText
import android.widget.FrameLayout
import androidx.activity.OnBackPressedCallback
import androidx.activity.result.contract.ActivityResultContracts
import androidx.annotation.ColorRes
import androidx.annotation.StringRes
import androidx.appcompat.app.AppCompatActivity
import androidx.camera.core.CameraSelector
import androidx.camera.core.ExperimentalGetImage
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageCapture
import androidx.camera.core.ImageCaptureException
import androidx.camera.core.ImageProxy
import androidx.camera.core.Preview
import androidx.camera.core.UseCaseGroup
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.core.content.ContextCompat
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import androidx.lifecycle.lifecycleScope
import com.fullcircle.qrgate.data.PunchEntity
import com.fullcircle.qrgate.data.QueueDb
import com.fullcircle.qrgate.databinding.ActivityScanBinding
import com.fullcircle.qrgate.net.PunchUploader
import com.fullcircle.qrgate.net.UploadWorker
import okhttp3.OkHttpClient
import okhttp3.Request
import com.google.android.gms.tasks.Tasks
import com.google.mlkit.vision.barcode.BarcodeScanner
import com.google.mlkit.vision.barcode.BarcodeScannerOptions
import com.google.mlkit.vision.barcode.BarcodeScanning
import com.google.mlkit.vision.barcode.common.Barcode
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.face.Face
import com.google.mlkit.vision.face.FaceDetection
import com.google.mlkit.vision.face.FaceDetector
import com.google.mlkit.vision.face.FaceDetectorOptions
import com.google.mlkit.vision.face.FaceLandmark
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import java.io.IOException
import java.time.Instant
import java.time.ZonedDateTime
import java.time.temporal.ChronoUnit
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min

class ScanActivity : AppCompatActivity() {
    private enum class Step { WAIT, CAPTURING, OK }

    sealed class BadgePick {
        data object None : BadgePick()
        data class One(val employeeId: String) : BadgePick()
        data object Ambiguous : BadgePick()
    }

    /** Rect-free so the geometry stays unit-testable off-device. */
    data class Box(val left: Int, val top: Int, val right: Int, val bottom: Int)

    private lateinit var binding: ActivityScanBinding
    private lateinit var prefs: Prefs
    private lateinit var cameraExecutor: ExecutorService
    private lateinit var scanner: BarcodeScanner
    private lateinit var faceDetector: FaceDetector
    private lateinit var photosDir: File

    private var imageCapture: ImageCapture? = null
    private var cameraProvider: ProcessCameraProvider? = null
    private var pendingEmployeeId: String? = null
    private var pendingPunchedAtIso: String? = null
    private val captureGeneration = AtomicInteger(0)
    private var lastRejectBeepAt = 0L
    private var readyAt = 0L
    private val lastOkAtByEmployee = ConcurrentHashMap<String, Long>()
    private val step = AtomicReference(Step.WAIT)
    private val burstIdle = BurstIdle()
    private val sleepTick = Runnable {
        if (step.get() != Step.WAIT) return@Runnable
        applyIdle(burstIdle.idleElapsed())
    }
    private var lastLegend: GateUi.Legend? = null
    private val clockTick = object : Runnable {
        override fun run() {
            if (!::binding.isInitialized || isDestroyed || isFinishing) return
            val at = ZonedDateTime.now()
            binding.gateDate.text = GateUi.formatDate(at)
            binding.gateTime.text = GateUi.formatTime(at)
            binding.root.postDelayed(this, 1_000L)
        }
    }
    private val healthExecutor = Executors.newSingleThreadExecutor()
    private val healthClient: OkHttpClient = OkHttpClient.Builder()
        .connectTimeout(3, TimeUnit.SECONDS)
        .readTimeout(3, TimeUnit.SECONDS)
        .writeTimeout(3, TimeUnit.SECONDS)
        .build()
    private val healthTick = object : Runnable {
        override fun run() {
            if (!::binding.isInitialized || isDestroyed || isFinishing) return
            healthExecutor.execute { pingHealth() }
            binding.root.postDelayed(this, HEALTH_MS)
        }
    }

    private val prefListener =
        SharedPreferences.OnSharedPreferenceChangeListener { _, key ->
            if (key == Prefs.KEY_TOKEN && prefs.token.isEmpty()) {
                runOnUiThread { goPairing() }
            }
        }

    private val requestCamera =
        registerForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
            if (granted) {
                startCamera()
            } else {
                binding.prompt.visibility = View.VISIBLE
                binding.prompt.setText(R.string.camera_required)
            }
        }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(
            WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON or
                WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON,
        )

        prefs = Prefs(this)
        if (prefs.token.isEmpty()) {
            goPairing()
            return
        }

        binding = ActivityScanBinding.inflate(layoutInflater)
        setContentView(binding.root)
        hideSystemBars()

        binding.version.text = BuildConfig.VERSION_NAME
        binding.version.setOnLongClickListener {
            showIdleDialog()
            true
        }
        binding.sleepOverlay.setOnClickListener { applyIdle(burstIdle.tapped()) }
        binding.legend.setOnClickListener { applyIdle(burstIdle.tapped()) }
        binding.clock.setOnClickListener { applyIdle(burstIdle.tapped()) }
        clockTick.run()
        applyLink(LinkStatus.DISCONNECTED)
        healthTick.run()

        photosDir = QueueDb.photosDir(this).also { it.mkdirs() }
        cameraExecutor = Executors.newSingleThreadExecutor()
        scanner = BarcodeScanning.getClient(
            BarcodeScannerOptions.Builder()
                .setBarcodeFormats(Barcode.FORMAT_QR_CODE)
                .build(),
        )
        faceDetector = FaceDetection.getClient(
            FaceDetectorOptions.Builder()
                .setPerformanceMode(FaceDetectorOptions.PERFORMANCE_MODE_FAST)
                .setLandmarkMode(FaceDetectorOptions.LANDMARK_MODE_ALL)
                .setClassificationMode(FaceDetectorOptions.CLASSIFICATION_MODE_NONE)
                .setMinFaceSize(0.10f)
                .build(),
        )

        onBackPressedDispatcher.addCallback(
            this,
            object : OnBackPressedCallback(true) {
                override fun handleOnBackPressed() {
                    // Kiosk: ignore back.
                }
            },
        )

        if (ContextCompat.checkSelfPermission(this, Manifest.permission.CAMERA) ==
            PackageManager.PERMISSION_GRANTED
        ) {
            startCamera()
        } else {
            requestCamera.launch(Manifest.permission.CAMERA)
        }
        applyIdle(burstIdle.started())

        UploadWorker.enqueue(this)
    }

    override fun onStart() {
        super.onStart()
        if (::prefs.isInitialized) {
            prefs.register(prefListener)
            if (prefs.token.isEmpty()) {
                goPairing()
                return
            }
        }
    }

    override fun onStop() {
        if (::prefs.isInitialized) prefs.unregister(prefListener)
        super.onStop()
    }

    override fun onResume() {
        super.onResume()
        if (::binding.isInitialized) hideSystemBars()
        tryLockTask()
    }

    private fun hideSystemBars() {
        WindowCompat.setDecorFitsSystemWindows(window, false)
        WindowInsetsControllerCompat(window, binding.root).let { c ->
            c.hide(WindowInsetsCompat.Type.systemBars())
            c.systemBarsBehavior =
                WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
        }
    }

    private fun tryLockTask() {
        try {
            startLockTask()
        } catch (_: IllegalArgumentException) {
        } catch (_: IllegalStateException) {
        } catch (_: SecurityException) {
        }
    }

    private fun startCamera() {
        if (!::binding.isInitialized) return
        binding.previewView.post { bindCameraUseCases() }
    }

    /**
     * Crop analysis + still to the same pixels as the full-screen preview.
     * Without a ViewPort, FILL_CENTER preview can show a cut-off head while
     * the analyzer still sees the whole sensor and punches.
     */
    private fun bindCameraUseCases() {
        if (isDestroyed || isFinishing) return
        if (burstIdle.mode != BurstIdle.Mode.ACTIVE) return
        if (binding.previewView.width == 0 || binding.previewView.height == 0) {
            binding.previewView.post { bindCameraUseCases() }
            return
        }
        val future = ProcessCameraProvider.getInstance(this)
        future.addListener({
            val provider = future.get()
            cameraProvider = provider
            if (burstIdle.mode != BurstIdle.Mode.ACTIVE) return@addListener
            val preview = Preview.Builder().build().also {
                it.setSurfaceProvider(binding.previewView.surfaceProvider)
            }
            val capture = ImageCapture.Builder()
                .setCaptureMode(ImageCapture.CAPTURE_MODE_MINIMIZE_LATENCY)
                .build()
            imageCapture = capture

            val analysis = ImageAnalysis.Builder()
                .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                .build()
                .also { it.setAnalyzer(cameraExecutor, ::analyzeFrame) }

            provider.unbindAll()
            try {
                val viewPort = binding.previewView.viewPort
                if (viewPort != null) {
                    val group = UseCaseGroup.Builder()
                        .setViewPort(viewPort)
                        .addUseCase(preview)
                        .addUseCase(capture)
                        .addUseCase(analysis)
                        .build()
                    provider.bindToLifecycle(
                        this,
                        CameraSelector.DEFAULT_FRONT_CAMERA,
                        group,
                    )
                } else {
                    provider.bindToLifecycle(
                        this,
                        CameraSelector.DEFAULT_FRONT_CAMERA,
                        preview,
                        capture,
                        analysis,
                    )
                }
            } catch (e: IllegalArgumentException) {
                Log.e(TAG, "front camera required", e)
                binding.prompt.visibility = View.VISIBLE
                binding.prompt.setText(R.string.front_camera_required)
            }
        }, ContextCompat.getMainExecutor(this))
    }

    @OptIn(ExperimentalGetImage::class)
    private fun analyzeFrame(imageProxy: ImageProxy) {
        val media = imageProxy.image
        if (media == null ||
            step.get() != Step.WAIT ||
            burstIdle.mode == BurstIdle.Mode.SLEEP
        ) {
            imageProxy.close()
            return
        }
        val rotation = imageProxy.imageInfo.rotationDegrees
        val (imgW, imgH) = uprightImageSize(imageProxy.width, imageProxy.height, rotation)
        val image = InputImage.fromMediaImage(media, rotation)
        val barcodesTask = scanner.process(image)
        val facesTask = faceDetector.process(image)
        Tasks.whenAllComplete(barcodesTask, facesTask)
            .addOnCompleteListener {
                try {
                    if (step.get() != Step.WAIT) return@addOnCompleteListener
                    if (facesTask.isSuccessful &&
                        facesTask.result.orEmpty().isNotEmpty()
                    ) {
                        runOnUiThread { applyIdle(burstIdle.faceSeen()) }
                    }
                    val pick = if (barcodesTask.isSuccessful) {
                        pickBadgeBarcode(barcodesTask.result.orEmpty())
                    } else {
                        BadgePick.None to null
                    }
                    val mlFace = if (facesTask.isSuccessful) {
                        facesTask.result.orEmpty().maxByOrNull { area(it.boundingBox.toBox()) }
                    } else {
                        null
                    }
                    val faceBox = mlFace?.boundingBox?.toBox()
                    val fullFace = mlFace != null && isCompleteFace(mlFace, imgW, imgH)
                    val badgeBox = pick.second?.boundingBox?.toBox()
                    val occludes = fullFace &&
                        pick.first is BadgePick.One &&
                        faceBox != null &&
                        badgeBox != null &&
                        badgeOccludesFace(faceBox, badgeBox)
                    val ready = fullFace && pick.first is BadgePick.One && !occludes
                    runOnUiThread {
                        applyLegend(
                            GateUi.legend(
                                asleep = burstIdle.mode == BurstIdle.Mode.SLEEP,
                                fullFace = fullFace,
                                pick = pick.first,
                                occludes = occludes,
                            ),
                        )
                    }
                    if (SystemClock.elapsedRealtime() < readyAt) return@addOnCompleteListener
                    if (!ready) return@addOnCompleteListener
                    val empId = (pick.first as BadgePick.One).employeeId
                    if (recentlyAccepted(empId)) {
                        dupRejectBeep()
                        return@addOnCompleteListener
                    }
                    if (step.compareAndSet(Step.WAIT, Step.CAPTURING)) {
                        pendingEmployeeId = empId
                        pendingPunchedAtIso =
                            Instant.now().truncatedTo(ChronoUnit.SECONDS).toString()
                        runOnUiThread {
                            applyIdle(burstIdle.captureStarted())
                            captureStill()
                        }
                    }
                } finally {
                    imageProxy.close()
                }
            }
    }

    private fun captureStill() {
        if (isDestroyed || isFinishing) return
        if (step.get() != Step.CAPTURING) return
        val generation = captureGeneration.get()
        val capture = imageCapture
        if (capture == null) {
            rejectStill()
            return
        }
        capture.takePicture(
            cameraExecutor,
            object : ImageCapture.OnImageCapturedCallback() {
                override fun onCaptureSuccess(image: ImageProxy) {
                    if (generation != captureGeneration.get()) {
                        image.close()
                        return
                    }
                    val bitmap = try {
                        image.toBitmap()
                    } catch (e: Exception) {
                        Log.w(TAG, "toBitmap failed", e)
                        image.close()
                        rejectStill()
                        return
                    }
                    val rotated = rotateIfNeeded(bitmap, image.imageInfo.rotationDegrees)
                    image.close()

                    if (generation != captureGeneration.get()) return

                    val emp = pendingEmployeeId
                    val punchedAt = pendingPunchedAtIso
                    if (emp == null || punchedAt == null) {
                        rejectStill()
                        return
                    }
                    val faceBox = verifyStill(rotated, emp)
                    if (faceBox == null) {
                        Log.i(TAG, "still missing face or badge QR; not queueing")
                        rejectStill()
                        return
                    }
                    val cropped = cropToFace(rotated, faceBox)
                    val clientId = UUID.randomUUID().toString()
                    val dest = File(photosDir, "$clientId.jpg")
                    if (!writeFaceJpeg(cropped, dest)) {
                        dest.delete()
                        rejectStill()
                        return
                    }
                    if (generation != captureGeneration.get()) {
                        dest.delete()
                        return
                    }
                    queuePunch(clientId, emp, punchedAt, dest)
                }

                override fun onError(exception: ImageCaptureException) {
                    Log.w(TAG, "capture failed", exception)
                    if (generation != captureGeneration.get()) return
                    rejectStill()
                }
            },
        )
    }

    /**
     * Detection only — no matching / enrolment. The badge must be in this JPEG, must be the
     * one seen live, and must not cover the face. Returns the face box to crop to, or null.
     */
    private fun verifyStill(bitmap: Bitmap, expectedEmp: String): Box? {
        val image = InputImage.fromBitmap(bitmap, 0)
        val faces = try {
            Tasks.await(faceDetector.process(image), 2, TimeUnit.SECONDS)
        } catch (e: Exception) {
            Log.w(TAG, "face detect failed", e)
            return null
        }
        val barcodes = try {
            Tasks.await(scanner.process(image), 2, TimeUnit.SECONDS)
        } catch (e: Exception) {
            Log.w(TAG, "badge decode on still failed", e)
            return null
        }

        val (pick, badge) = pickBadgeBarcode(barcodes)
        val id = (pick as? BadgePick.One)?.employeeId ?: return null
        if (!id.equals(expectedEmp, ignoreCase = true)) return null
        val badgeBox = badge?.boundingBox?.toBox() ?: return null
        val mlFace = faces.maxByOrNull { area(it.boundingBox.toBox()) } ?: return null
        val faceBox = mlFace.boundingBox.toBox()
        if (!isCompleteFace(mlFace, bitmap.width, bitmap.height)) {
            Log.i(TAG, "face not complete; not queueing")
            return null
        }
        if (badgeOccludesFace(faceBox, badgeBox)) {
            Log.i(TAG, "badge covers face; not queueing")
            return null
        }
        return faceBox
    }

    private fun rejectStill() {
        captureGeneration.incrementAndGet()
        pendingEmployeeId = null
        pendingPunchedAtIso = null
        readyAt = SystemClock.elapsedRealtime() + REJECT_COOLDOWN_MS
        step.set(Step.WAIT)
        val now = SystemClock.elapsedRealtime()
        val shouldBeep = now - lastRejectBeepAt > 1_500L
        if (shouldBeep) lastRejectBeepAt = now
        runOnUiThread {
            if (isDestroyed || isFinishing) return@runOnUiThread
            flash(R.color.flash_fail)
            if (shouldBeep) beep(ToneGenerator.TONE_PROP_NACK, 300)
            showWaitUi()
            applyIdle(burstIdle.backToWait())
        }
    }

    private fun queuePunch(
        clientId: String,
        employeeId: String,
        punchedAtIso: String,
        photo: File,
    ) {
        val row = PunchEntity(
            clientId = clientId,
            employeeId = employeeId,
            punchedAtIso = punchedAtIso,
            photoPath = photo.absolutePath,
        )
        lifecycleScope.launch(Dispatchers.IO) {
            if (recentlyAccepted(employeeId)) {
                photo.delete()
                withContext(Dispatchers.Main) {
                    dupRejectBeep()
                    backToWait()
                }
                return@launch
            }
            val accepted = QueueDb.insertIfPaired(this@ScanActivity, row)
            if (!accepted) {
                photo.delete()
                withContext(Dispatchers.Main) { goPairing() }
                return@launch
            }
            rememberOk(employeeId)
            UploadWorker.enqueue(this@ScanActivity)
            withContext(Dispatchers.Main) { showOk() }
        }
    }

    private fun showOk() {
        captureGeneration.incrementAndGet()
        pendingEmployeeId = null
        pendingPunchedAtIso = null
        step.set(Step.OK)
        flash(R.color.flash_ok)
        beep(ToneGenerator.TONE_PROP_BEEP, 200)
        applyLegend(GateUi.Legend(faceOk = true, qrOk = true, asleep = false))
        binding.root.postDelayed({ backToWait() }, OK_MS)
    }

    private fun backToWait() {
        if (isDestroyed || isFinishing) return
        captureGeneration.incrementAndGet()
        pendingEmployeeId = null
        pendingPunchedAtIso = null
        if (prefs.token.isEmpty()) {
            goPairing()
            return
        }
        readyAt = SystemClock.elapsedRealtime() + QR_COOLDOWN_MS
        showWaitUi()
        step.set(Step.WAIT)
        applyIdle(burstIdle.backToWait())
    }

    /** Full-screen colour cue: green accepted, red rejected. Read from across the gate. */
    private fun flash(@ColorRes colorRes: Int) {
        if (!::binding.isInitialized || isDestroyed || isFinishing) return
        val v = binding.flashOverlay
        v.animate().cancel()
        v.setBackgroundColor(ContextCompat.getColor(this, colorRes))
        v.alpha = FLASH_ALPHA
        v.visibility = View.VISIBLE
        v.animate()
            .alpha(0f)
            .setStartDelay(FLASH_HOLD_MS)
            .setDuration(FLASH_FADE_MS)
            .withEndAction { v.visibility = View.GONE }
    }

    private fun applyLegend(legend: GateUi.Legend) {
        if (!::binding.isInitialized || isDestroyed || isFinishing) return
        if (legend == lastLegend) return
        lastLegend = legend
        tintLegend(binding.faceIcon, binding.faceLabel, legend.faceOk)
        tintLegend(binding.qrIcon, binding.qrLabel, legend.qrOk)
        if (legend.asleep) {
            binding.prompt.visibility = View.VISIBLE
            binding.prompt.setText(R.string.tap_to_scan)
        } else {
            binding.prompt.visibility = View.GONE
        }
    }

    private fun tintLegend(icon: ImageView, label: TextView, ok: Boolean) {
        val color = ContextCompat.getColor(
            this,
            if (ok) R.color.flash_ok else R.color.flash_fail,
        )
        icon.setColorFilter(color, PorterDuff.Mode.SRC_IN)
        label.setTextColor(color)
    }

    private fun showWaitUi() {
        applyLegend(GateUi.Legend(faceOk = false, qrOk = false, asleep = false))
    }

    private fun recentlyAccepted(employeeId: String): Boolean {
        val now = SystemClock.elapsedRealtime()
        lastOkAtByEmployee.entries.removeIf { now - it.value >= DUP_WINDOW_MS }
        val last = lastOkAtByEmployee[employeeId] ?: return false
        return now - last < DUP_WINDOW_MS
    }

    private fun rememberOk(employeeId: String) {
        lastOkAtByEmployee[employeeId] = SystemClock.elapsedRealtime()
    }

    private fun dupRejectBeep() {
        val now = SystemClock.elapsedRealtime()
        if (now - lastRejectBeepAt < 1_500L) return
        lastRejectBeepAt = now
        runOnUiThread {
            flash(R.color.flash_fail)
            beep(ToneGenerator.TONE_SUP_ERROR, 400)
        }
    }

    private fun goPairing() {
        disarmIdleTimer()
        startActivity(Intent(this, PairingActivity::class.java))
        finish()
    }

    private fun beep(tone: Int, durationMs: Int) {
        try {
            val tg = ToneGenerator(AudioManager.STREAM_NOTIFICATION, 80)
            tg.startTone(tone, durationMs)
            if (::binding.isInitialized) {
                binding.root.postDelayed({ tg.release() }, durationMs + 80L)
            } else {
                tg.release()
            }
        } catch (_: Exception) {
        }
    }

    private fun applyIdle(effect: BurstIdle.Effect) {
        when (effect) {
            BurstIdle.Effect.None -> {}
            BurstIdle.Effect.ArmIdle -> armIdleTimer()
            BurstIdle.Effect.DisarmIdle -> disarmIdleTimer()
            BurstIdle.Effect.Sleep -> enterSleep()
            BurstIdle.Effect.Wake -> enterWake()
        }
    }

    private fun armIdleTimer() {
        if (!::binding.isInitialized) return
        binding.root.removeCallbacks(sleepTick)
        binding.root.postDelayed(sleepTick, prefs.idleSeconds * 1000L)
    }

    private fun disarmIdleTimer() {
        if (!::binding.isInitialized) return
        binding.root.removeCallbacks(sleepTick)
    }

    /**
     * Unbind the camera and dim the panel. Keep the window "on" so a tap
     * still wakes us — the mount covers the power button.
     */
    private fun enterSleep() {
        if (isDestroyed || isFinishing) return
        if (step.get() != Step.WAIT) {
            burstIdle.abortSleep()
            return
        }
        disarmIdleTimer()
        cameraProvider?.unbindAll()
        imageCapture = null
        setBrightness(SLEEP_BRIGHTNESS)
        binding.sleepOverlay.visibility = View.VISIBLE
        applyLegend(GateUi.Legend(faceOk = false, qrOk = false, asleep = true))
    }

    private fun enterWake() {
        if (isDestroyed || isFinishing) return
        setBrightness(WindowManager.LayoutParams.BRIGHTNESS_OVERRIDE_NONE)
        binding.sleepOverlay.visibility = View.GONE
        showWaitUi()
        startCamera()
        armIdleTimer()
    }

    private fun setBrightness(value: Float) {
        val lp = window.attributes
        lp.screenBrightness = value
        window.attributes = lp
    }

    private fun showIdleDialog() {
        disarmIdleTimer()
        lifecycleScope.launch {
            val queued = QueueDb.get(this@ScanActivity).punchDao().count()
            withContext(Dispatchers.Main) {
                if (isDestroyed || isFinishing) return@withContext
                val pad = (20 * resources.displayMetrics.density).toInt()
                val input = EditText(this@ScanActivity).apply {
                    inputType = InputType.TYPE_CLASS_NUMBER
                    hint = getString(R.string.idle_range)
                    setText(prefs.idleSeconds.toString())
                    setSelection(text.length)
                }
                val box = FrameLayout(this@ScanActivity).apply {
                    setPadding(pad, pad / 2, pad, 0)
                    addView(
                        input,
                        FrameLayout.LayoutParams(
                            ViewGroup.LayoutParams.MATCH_PARENT,
                            ViewGroup.LayoutParams.WRAP_CONTENT,
                        ),
                    )
                }
                androidx.appcompat.app.AlertDialog.Builder(this@ScanActivity)
                    .setTitle(R.string.idle_title)
                    .setMessage(GateUi.queuedLabel(queued))
                    .setView(box)
                    .setPositiveButton(R.string.idle_save) { _, _ ->
                        prefs.idleSeconds = BurstIdle.parseIdleSeconds(input.text.toString())
                    }
                    .setNegativeButton(android.R.string.cancel, null)
                    .setOnDismissListener {
                        if (burstIdle.mode == BurstIdle.Mode.ACTIVE && step.get() == Step.WAIT) {
                            armIdleTimer()
                        }
                    }
                    .show()
            }
        }
    }

    private fun pingHealth() {
        if (isDestroyed || isFinishing) return
        val token = prefs.token
        val base = prefs.baseUrl.trimEnd('/')
        if (token.isEmpty() || base.isEmpty()) return
        val request = Request.Builder()
            .url("$base/api/punch/health")
            .header("Authorization", "Bearer $token")
            .get()
            .build()
        val status = try {
            healthClient.newCall(request).execute().use { LinkStatus.fromHttp(it.code) }
        } catch (_: IOException) {
            LinkStatus.fromNetworkError()
        }
        val afterDrain =
            if (status == LinkStatus.CONNECTED) {
                when (PunchUploader.drainBlocking(applicationContext)) {
                    PunchUploader.Result.REVOKED -> LinkStatus.REVOKED
                    else -> status
                }
            } else {
                status
            }
        runOnUiThread { applyLink(afterDrain) }
    }

    private fun applyLink(status: LinkStatus) {
        if (!::binding.isInitialized || isDestroyed || isFinishing) return
        when (status) {
            LinkStatus.CONNECTED -> {
                val color = ContextCompat.getColor(this, R.color.flash_ok)
                binding.linkIcon.setColorFilter(color, PorterDuff.Mode.SRC_IN)
                binding.linkIcon.contentDescription = getString(R.string.server_connected)
            }
            LinkStatus.DISCONNECTED -> {
                val color = ContextCompat.getColor(this, R.color.flash_fail)
                binding.linkIcon.setColorFilter(color, PorterDuff.Mode.SRC_IN)
                binding.linkIcon.contentDescription = getString(R.string.server_disconnected)
            }
            LinkStatus.REVOKED -> {
                lifecycleScope.launch {
                    QueueDb.wipeBecauseRevoked(this@ScanActivity)
                    withContext(Dispatchers.Main) { goPairing() }
                }
            }
        }
    }

    override fun onDestroy() {
        captureGeneration.incrementAndGet()
        if (::binding.isInitialized) {
            binding.root.removeCallbacks(sleepTick)
            binding.root.removeCallbacks(clockTick)
            binding.root.removeCallbacks(healthTick)
        }
        super.onDestroy()
        healthExecutor.shutdown()
        if (::cameraExecutor.isInitialized) cameraExecutor.shutdown()
        if (::scanner.isInitialized) scanner.close()
        if (::faceDetector.isInitialized) faceDetector.close()
    }

    companion object {
        private const val TAG = "QrGateScan"
        private const val HEALTH_MS = 20_000L
        private const val OK_MS = 1_500L
        private const val QR_COOLDOWN_MS = 2_000L
        private const val REJECT_COOLDOWN_MS = 750L
        private const val FLASH_ALPHA = 0.75f
        private const val FLASH_HOLD_MS = 250L
        private const val FLASH_FADE_MS = 400L
        private const val DUP_WINDOW_MS = 180_000L
        private const val MAX_PHOTO_BYTES = 300_000L
        private const val LONG_SIDE_PX = 480
        private const val JPEG_QUALITY = 70
        private const val FACE_CROP_PAD = 0.3f
        private const val MAX_FACE_COVERED = 0.05f
        private const val FACE_EDGE_MARGIN = 0.04f
        private const val MAX_FACE_YAW_DEG = 25f
        private const val SLEEP_BRIGHTNESS = 0.01f

        private val UUID_RE =
            Regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")

        /** Fraction of the face box hidden behind the badge box, 0f when they miss. */
        fun faceCoveredFraction(face: Box, badge: Box): Float {
            val faceArea = area(face)
            if (faceArea <= 0L) return 0f
            val w = (min(face.right, badge.right) - max(face.left, badge.left)).coerceAtLeast(0)
            val h = (min(face.bottom, badge.bottom) - max(face.top, badge.top)).coerceAtLeast(0)
            return (w.toLong() * h.toLong()).toFloat() / faceArea.toFloat()
        }

        /**
         * Whole head in shot. A 4% inset catches boxes of a visible half that
         * sit a few pixels in, not at 0. Size does not matter — a 30%
         * arm's-length face that is complete must punch.
         */
        fun faceFullyInFrame(face: Box, imageWidth: Int, imageHeight: Int): Boolean {
            if (imageWidth <= 0 || imageHeight <= 0) return false
            if (area(face) <= 0L) return false
            val mx = max(1, (imageWidth * FACE_EDGE_MARGIN).toInt())
            val my = max(1, (imageHeight * FACE_EDGE_MARGIN).toInt())
            return face.left >= mx &&
                face.top >= my &&
                face.right <= imageWidth - mx &&
                face.bottom <= imageHeight - my
        }

        fun fullFaceFeatures(hasLeftEye: Boolean, hasRightEye: Boolean, hasNose: Boolean): Boolean =
            hasLeftEye && hasRightEye && hasNose

        fun faceIsFrontal(eulerY: Float, maxAbsDeg: Float = MAX_FACE_YAW_DEG): Boolean =
            abs(eulerY) <= maxAbsDeg

        /** ML Kit boxes are in the rotated (upright) image; the buffer may be landscape. */
        fun uprightImageSize(width: Int, height: Int, rotationDegrees: Int): Pair<Int, Int> =
            if (rotationDegrees % 180 == 0) width to height else height to width

        /** Fails closed: a degenerate face box counts as occluded. */
        fun badgeOccludesFace(
            face: Box,
            badge: Box,
            maxFraction: Float = MAX_FACE_COVERED,
        ): Boolean {
            if (area(face) <= 0L) return true
            return faceCoveredFraction(face, badge) > maxFraction
        }

        /** Face box padded outward and clamped to the image — ML Kit's box is tight. */
        fun faceCropBox(face: Box, padFraction: Float, imgW: Int, imgH: Int): Box {
            val padX = ((face.right - face.left) * padFraction).toInt()
            val padY = ((face.bottom - face.top) * padFraction).toInt()
            return Box(
                left = (face.left - padX).coerceIn(0, imgW),
                top = (face.top - padY).coerceIn(0, imgH),
                right = (face.right + padX).coerceIn(0, imgW),
                bottom = (face.bottom + padY).coerceIn(0, imgH),
            )
        }

        /** The person at the gate, not a bystander in the background. */
        fun largestFace(faces: List<Box>): Box? = faces.maxByOrNull { area(it) }

        private fun area(b: Box): Long =
            (b.right - b.left).coerceAtLeast(0).toLong() *
                (b.bottom - b.top).coerceAtLeast(0).toLong()

        fun parseBadge(raw: String): String? {
            val trimmed = raw.trim()
            val id = if (trimmed.startsWith("fcqa:")) {
                trimmed.removePrefix("fcqa:")
            } else {
                trimmed
            }
            return id.takeIf { UUID_RE.matches(it) }
        }

        fun pickBadge(raws: Iterable<String>): BadgePick {
            val ids = raws.mapNotNull { parseBadge(it.trim()) }.toSet()
            return when (ids.size) {
                0 -> BadgePick.None
                1 -> BadgePick.One(ids.single())
                else -> BadgePick.Ambiguous
            }
        }

        /** Same IDs as [pickBadge]; if that is One, the barcode used for the box prefers fcqa:. */
        fun pickBadgeBarcode(barcodes: List<Barcode>): Pair<BadgePick, Barcode?> {
            val parsed = barcodes.mapNotNull { b ->
                val raw = b.rawValue?.trim()?.takeIf { it.isNotEmpty() } ?: return@mapNotNull null
                parseBadge(raw)?.let { id -> Triple(id, raw, b) }
            }
            val pick = pickBadge(parsed.map { it.second })
            val badge = when (pick) {
                is BadgePick.One ->
                    parsed.firstOrNull { it.second.startsWith("fcqa:") }?.third
                        ?: parsed.firstOrNull()?.third
                else -> null
            }
            return pick to badge
        }

        fun Rect.toBox(): Box = Box(left, top, right, bottom)

        /** Landmarks mean the feature is in this cropped frame, not badge occlusion. */
        fun isCompleteFace(face: Face, imageWidth: Int, imageHeight: Int): Boolean {
            val box = face.boundingBox.toBox()
            return faceFullyInFrame(box, imageWidth, imageHeight) &&
                fullFaceFeatures(
                    face.getLandmark(FaceLandmark.LEFT_EYE) != null,
                    face.getLandmark(FaceLandmark.RIGHT_EYE) != null,
                    face.getLandmark(FaceLandmark.NOSE_BASE) != null,
                ) &&
                faceIsFrontal(face.headEulerAngleY)
        }

        /** Falls back to the whole frame if the padded box is degenerate. */
        fun cropToFace(src: Bitmap, face: Box): Bitmap {
            val box = faceCropBox(face, FACE_CROP_PAD, src.width, src.height)
            val w = box.right - box.left
            val h = box.bottom - box.top
            if (w <= 0 || h <= 0) return src
            return Bitmap.createBitmap(src, box.left, box.top, w, h)
        }

        fun rotateIfNeeded(bitmap: Bitmap, degrees: Int): Bitmap {
            if (degrees % 360 == 0) return bitmap
            val matrix = Matrix().apply { postRotate(degrees.toFloat()) }
            return Bitmap.createBitmap(bitmap, 0, 0, bitmap.width, bitmap.height, matrix, true)
        }

        fun writeFaceJpeg(bitmap: Bitmap, dest: File): Boolean {
            val scaled = scaleLongSide(bitmap, LONG_SIDE_PX)
            dest.outputStream().use { out ->
                if (!scaled.compress(Bitmap.CompressFormat.JPEG, JPEG_QUALITY, out)) return false
            }
            val size = dest.length()
            if (size !in 1..MAX_PHOTO_BYTES) {
                Log.w(TAG, "face jpeg ${size}b outside 1..$MAX_PHOTO_BYTES")
                return false
            }
            return true
        }

        fun scaleLongSide(src: Bitmap, longSide: Int): Bitmap {
            val longest = max(src.width, src.height)
            if (longest <= longSide) return src
            val scale = longSide.toFloat() / longest.toFloat()
            val w = (src.width * scale).toInt().coerceAtLeast(1)
            val h = (src.height * scale).toInt().coerceAtLeast(1)
            return Bitmap.createScaledBitmap(src, w, h, true)
        }
    }
}
