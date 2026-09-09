package com.fullcircle.qrgate

import java.time.ZonedDateTime
import java.time.format.DateTimeFormatter
import java.util.Locale

object GateUi {
    data class Legend(val faceOk: Boolean, val qrOk: Boolean, val asleep: Boolean)

    private val dateFmt = DateTimeFormatter.ofPattern("EEE d MMM yyyy", Locale.ENGLISH)
    private val timeFmt = DateTimeFormatter.ofPattern("HH:mm:ss", Locale.ENGLISH)

    fun formatDate(at: ZonedDateTime): String = at.format(dateFmt)
    fun formatTime(at: ZonedDateTime): String = at.format(timeFmt)

    fun queuedLabel(count: Int): String =
        if (count == 1) "1 punch not sent" else "$count punches not sent"

    fun legend(
        asleep: Boolean,
        fullFace: Boolean,
        pick: ScanActivity.BadgePick,
        occludes: Boolean,
    ): Legend {
        if (asleep) return Legend(faceOk = false, qrOk = false, asleep = true)
        return Legend(
            faceOk = fullFace && !occludes,
            qrOk = pick is ScanActivity.BadgePick.One,
            asleep = false,
        )
    }
}
