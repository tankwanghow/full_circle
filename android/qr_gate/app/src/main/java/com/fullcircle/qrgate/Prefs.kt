package com.fullcircle.qrgate

import android.content.Context
import android.content.SharedPreferences

class Prefs(context: Context) {
    private val sp: SharedPreferences =
        context.applicationContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    var token: String
        get() = sp.getString(KEY_TOKEN, "") ?: ""
        set(value) {
            sp.edit().putString(KEY_TOKEN, value).apply()
        }

    var baseUrl: String
        get() = sp.getString(KEY_BASE_URL, "") ?: ""
        set(value) {
            sp.edit().putString(KEY_BASE_URL, value.trimEnd('/')).apply()
        }

    val isPaired: Boolean
        get() = token.isNotEmpty() && baseUrl.isNotEmpty()

    /** Camera-off idle, seconds. Survives re-pair; not cleared with the token. */
    var idleSeconds: Int
        get() = BurstIdle.clampIdleSeconds(
            sp.getInt(KEY_IDLE_SEC, BurstIdle.DEFAULT_IDLE_SEC),
        )
        set(value) {
            sp.edit().putInt(KEY_IDLE_SEC, BurstIdle.clampIdleSeconds(value)).apply()
        }

    fun savePairing(token: String, baseUrl: String) {
        sp.edit()
            .putString(KEY_TOKEN, token)
            .putString(KEY_BASE_URL, baseUrl.trimEnd('/'))
            .apply()
    }

    fun clear() {
        // Editor.clear() does not notify listeners of KEY_TOKEN.
        sp.edit()
            .remove(KEY_TOKEN)
            .remove(KEY_BASE_URL)
            .apply()
    }

    fun register(listener: SharedPreferences.OnSharedPreferenceChangeListener) {
        sp.registerOnSharedPreferenceChangeListener(listener)
    }

    fun unregister(listener: SharedPreferences.OnSharedPreferenceChangeListener) {
        sp.unregisterOnSharedPreferenceChangeListener(listener)
    }

    companion object {
        const val PREFS_NAME = "qr_gate"
        const val KEY_TOKEN = "token"
        const val KEY_BASE_URL = "baseUrl"
        const val KEY_IDLE_SEC = "idleSeconds"
    }
}
