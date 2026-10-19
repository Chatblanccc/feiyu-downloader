package io.feather.videodownloader.android.data

import android.content.Context
import androidx.datastore.preferences.core.booleanPreferencesKey
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.preferencesDataStore
import androidx.room.*
import io.feather.videodownloader.android.core.*
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.map
import java.util.UUID

@Entity(tableName = "tasks")
data class DownloadTask(
    @PrimaryKey val id: String = UUID.randomUUID().toString(), val source: String,
    val title: String = "等待解析", val quality: String = Quality.BEST.name, val authentication: String = "none",
    val state: String = TaskState.QUEUED.name, val bytes: Long = 0, val total: Long? = null,
    val speed: Double? = null, val eta: Long? = null, val outputUri: String? = null, val pendingUri: String? = null,
    val error: String? = null, val createdAt: Long = System.currentTimeMillis(), val updatedAt: Long = System.currentTimeMillis()
) { @get:Ignore val status get() = TaskState.valueOf(state) }
@Dao interface TaskDao {
    @Query("SELECT * FROM tasks ORDER BY createdAt DESC") fun observe(): Flow<List<DownloadTask>>
    @Query("SELECT * FROM tasks ORDER BY createdAt") suspend fun all(): List<DownloadTask>
    @Query("SELECT * FROM tasks WHERE id=:id") suspend fun get(id: String): DownloadTask?
    @Insert(onConflict = OnConflictStrategy.REPLACE) suspend fun put(task: DownloadTask)
    @Query("DELETE FROM tasks WHERE id=:id") suspend fun remove(id: String)
}
@Database(entities = [DownloadTask::class], version = 1, exportSchema = true)
abstract class TaskDatabase : RoomDatabase() {
    abstract fun tasks(): TaskDao
    companion object { fun open(context: Context) = Room.databaseBuilder(context, TaskDatabase::class.java, "feiyu.db").build() }
}
private val Context.settingsStore by preferencesDataStore("settings")
class Settings(private val context: Context) {
    private val mobile = booleanPreferencesKey("mobile_data")
    val allowMobile = context.settingsStore.data.map { it[mobile] ?: false }
    suspend fun setMobile(value: Boolean) { context.settingsStore.edit { it[mobile] = value } }
}
