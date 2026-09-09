package com.fullcircle.qrgate

enum class LinkStatus {
    CONNECTED,
    DISCONNECTED,
    REVOKED,
    ;

    companion object {
        fun fromHttp(code: Int): LinkStatus =
            when (code) {
                200, 204 -> CONNECTED
                401 -> REVOKED
                else -> DISCONNECTED
            }

        fun fromNetworkError(): LinkStatus = DISCONNECTED
    }
}
