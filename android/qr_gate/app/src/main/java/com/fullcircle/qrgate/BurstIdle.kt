package com.fullcircle.qrgate

/**
 * Camera-on only while a queue is at the gate. Sleep is a dim, tappable
 * screen with the camera unbound — cheap phones have no long-range PIR,
 * and a real screen-off ignores taps when the power button is in the mount.
 */
class BurstIdle {
    enum class Mode { ACTIVE, SLEEP }

    enum class Effect { None, ArmIdle, DisarmIdle, Sleep, Wake }

    @Volatile
    var mode: Mode = Mode.ACTIVE
        private set

    var busy: Boolean = false
        private set

    fun started(): Effect {
        mode = Mode.ACTIVE
        busy = false
        return Effect.ArmIdle
    }

    fun faceSeen(): Effect {
        if (mode != Mode.ACTIVE || busy) return Effect.None
        return Effect.ArmIdle
    }

    fun captureStarted(): Effect {
        if (mode != Mode.ACTIVE) return Effect.None
        busy = true
        return Effect.DisarmIdle
    }

    fun backToWait(): Effect {
        busy = false
        if (mode != Mode.ACTIVE) return Effect.None
        return Effect.ArmIdle
    }

    fun idleElapsed(): Effect {
        if (mode != Mode.ACTIVE || busy) return Effect.None
        mode = Mode.SLEEP
        return Effect.Sleep
    }

    fun tapped(): Effect {
        if (mode != Mode.SLEEP) return Effect.None
        mode = Mode.ACTIVE
        busy = false
        return Effect.Wake
    }

    /** Capture started on the camera thread after idleElapsed had already flipped us. */
    fun abortSleep() {
        if (mode == Mode.SLEEP) mode = Mode.ACTIVE
    }

    companion object {
        const val MIN_IDLE_SEC = 5
        const val MAX_IDLE_SEC = 120
        const val DEFAULT_IDLE_SEC = 20
        const val IDLE_MS = DEFAULT_IDLE_SEC * 1000L

        fun clampIdleSeconds(raw: Int): Int = raw.coerceIn(MIN_IDLE_SEC, MAX_IDLE_SEC)

        fun parseIdleSeconds(raw: String): Int {
            val n = raw.trim().toIntOrNull() ?: return DEFAULT_IDLE_SEC
            return clampIdleSeconds(n)
        }
    }
}
