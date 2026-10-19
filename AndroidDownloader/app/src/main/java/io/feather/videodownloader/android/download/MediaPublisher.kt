package io.feather.videodownloader.android.download

import android.content.ContentValues
import android.content.Context
import android.net.Uri
import android.os.Environment
import android.provider.MediaStore
import android.webkit.MimeTypeMap
import io.feather.videodownloader.android.data.*
import io.feather.videodownloader.android.core.TaskState
import kotlinx.coroutines.*
import java.io.File

class MediaPublisher(private val context: Context, private val dao: TaskDao) {
    suspend fun publish(task: DownloadTask, file: File): DownloadTask = withContext(Dispatchers.IO) {
        val resolver=context.contentResolver
        val audio=task.quality=="AUDIO"
        val collection=if(audio)MediaStore.Audio.Media.EXTERNAL_CONTENT_URI else MediaStore.Video.Media.EXTERNAL_CONTENT_URI
        val mime=MimeTypeMap.getSingleton().getMimeTypeFromExtension(file.extension.lowercase()) ?: if(audio)"audio/mp4" else "video/mp4"
        val values=ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME,file.name)
            put(MediaStore.MediaColumns.MIME_TYPE,mime)
            put(MediaStore.MediaColumns.RELATIVE_PATH,(if(audio)Environment.DIRECTORY_MUSIC else Environment.DIRECTORY_MOVIES)+"/飞羽下载")
            put(MediaStore.MediaColumns.IS_PENDING,1)
        }
        val uri=requireNotNull(resolver.insert(collection,values)){"无法在系统媒体库创建文件。"}
        val saving=task.copy(state=TaskState.SAVING.name,pendingUri=uri.toString(),bytes=file.length(),total=file.length(),error=null)
        try {
            dao.put(saving)
            resolver.openOutputStream(uri,"w")!!.use { output -> file.inputStream().use { input ->
                val buffer=ByteArray(262144);while(true){ensureActive();val n=input.read(buffer);if(n<0)break;output.write(buffer,0,n)}
            } }
            val length=resolver.openAssetFileDescriptor(uri,"r")!!.use { it.length }
            check(length==file.length() && length>0){"公共文件保存不完整，请重试。"}
            ensureActive()
            check(resolver.update(uri,ContentValues().apply{put(MediaStore.MediaColumns.IS_PENDING,0)},null,null)==1){"无法完成媒体库保存。"}
            // Once published, commit completion even if the UI cancels at this exact boundary.
            withContext(NonCancellable) {
                saving.copy(state=TaskState.COMPLETED.name,outputUri=uri.toString(),pendingUri=null,bytes=length,total=length,speed=null,eta=null,updatedAt=System.currentTimeMillis()).also { dao.put(it) }
            }
        } catch(e: Throwable) {
            withContext(NonCancellable) { runCatching { resolver.delete(uri,null,null) } }; throw e
        }
    }
    suspend fun recover() = withContext(Dispatchers.IO) {
        dao.all().forEach { task ->
            if(task.pendingUri!=null) {
                val uri=Uri.parse(task.pendingUri)
                val published=runCatching { context.contentResolver.query(uri,arrayOf(MediaStore.MediaColumns.IS_PENDING,MediaStore.MediaColumns.SIZE),null,null,null)?.use { c->c.moveToFirst() && c.getInt(0)==0 && c.getLong(1)>0 && c.getLong(1)==task.total }==true }.getOrDefault(false)
                if(published) dao.put(task.copy(state=TaskState.COMPLETED.name,outputUri=task.pendingUri,pendingUri=null,error=null))
                else { runCatching{context.contentResolver.delete(uri,null,null)};dao.put(task.copy(state=TaskState.INTERRUPTED.name,pendingUri=null,error="上次保存未完成，请手动重试。")) }
            } else if(task.status.active || task.status==TaskState.QUEUED) {
                dao.put(task.copy(state=TaskState.INTERRUPTED.name,error="上次任务已中断，请手动重试。"))
            }
        }
    }
}
