package com.fullcircle.qrgate.data

import androidx.room.Dao
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.Query

@Dao
interface PunchDao {
    @Query("SELECT * FROM punches ORDER BY punchedAtIso ASC")
    suspend fun all(): List<PunchEntity>

    @Insert(onConflict = OnConflictStrategy.ABORT)
    suspend fun insert(row: PunchEntity)

    @Query("DELETE FROM punches WHERE clientId = :clientId")
    suspend fun delete(clientId: String)

    @Query("DELETE FROM punches")
    suspend fun deleteAll()

    @Query("UPDATE punches SET tries = :tries, lastError = :lastError WHERE clientId = :clientId")
    suspend fun markAttempt(clientId: String, tries: Int, lastError: String?)
}
