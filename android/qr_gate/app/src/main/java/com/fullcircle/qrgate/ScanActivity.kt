package com.fullcircle.qrgate

import android.Manifest
import android.content.Intent
import android.content.SharedPreferences
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.Matrix
import android.graphics.Rect
import android.media.AudioManager
import android.media.ToneGenerator
import android.os.Bundle
import android.os.SystemClock
import android.util.Log
import android.view.View
import android.view.WindowManager
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
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.core.content.ContextCompat
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import androidx.lifecycle.lifecycleScope
import com.fullcircle.qrgate.data.PunchEntity
import com.fullcircle.qrgate.data.QueueDb
import com.fullcircle.qrgate.databinding.ActivityScanBinding
import com.fullcircle.qrgate.net.UploadWorker
import com.google.android.gms.tasks.Tasks
import com.google.mlkit.vision.barcode.BarcodeScanner
import com.google.mlkit.vision.barcode.BarcodeScannerOptions
import com.google.mlkit.vision.barcode.BarcodeScanning
import com.google.mlkit.vision.barcode.common.Barcode
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.face.FaceDetection
import com.google.mlkit.vision.face.FaceDetector
import com.google.mlkit.vision.face.FaceDetectorOptions
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import java.time.Instant
import java.time.temporal.ChronoUnit
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import kotlin.math.max
import kotlin.math.min

class ScanActivity : AppCompatActivity() {
    private enum class Step { WAIT, CAPTURING, OK }

    /** Rect-free so the geometry stays unit-testable off-device. */
    data class Box(val left: Int, val top: Int, val right: Int, val bottom: Int)

    private lateinit var binding: ActivityScanBinding
    private lateinit var prefs: Prefs
    private lateinit var cameraExecutor: ExecutorService
    private lateinit var scanner: BarcodeScanner
    private lateinit var faceDetector: FaceDetector
    private lateinit var photosDir: File

    private var imageCapture: ImageCapture? = null
    private var pendingEmployeeId: String? = null
    private var pendingPunchedAtIso: String? = null
    private val captureGeneration = AtomicInteger(0)
    private var lastRejectBeepAt = 0L
    private var lastHintAt = 0L
    private var readyAt = 0L
    private val lastOkAtByEmployee = ConcurrentHashMap<String, Long>()
    private val step = AtomicReference(Step.WAIT)

    private val prefListener =
        SharedPreferences.OnSharedPreferenceChangeListener { _, key ->
            if (key == Prefs.KEY_TOKEN && prefs.token.isEmpty()) {
                runOnUiThread { goPairing() }
            }
        }

    private val requestCamera =
        registerForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
            if (granted) startCamera() else binding.prompt.setText(R.string.camera_required)
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
                .setLandmarkMode(FaceDetectorOptions.LANDMARK_MODE_NONE)
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
        val future = ProcessCameraProvider.getInstance(this)
        future.addListener({
            val provider = future.get()
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
                provider.bindToLifecycle(
                    this,
                    CameraSelector.DEFAULT_FRONT_CAMERA,
                    preview,
                    capture,
                    analysis,
                )
            } catch (e: IllegalArgumentException) {
                Log.e(TAG, "front camera required", e)
                binding.prompt.setText(R.string.front_camera_required)
            }
        }, ContextCompat.getMainExecutor(this))
    }

    @OptIn(ExperimentalGetImage::class)
    private fun analyzeFrame(imageProxy: ImageProxy) {
        val media = imageProxy.image
        if (media == null || step.get() != Step.WAIT ||
            SystemClock.elapsedRealtime() < readyAt
        ) {
            imageProxy.close()
            return
        }
        val image = InputImage.fromMediaImage(media, imageProxy.imageInfo.rotationDegrees)
        val barcodesTask = scanner.process(image)
        val facesTask = faceDetector.process(image)
        Tasks.whenAllComplete(barcodesTask, facesTask)
            .addOnCompleteListener {
                try {
                    if (step.get() != Step.WAIT) return@addOnCompleteListener
                    if (!barcodesTask.isSuccessful || !facesTask.isSuccessful) {
                        return@addOnCompleteListener
                    }
                    val (empId, badge) = pickBadgeBarcode(barcodesTask.result.orEmpty())
                        ?: return@addOnCompleteListener
                    val badgeBox = badge.boundingBox?.toBox() ?: return@addOnCompleteListener
                    val faceBox = largestFace(
                        facesTask.result.orEmpty().map { it.boundingBox.toBox() },
                    ) ?: return@addOnCompleteListener
                    if (badgeOccludesFace(faceBox, badgeBox)) {
                        showHint(R.string.badge_covers_face)
                        return@addOnCompleteListener
                    }
                    if (recentlyAccepted(empId)) {
                        dupRejectBeep()
                        return@addOnCompleteListener
                    }
                    if (step.compareAndSet(Step.WAIT, Step.CAPTURING)) {
                        pendingEmployeeId = empId
                        pendingPunchedAtIso =
                            Instant.now().truncatedTo(ChronoUnit.SECONDS).toString()
                        runOnUiThread { captureStill() }
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

        val (id, badge) = pickBadgeBarcode(barcodes) ?: return null
        if (!id.equals(expectedEmp, ignoreCase = true)) return null
        val badgeBox = badge.boundingBox?.toBox() ?: return null
        val faceBox = largestFace(faces.map { it.boundingBox.toBox() }) ?: return null
        if (badgeOccludesFace(faceBox, badgeBox)) {
            Log.i(TAG, "badge covers face; not queueing")
            return null
        }
        return faceBox
    }

    private fun rejectStill(@StringRes reasonRes: Int = R.string.capture_rejected) {
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
            showHint(reasonRes, force = true)
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
        binding.guideFrame.visibility = View.GONE
        binding.prompt.setText(R.string.ok)
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

    /** Briefly explain a rejection, then fall back to the standing prompt. */
    private fun showHint(@StringRes res: Int, force: Boolean = false) {
        val now = SystemClock.elapsedRealtime()
        if (!force && now - lastHintAt < HINT_MS) return
        lastHintAt = now
        runOnUiThread {
            if (isDestroyed || isFinishing) return@runOnUiThread
            binding.prompt.setText(res)
            binding.root.postDelayed({
                if (!isDestroyed && !isFinishing && step.get() == Step.WAIT) {
                    binding.prompt.setText(R.string.scan_badge)
                }
            }, HINT_MS)
        }
    }

    private fun showWaitUi() {
        binding.guideFrame.visibility = View.VISIBLE
        binding.prompt.setText(R.string.scan_badge)
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

    override fun onDestroy() {
        captureGeneration.incrementAndGet()
        super.onDestroy()
        if (::cameraExecutor.isInitialized) cameraExecutor.shutdown()
        if (::scanner.isInitialized) scanner.close()
        if (::faceDetector.isInitialized) faceDetector.close()
    }

    companion object {
        private const val TAG = "QrGateScan"
        private const val OK_MS = 1_500L
        private const val QR_COOLDOWN_MS = 2_000L
        private const val REJECT_COOLDOWN_MS = 750L
        private const val HINT_MS = 1_500L
        private const val FLASH_ALPHA = 0.75f
        private const val FLASH_HOLD_MS = 250L
        private const val FLASH_FADE_MS = 400L
        private const val DUP_WINDOW_MS = 180_000L
        private const val MAX_PHOTO_BYTES = 300_000L
        private const val LONG_SIDE_PX = 480
        private const val JPEG_QUALITY = 70
        private const val FACE_CROP_PAD = 0.3f
        private const val MAX_FACE_COVERED = 0.05f

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

        fun pickBadge(raws: Iterable<String>): String? {
            val trimmed = raws.map { it.trim() }.filter { it.isNotEmpty() }
            trimmed.firstOrNull { it.startsWith("fcqa:") }?.let { parseBadge(it) }?.let { return it }
            return trimmed.firstNotNullOfOrNull { parseBadge(it) }
        }

        /** Same preference as [pickBadge], but keeps the Barcode so its box can be measured. */
        fun pickBadgeBarcode(barcodes: List<Barcode>): Pair<String, Barcode>? {
            val raws = barcodes.mapNotNull { b ->
                b.rawValue?.trim()?.takeIf { it.isNotEmpty() }?.let { it to b }
            }
            raws.firstOrNull { it.first.startsWith("fcqa:") }
                ?.let { (raw, b) -> parseBadge(raw)?.let { return it to b } }
            return raws.firstNotNullOfOrNull { (raw, b) -> parseBadge(raw)?.let { it to b } }
        }

        fun Rect.toBox(): Box = Box(left, top, right, bottom)

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
