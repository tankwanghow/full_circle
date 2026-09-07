package com.fullcircle.qrgate.data

import androidx.room.Entity
import androidx.room.PrimaryKey

@Entity(tableName = "punches")
data class PunchEntity(
    @PrimaryKey val clientId: String,
    val employeeId: String,
    val punchedAtIso: String,
    val photoPath: String,
    val tries: Int = 0,
    val lastError: String? = null,
)
