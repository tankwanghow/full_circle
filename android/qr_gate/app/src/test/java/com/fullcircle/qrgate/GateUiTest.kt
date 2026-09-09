package com.fullcircle.qrgate

import org.junit.Assert.assertEquals
import org.junit.Test
import java.time.LocalDateTime
import java.time.ZoneId
import java.time.ZonedDateTime

class GateUiTest {
    @Test
    fun queuedLabelCountsUnsentPunches() {
        assertEquals("0 punches not sent", GateUi.queuedLabel(0))
        assertEquals("1 punch not sent", GateUi.queuedLabel(1))
        assertEquals("3 punches not sent", GateUi.queuedLabel(3))
    }

    @Test
    fun dateAndTimeUseEnglishAndTwentyFourHourClock() {
        val at = ZonedDateTime.of(
            LocalDateTime.of(2026, 9, 9, 14, 32, 5),
            ZoneId.of("Asia/Kuala_Lumpur"),
        )
        assertEquals("Wed 9 Sep 2026", GateUi.formatDate(at))
        assertEquals("14:32:05", GateUi.formatTime(at))
    }

    @Test
    fun asleepLeavesBothRequirementsUnmet() {
        val legend = GateUi.legend(
            asleep = true,
            fullFace = false,
            pick = ScanActivity.BadgePick.None,
            occludes = false,
        )
        assertEquals(false, legend.faceOk)
        assertEquals(false, legend.qrOk)
        assertEquals(true, legend.asleep)
    }

    @Test
    fun incompleteFaceIsNotOkEvenIfAQrIsPresent() {
        val legend = GateUi.legend(
            asleep = false,
            fullFace = false,
            pick = ScanActivity.BadgePick.One("aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"),
            occludes = false,
        )
        assertEquals(false, legend.faceOk)
        assertEquals(true, legend.qrOk)
    }

    @Test
    fun fullFaceWithoutQrLeavesQrNotOk() {
        val legend = GateUi.legend(
            asleep = false,
            fullFace = true,
            pick = ScanActivity.BadgePick.None,
            occludes = false,
        )
        assertEquals(true, legend.faceOk)
        assertEquals(false, legend.qrOk)
    }

    @Test
    fun twoBadgesFailQrAndACoveredFaceFailsFace() {
        val two = GateUi.legend(
            asleep = false,
            fullFace = true,
            pick = ScanActivity.BadgePick.Ambiguous,
            occludes = false,
        )
        assertEquals(true, two.faceOk)
        assertEquals(false, two.qrOk)
        val covered = GateUi.legend(
            asleep = false,
            fullFace = true,
            pick = ScanActivity.BadgePick.One("aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"),
            occludes = true,
        )
        assertEquals(false, covered.faceOk)
        assertEquals(true, covered.qrOk)
    }
}
