package com.fullcircle.qrgate

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class BurstIdleTest {
    @Test
    fun startsActiveAndWantsTheIdleTimerArmed() {
        val idle = BurstIdle()
        assertEquals(BurstIdle.Mode.ACTIVE, idle.mode)
        assertEquals(BurstIdle.Effect.ArmIdle, idle.started())
        assertEquals(BurstIdle.Mode.ACTIVE, idle.mode)
        assertFalse(idle.busy)
    }

    @Test
    fun aFaceWhileWaitingRearmsTheIdleTimer() {
        val idle = BurstIdle()
        idle.started()
        assertEquals(BurstIdle.Effect.ArmIdle, idle.faceSeen())
        assertEquals(BurstIdle.Mode.ACTIVE, idle.mode)
    }

    @Test
    fun idleElapsedWhileWaitingGoesToSleep() {
        val idle = BurstIdle()
        idle.started()
        assertEquals(BurstIdle.Effect.Sleep, idle.idleElapsed())
        assertEquals(BurstIdle.Mode.SLEEP, idle.mode)
    }

    @Test
    fun aFaceDoesNotWakeFromSleep() {
        val idle = BurstIdle()
        idle.started()
        idle.idleElapsed()
        assertEquals(BurstIdle.Effect.None, idle.faceSeen())
        assertEquals(BurstIdle.Mode.SLEEP, idle.mode)
    }

    @Test
    fun tapWakesFromSleep() {
        val idle = BurstIdle()
        idle.started()
        idle.idleElapsed()
        assertEquals(BurstIdle.Effect.Wake, idle.tapped())
        assertEquals(BurstIdle.Mode.ACTIVE, idle.mode)
        assertFalse(idle.busy)
    }

    @Test
    fun tapWhileActiveDoesNothing() {
        val idle = BurstIdle()
        idle.started()
        assertEquals(BurstIdle.Effect.None, idle.tapped())
        assertEquals(BurstIdle.Mode.ACTIVE, idle.mode)
    }

    @Test
    fun captureDisarmsIdleAndBlocksSleep() {
        val idle = BurstIdle()
        idle.started()
        assertEquals(BurstIdle.Effect.DisarmIdle, idle.captureStarted())
        assertTrue(idle.busy)
        assertEquals(BurstIdle.Effect.None, idle.idleElapsed())
        assertEquals(BurstIdle.Mode.ACTIVE, idle.mode)
        assertEquals(BurstIdle.Effect.None, idle.faceSeen())
    }

    @Test
    fun backToWaitAfterCaptureRearmsIdle() {
        val idle = BurstIdle()
        idle.started()
        idle.captureStarted()
        assertEquals(BurstIdle.Effect.ArmIdle, idle.backToWait())
        assertFalse(idle.busy)
        assertEquals(BurstIdle.Mode.ACTIVE, idle.mode)
    }

    @Test
    fun idleElapsedWhileAlreadyAsleepDoesNothing() {
        val idle = BurstIdle()
        idle.started()
        idle.idleElapsed()
        assertEquals(BurstIdle.Effect.None, idle.idleElapsed())
        assertEquals(BurstIdle.Mode.SLEEP, idle.mode)
    }

    @Test
    fun abortSleepUndoesIdleElapsedWhenCaptureWonTheRace() {
        val idle = BurstIdle()
        idle.started()
        idle.idleElapsed()
        assertEquals(BurstIdle.Mode.SLEEP, idle.mode)
        idle.abortSleep()
        assertEquals(BurstIdle.Mode.ACTIVE, idle.mode)
        assertEquals(BurstIdle.Effect.None, idle.tapped())
    }

    @Test
    fun idleWindowIsTwentySeconds() {
        assertEquals(20, BurstIdle.DEFAULT_IDLE_SEC)
        assertEquals(20_000L, BurstIdle.IDLE_MS)
    }

    @Test
    fun idleSecondsAreClampedToFiveThroughOneTwenty() {
        assertEquals(5, BurstIdle.clampIdleSeconds(5))
        assertEquals(20, BurstIdle.clampIdleSeconds(20))
        assertEquals(120, BurstIdle.clampIdleSeconds(120))
        assertEquals(5, BurstIdle.clampIdleSeconds(4))
        assertEquals(5, BurstIdle.clampIdleSeconds(0))
        assertEquals(5, BurstIdle.clampIdleSeconds(-3))
        assertEquals(120, BurstIdle.clampIdleSeconds(121))
        assertEquals(120, BurstIdle.clampIdleSeconds(9_999))
    }

    @Test
    fun idleSecondsParseJunkAsTheDefault() {
        assertEquals(20, BurstIdle.parseIdleSeconds(""))
        assertEquals(20, BurstIdle.parseIdleSeconds("  "))
        assertEquals(20, BurstIdle.parseIdleSeconds("abc"))
        assertEquals(20, BurstIdle.parseIdleSeconds("20.5"))
        assertEquals(45, BurstIdle.parseIdleSeconds(" 45 "))
        assertEquals(5, BurstIdle.parseIdleSeconds("1"))
        assertEquals(120, BurstIdle.parseIdleSeconds("999"))
    }
}
