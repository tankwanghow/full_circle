package com.fullcircle.qrgate

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class PairingActivityTest {
    // Release builds forbid cleartext. Pairing only stores the URL, so without
    // this check the failure surfaces much later as a retrying upload error and
    // the gate silently never delivers.
    private val allowCleartext: (String) -> Boolean = { true }
    private val denyCleartext: (String) -> Boolean = { false }

    @Test
    fun httpsIsUsableEvenWhereCleartextIsForbidden() {
        assertTrue(PairingActivity.pairingUrlUsable("https://books.example.com", denyCleartext))
    }

    @Test
    fun httpIsUsableWhenTheBuildPermitsCleartext() {
        assertTrue(PairingActivity.pairingUrlUsable("http://192.168.1.112:4000", allowCleartext))
    }

    @Test
    fun httpIsRefusedWhenTheBuildForbidsCleartext() {
        assertFalse(PairingActivity.pairingUrlUsable("http://192.168.1.112:4000", denyCleartext))
    }

    @Test
    fun aUrlWithoutAHostIsRefused() {
        assertFalse(PairingActivity.pairingUrlUsable("http://", allowCleartext))
        assertFalse(PairingActivity.pairingUrlUsable("not a url", allowCleartext))
    }

    @Test
    fun aNonHttpSchemeIsRefused() {
        assertFalse(PairingActivity.pairingUrlUsable("ftp://example.com", allowCleartext))
    }

    @Test
    fun theHostIsWhatGetsCheckedForCleartext() {
        var asked: String? = null
        PairingActivity.pairingUrlUsable("http://192.168.1.112:4000/x") { h ->
            asked = h
            true
        }
        assertEquals("192.168.1.112", asked)
    }

    @Test
    fun parsePairingStillSplitsTheUrlWithItsColons() {
        val parsed = PairingActivity.parsePairing("fcpair:id1:tok1:http://192.168.1.112:4000")
        assertEquals("http://192.168.1.112:4000", parsed?.third)
        assertNull(PairingActivity.parsePairing("fcqa:abc"))
    }
}
