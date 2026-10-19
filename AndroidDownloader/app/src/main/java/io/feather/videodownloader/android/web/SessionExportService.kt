package io.feather.videodownloader.android.web

import android.app.Service
import android.content.*
import android.os.*
import android.webkit.CookieManager
import io.feather.videodownloader.android.core.Site
import kotlinx.coroutines.*
import java.io.File
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/** Private IPC reads only the explicitly selected site's session. It never opens an Activity from the background. */
class SessionExportService:Service(){
    private val messenger=Messenger(Handler(Looper.getMainLooper()){message->
        val response=Bundle()
        try {
            val site=Site.valueOf(message.data.getString("site") ?: "")
            val name=requireNotNull(message.data.getString("file"));check(name.matches(Regex("cookie-[a-zA-Z0-9-]+\\.txt")))
            val cookies=CookieManager.getInstance().getCookie("https://${site.domain}/") ?: error("请先在设置中打开${site.label}并完成登录。")
            // CookieManager exposes request headers, not a complete Netscape export.
            // Conservatively scope these session cookies to this exact host and '/'.
            val rows=cookies.split(';').mapNotNull { piece->
                val p=piece.trim().split('=',limit=2)
                if(p.size==2 && p[0].isNotBlank() && !piece.contains('\n') && !piece.contains('\t'))
                    "${site.domain}\tFALSE\t/\tTRUE\t0\t${p[0]}\t${p[1]}" else null
            };check(rows.isNotEmpty()){"没有可用网站会话。"}
            File(cacheDir,name).apply{writeText("# Netscape HTTP Cookie File\n"+rows.joinToString("\n")+"\n");setReadable(false,false);setWritable(false,false);setReadable(true,true);setWritable(true,true)}
            response.putBoolean("ok",true)
        }catch(e:Exception){response.putString("error",e.message)}
        runCatching{message.replyTo.send(Message.obtain(null,2).apply{data=response})};true
    })
    override fun onBind(intent:Intent)=messenger.binder
    companion object {
        suspend fun export(context:Context,site:Site,destination:File)=withContext(Dispatchers.Main){withTimeout(10000){suspendCancellableCoroutine<Unit>{continuation->
            var bound=false;lateinit var connection:ServiceConnection
            fun release(){if(bound){bound=false;runCatching{context.unbindService(connection)}}}
            val reply=Messenger(Handler(Looper.getMainLooper()){message->
                release()
                if(!continuation.isActive)destination.delete()
                else if(message.data.getBoolean("ok"))continuation.resume(Unit)
                else continuation.resumeWithException(IllegalStateException(message.data.getString("error") ?: "无法读取网站会话。"))
                true
            })
            connection=object:ServiceConnection {
                override fun onServiceConnected(name:ComponentName,binder:IBinder){
                    if(!continuation.isActive){release();return}
                    runCatching{Messenger(binder).send(Message.obtain(null,1).apply{data=Bundle().apply{putString("site",site.name);putString("file",destination.name)};replyTo=reply})}
                        .onFailure{release();if(continuation.isActive)continuation.resumeWithException(it)}
                }
                override fun onServiceDisconnected(name:ComponentName){release();if(continuation.isActive)continuation.resumeWithException(IllegalStateException("网站会话组件已退出。"))}
            }
            bound=context.bindService(Intent(context,SessionExportService::class.java),connection,Context.BIND_AUTO_CREATE)
            if(!bound)continuation.resumeWithException(IllegalStateException("无法读取网站会话。"))
            continuation.invokeOnCancellation{Handler(Looper.getMainLooper()).post{release();destination.delete()}}
        }}}
    }
}
