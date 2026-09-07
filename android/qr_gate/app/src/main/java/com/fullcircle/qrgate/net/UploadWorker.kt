package com.fullcircle.qrgate.net

import android.content.Context
import android.util.Log
import androidx.work.BackoffPolicy
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import com.fullcircle.qrgate.Prefs
import com.fullcircle.qrgate.data.PunchDao
import com.fullcircle.qrgate.data.PunchEntity
import com.fullcircle.qrgate.data.QueueDb
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.MultipartBody
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.asRequestBody
import java.io.File
import java.io.IOException
import java.util.concurrent.TimeUnit

class UploadWorker(
    context: Context,
    params: WorkerParameters,
) : CoroutineWorker(context, params) {

    override suspend fun doWork(): Result {
        val prefs = Prefs(applicationContext)
        val token = prefs.token
        val baseUrl = prefs.baseUrl.trimEnd('/')
        if (token.isEmpty() || baseUrl.isEmpty()) {
            return Result.success()
        }

        val dao = QueueDb.get(applicationContext).punchDao()
        val rows = dao.all()
        if (rows.isEmpty()) return Result.success()

        var networkFail = false
        for (row in rows) {
            when (val outcome = upload(baseUrl, token, row)) {
                is Outcome.Done -> {
                    dao.delete(row.clientId)
                    File(row.photoPath).delete()
                }
                is Outcome.Revoked -> {
                    dropAll(dao, rows)
                    prefs.clear()
                    Log.w(TAG, "device token rejected (401); pairing cleared")
                    return Result.success()
                }
                is Outcome.Retry -> {
                    dao.markAttempt(row.clientId, row.tries + 1, outcome.reason)
                    networkFail = true
                }
            }
        }
        return if (networkFail) Result.retry() else Result.success()
    }

    private suspend fun dropAll(
        dao: PunchDao,
        rows: List<PunchEntity>,
    ) {
        for (row in rows) {
            dao.delete(row.clientId)
            File(row.photoPath).delete()
        }
    }

    private fun upload(baseUrl: String, token: String, row: PunchEntity): Outcome {
        val photo = File(row.photoPath)
        if (!photo.isFile) {
            Log.w(TAG, "photo missing for ${row.clientId}; dropping")
            return Outcome.Done
        }

        val body = MultipartBody.Builder()
            .setType(MultipartBody.FORM)
            .addFormDataPart("employee_id", row.employeeId)
            .addFormDataPart("punched_at", row.punchedAtIso)
            .addFormDataPart("client_id", row.clientId)
            .addFormDataPart(
                "photo",
                "face.jpg",
                photo.asRequestBody(JPEG),
            )
            .build()

        val request = Request.Builder()
            .url("$baseUrl/api/punch/attendances")
            .header("Authorization", "Bearer $token")
            .post(body)
            .build()

        return try {
            client.newCall(request).execute().use { resp ->
                when (resp.code) {
                    201 -> {
                        Log.i(TAG, "uploaded ${row.clientId}")
                        Outcome.Done
                    }
                    401 -> Outcome.Revoked
                    404, 409, 413, 422 -> {
                        Log.w(TAG, "drop ${row.clientId} after HTTP ${resp.code}")
                        Outcome.Done
                    }
                    in 400..499 -> {
                        Log.w(TAG, "drop ${row.clientId} after HTTP ${resp.code}")
                        Outcome.Done
                    }
                    else -> {
                        Log.w(TAG, "retry ${row.clientId} after HTTP ${resp.code}")
                        Outcome.Retry("HTTP ${resp.code}")
                    }
                }
            }
        } catch (e: IOException) {
            Log.w(TAG, "network error for ${row.clientId}: ${e.message}")
            Outcome.Retry(e.message ?: "network")
        }
    }

    private sealed class Outcome {
        data object Done : Outcome()
        data object Revoked : Outcome()
        data class Retry(val reason: String) : Outcome()
    }

    companion object {
        private const val TAG = "QrGateUpload"
        private const val UNIQUE_NAME = "punch-upload"
        private val JPEG = "image/jpeg".toMediaType()

        private val client: OkHttpClient = OkHttpClient.Builder()
            .connectTimeout(15, TimeUnit.SECONDS)
            .writeTimeout(30, TimeUnit.SECONDS)
            .readTimeout(30, TimeUnit.SECONDS)
            .build()

        fun enqueue(context: Context) {
            val request = OneTimeWorkRequestBuilder<UploadWorker>()
                .setConstraints(
                    Constraints.Builder()
                        .setRequiredNetworkType(NetworkType.CONNECTED)
                        .build(),
                )
                .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 15, TimeUnit.SECONDS)
                .build()
            WorkManager.getInstance(context).enqueueUniqueWork(
                UNIQUE_NAME,
                ExistingWorkPolicy.APPEND_OR_REPLACE,
                request,
            )
        }
    }
}
