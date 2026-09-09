package com.fullcircle.qrgate

import org.junit.Assert.assertEquals
import org.junit.Test

class LinkStatusTest {
    @Test
    fun noContentOrOkMeansConnected() {
        assertEquals(LinkStatus.CONNECTED, LinkStatus.fromHttp(204))
        assertEquals(LinkStatus.CONNECTED, LinkStatus.fromHttp(200))
    }

    @Test
    fun unauthorizedMeansRevoked() {
        assertEquals(LinkStatus.REVOKED, LinkStatus.fromHttp(401))
    }

    @Test
    fun anythingElseOrANetworkFailureMeansDisconnected() {
        assertEquals(LinkStatus.DISCONNECTED, LinkStatus.fromHttp(500))
        assertEquals(LinkStatus.DISCONNECTED, LinkStatus.fromHttp(404))
        assertEquals(LinkStatus.DISCONNECTED, LinkStatus.fromNetworkError())
    }
}
