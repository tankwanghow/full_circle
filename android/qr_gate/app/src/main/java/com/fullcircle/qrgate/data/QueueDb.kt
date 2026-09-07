package com.fullcircle.qrgate.data

import android.content.Context
import androidx.room.Database
import androidx.room.Room
import androidx.room.RoomDatabase

@Database(entities = [PunchEntity::class], version = 1, exportSchema = false)
abstract class QueueDb : RoomDatabase() {
    abstract fun punchDao(): PunchDao

    companion object {
        @Volatile
        private var INSTANCE: QueueDb? = null

        fun get(context: Context): QueueDb {
            return INSTANCE ?: synchronized(this) {
                INSTANCE ?: Room.databaseBuilder(
                    context.applicationContext,
                    QueueDb::class.java,
                    "punch_queue.db",
                ).build().also { INSTANCE = it }
            }
        }
    }
}
