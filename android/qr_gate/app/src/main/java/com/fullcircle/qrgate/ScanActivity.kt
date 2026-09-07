package com.fullcircle.qrgate

import android.Manifest
import android.content.Intent
import android.content.SharedPreferences
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.Matrix
import android.media.AudioManager
import android.media.ToneGenerator
import android.os.Bundle
import android.os.SystemClock
import android.util.Log
import android.view.View
import android.view.WindowManager
import androidx.activity.OnBackPressedCallback
import androidx.activity.result.contract.ActivityResultContracts
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

class ScanActivity : AppCompatActivity() {
    private enum class Step { QR, FACE, CAPTURING, OK }

    private lateinit var binding: ActivityScanBinding
    private lateinit var prefs: Prefs
    private lateinit var cameraExecutor: ExecutorService
    private lateinit var scanner: BarcodeScanner
    private lateinit var faceDetector: FaceDetector
    private lateinit var photosDir: File

    private var imageCapture: ImageCapture? = null
    private var pendingEmployeeId: String? = null
    private var pendingPunchedAtIso: String? = null
    private val faceEpoch = AtomicInteger(0)
    private var faceDeadlineElapsed = 0L
    private var lastRejectBeepAt = 0L
    private var qrReadyAt = 0L
    private val lastOkAtByEmployee = ConcurrentHashMap<String, Long>()
    private val step = AtomicReference(Step.QR)
    private val faceTimeout = Runnable { onFaceTimeout() }

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
                binding.prompt.setText("Front camera required")
            }
        }, ContextCompat.getMainExecutor(this))
    }

    @OptIn(ExperimentalGetImage::class)
    private fun analyzeFrame(imageProxy: ImageProxy) {
        val media = imageProxy.image
        if (media == null) {
            imageProxy.close()
            return
        }
        val image = InputImage.fromMediaImage(media, imageProxy.imageInfo.rotationDegrees)
        when (step.get()) {
            Step.QR -> {
                scanner.process(image)
                    .addOnSuccessListener { barcodes ->
                        if (step.get() != Step.QR) return@addOnSuccessListener
                        val now = SystemClock.elapsedRealtime()
                        if (now < qrReadyAt) return@addOnSuccessListener
                        val raw = barcodes.firstNotNullOfOrNull { it.rawValue }
                            ?: return@addOnSuccessListener
                        val empId = parseBadge(raw) ?: return@addOnSuccessListener
                        if (recentlyAccepted(empId)) {
                            dupRejectBeep()
                            return@addOnSuccessListener
                        }
                        if (step.compareAndSet(Step.QR, Step.FACE)) {
                            runOnUiThread { onBadgeScanned(empId) }
                        }
                    }
                    .addOnCompleteListener { imageProxy.close() }
            }
            Step.FACE -> {
                faceDetector.process(image)
                    .addOnSuccessListener { faces ->
                        if (step.get() != Step.FACE) return@addOnSuccessListener
                        if (faces.isNotEmpty() && step.compareAndSet(Step.FACE, Step.CAPTURING)) {
                            runOnUiThread { captureFace() }
                        }
                    }
                    .addOnCompleteListener { imageProxy.close() }
            }
            else -> imageProxy.close()
        }
    }

    private fun onBadgeScanned(employeeId: String) {
        pendingEmployeeId = employeeId
        pendingPunchedAtIso = Instant.now().truncatedTo(ChronoUnit.SECONDS).toString()
        binding.guideSquare.visibility = View.GONE
        binding.guideOval.visibility = View.VISIBLE
        binding.prompt.setText(R.string.look_at_camera)
        armFaceTimeout()
    }

    private fun armFaceTimeout() {
        faceEpoch.incrementAndGet()
        faceDeadlineElapsed = SystemClock.elapsedRealtime() + FACE_TIMEOUT_MS
        binding.root.removeCallbacks(faceTimeout)
        binding.root.postDelayed(faceTimeout, FACE_TIMEOUT_MS)
    }

    private fun cancelFaceTimeout() {
        if (::binding.isInitialized) binding.root.removeCallbacks(faceTimeout)
    }

    private fun onFaceTimeout() {
        // Shutter already in flight (a face was seen) may finish; don't abort that.
        if (step.get() != Step.FACE) return
        abortFaceStep()
    }

    private fun abortFaceStep() {
        if (step.get() == Step.OK || step.get() == Step.QR) return
        faceEpoch.incrementAndGet()
        pendingEmployeeId = null
        pendingPunchedAtIso = null
        step.set(Step.QR)
        beep(ToneGenerator.TONE_PROP_NACK, 300)
        backToQr()
    }

    private fun captureFace() {
        if (isDestroyed || isFinishing) return
        if (step.get() != Step.CAPTURING) return
        val epoch = faceEpoch.get()
        val capture = imageCapture
        if (capture == null) {
            stayOnFace(beepReject = true)
            return
        }
        capture.takePicture(
            cameraExecutor,
            object : ImageCapture.OnImageCapturedCallback() {
                override fun onCaptureSuccess(image: ImageProxy) {
                    if (epoch != faceEpoch.get()) {
                        image.close()
                        return
                    }
                    val bitmap = try {
                        image.toBitmap()
                    } catch (e: Exception) {
                        Log.w(TAG, "toBitmap failed", e)
                        image.close()
                        stayOnFace(beepReject = true)
                        return
                    }
                    val rotated = rotateIfNeeded(bitmap, image.imageInfo.rotationDegrees)
                    image.close()

                    if (epoch != faceEpoch.get()) return

                    if (!hasFace(rotated)) {
                        Log.i(TAG, "capture has zero faces; not queueing")
                        stayOnFace(beepReject = true)
                        return
                    }

                    val emp = pendingEmployeeId
                    val punchedAt = pendingPunchedAtIso
                    if (emp == null || punchedAt == null || epoch != faceEpoch.get()) {
                        runOnUiThread { backToQr() }
                        return
                    }
                    val clientId = UUID.randomUUID().toString()
                    val dest = File(photosDir, "$clientId.jpg")
                    if (!writeFaceJpeg(rotated, dest)) {
                        dest.delete()
                        stayOnFace(beepReject = true)
                        return
                    }
                    if (epoch != faceEpoch.get()) {
                        dest.delete()
                        return
                    }
                    queuePunch(clientId, emp, punchedAt, dest)
                }

                override fun onError(exception: ImageCaptureException) {
                    Log.w(TAG, "capture failed", exception)
                    if (epoch != faceEpoch.get()) return
                    stayOnFace(beepReject = true)
                }
            },
        )
    }

    /** Detection only — no matching / enrolment. Empty or error → do not save. */
    private fun hasFace(bitmap: Bitmap): Boolean {
        return try {
            val image = InputImage.fromBitmap(bitmap, 0)
            val faces = Tasks.await(faceDetector.process(image), 2, TimeUnit.SECONDS)
            faces.isNotEmpty()
        } catch (e: Exception) {
            Log.w(TAG, "face detect failed", e)
            false
        }
    }

    private fun stayOnFace(beepReject: Boolean) {
        if (pendingEmployeeId == null || step.get() == Step.QR || step.get() == Step.OK) {
            runOnUiThread { backToQr() }
            return
        }
        if (SystemClock.elapsedRealtime() >= faceDeadlineElapsed) {
            runOnUiThread { abortFaceStep() }
            return
        }
        step.set(Step.FACE)
        val now = SystemClock.elapsedRealtime()
        val shouldBeep = beepReject && now - lastRejectBeepAt > 1_500L
        if (shouldBeep) lastRejectBeepAt = now
        runOnUiThread {
            if (isDestroyed || isFinishing) return@runOnUiThread
            if (pendingEmployeeId == null) {
                backToQr()
                return@runOnUiThread
            }
            if (shouldBeep) beep(ToneGenerator.TONE_PROP_NACK, 300)
            binding.guideSquare.visibility = View.GONE
            binding.guideOval.visibility = View.VISIBLE
            binding.prompt.setText(R.string.look_at_camera)
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
                    backToQr()
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
        cancelFaceTimeout()
        faceEpoch.incrementAndGet()
        pendingEmployeeId = null
        pendingPunchedAtIso = null
        step.set(Step.OK)
        beep(ToneGenerator.TONE_PROP_BEEP, 200)
        binding.guideSquare.visibility = View.GONE
        binding.guideOval.visibility = View.GONE
        binding.prompt.setText(R.string.ok)
        binding.root.postDelayed({ backToQr() }, OK_MS)
    }

    private fun backToQr() {
        if (isDestroyed || isFinishing) return
        cancelFaceTimeout()
        faceEpoch.incrementAndGet()
        pendingEmployeeId = null
        pendingPunchedAtIso = null
        if (prefs.token.isEmpty()) {
            goPairing()
            return
        }
        qrReadyAt = SystemClock.elapsedRealtime() + QR_COOLDOWN_MS
        binding.guideOval.visibility = View.GONE
        binding.guideSquare.visibility = View.VISIBLE
        binding.prompt.setText(R.string.scan_badge)
        step.set(Step.QR)
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
        runOnUiThread { beep(ToneGenerator.TONE_SUP_ERROR, 400) }
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
        cancelFaceTimeout()
        super.onDestroy()
        if (::cameraExecutor.isInitialized) cameraExecutor.shutdown()
        if (::scanner.isInitialized) scanner.close()
        if (::faceDetector.isInitialized) faceDetector.close()
    }

    companion object {
        private const val TAG = "QrGateScan"
        private const val FACE_TIMEOUT_MS = 8_000L
        private const val OK_MS = 1_500L
        private const val QR_COOLDOWN_MS = 2_000L
        private const val DUP_WINDOW_MS = 180_000L
        private const val MAX_PHOTO_BYTES = 300_000L
        private const val LONG_SIDE_PX = 480
        private const val JPEG_QUALITY = 70

        private val UUID_RE =
            Regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")

        fun parseBadge(raw: String): String? {
            val trimmed = raw.trim()
            val id = if (trimmed.startsWith("fcqa:")) {
                trimmed.removePrefix("fcqa:")
            } else {
                trimmed
            }
            return id.takeIf { UUID_RE.matches(it) }
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
