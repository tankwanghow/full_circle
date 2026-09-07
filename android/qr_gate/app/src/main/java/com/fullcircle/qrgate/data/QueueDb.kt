package com.fullcircle.qrgate.data

import android.content.Context
import androidx.room.Database
import androidx.room.Room
import androidx.room.RoomDatabase
import com.fullcircle.qrgate.Prefs
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.io.File

@Database(entities = [PunchEntity::class], version = 1, exportSchema = false)
abstract class QueueDb : RoomDatabase() {
    abstract fun punchDao(): PunchDao

    companion object {
        @Volatile
        private var INSTANCE: QueueDb? = null

        val mutex = Mutex()

        fun photosDir(context: Context): File =
            File(context.applicationContext.filesDir, "punch_photos")

        fun get(context: Context): QueueDb {
            return INSTANCE ?: synchronized(this) {
                INSTANCE ?: Room.databaseBuilder(
                    context.applicationContext,
                    QueueDb::class.java,
                    "punch_queue.db",
                ).build().also { INSTANCE = it }
            }
        }

        suspend fun insertIfPaired(context: Context, row: PunchEntity): Boolean {
            mutex.withLock {
                if (Prefs(context).token.isEmpty()) return false
                get(context).punchDao().insert(row)
                return true
            }
        }

        /** 401 / revoke: wipe table + photo files, then clear pairing. */
        suspend fun wipeBecauseRevoked(context: Context) {
            mutex.withLock {
                get(context).punchDao().deleteAll()
                photosDir(context).listFiles()?.forEach { it.delete() }
                Prefs(context).clear()
            }
        }
    }
}
