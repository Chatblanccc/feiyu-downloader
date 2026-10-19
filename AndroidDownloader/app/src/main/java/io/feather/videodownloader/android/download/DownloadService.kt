package io.feather.videodownloader.android.download

import android.app.*
import android.content.*
import android.content.pm.ServiceInfo
import android.net.*
import android.os.*
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import io.feather.videodownloader.android.*
import io.feather.videodownloader.android.core.*
import io.feather.videodownloader.android.data.*
import kotlinx.coroutines.*
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.first

class DownloadService : Service() {
    private val scope=CoroutineScope(SupervisorJob()+Dispatchers.Main.immediate+CoroutineExceptionHandler{_,error->
        fatalPersistenceError=true
        app.downloadNotice.value=if(error is android.database.sqlite.SQLiteException)"无法保存任务记录，请检查手机剩余空间后重新打开应用。" else "后台下载已中断，请重新打开应用后重试。"
        app.engine.cancelAll();stopForeground(STOP_FOREGROUND_REMOVE);stopSelf()
    })
    private val app get()=application as FeiyuApp
    private val dao get()=app.database.tasks()
    private var worker: Job?=null
    private var taskJob: Job?=null
    private var current: DownloadTask?=null
    private var generation=0
    private var stoppedReason: String?=null
    private val cancelledIds=mutableSetOf<String>()
    private var fatalPersistenceError=false
    override fun onBind(intent: Intent?) = null
    override fun onCreate() {
        super.onCreate()
        running=true
        getSystemService(NotificationManager::class.java).createNotificationChannel(NotificationChannel(CHANNEL,"下载任务",NotificationManager.IMPORTANCE_LOW))
        foreground("准备下载",false)
    }
    private fun foreground(message: String, processing: Boolean) {
        val open=PendingIntent.getActivity(this,0,Intent(this,MainActivity::class.java),PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val builder=NotificationCompat.Builder(this,CHANNEL).setSmallIcon(android.R.drawable.stat_sys_download)
            .setContentTitle("飞羽下载").setContentText(message).setContentIntent(open).setOngoing(true).setOnlyAlertOnce(true)
        current?.let { task ->
            val cancel=PendingIntent.getService(this,task.id.hashCode(),Intent(this,DownloadService::class.java).setAction(CANCEL).putExtra("id",task.id),PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
            builder.addAction(android.R.drawable.ic_delete,"取消",cancel)
        }
        val type=if(Build.VERSION.SDK_INT>=35 && processing)ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROCESSING else ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
        // minSdk 29 supports the typed platform overload. Older ServiceCompat
        // releases mask out mediaProcessing and can accidentally pass type NONE.
        startForeground(NOTIFICATION,builder.build(),type)
    }
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        generation++
        intent?.getStringExtra("retryId")?.let{cancelledIds.remove(it)}
        if(intent?.action==CANCEL) {
            val id=intent.getStringExtra("id")
            if(id!=null)cancelledIds.add(id)
            if(id==current?.id) { stoppedReason=null; taskJob?.cancel(); if(id!=null)app.engine.cancel(id) }
            else if(id!=null) scope.launch { dao.get(id)?.let { if(it.status==TaskState.QUEUED)dao.put(it.copy(state=TaskState.CANCELLED.name)) } }
        }
        if(worker?.isActive!=true) worker=scope.launch {
            while(isActive) {
                val observed=generation
                val queued=dao.all().filter{it.status==TaskState.QUEUED}
                queued.filter{it.id in cancelledIds}.forEach{dao.put(it.copy(state=TaskState.CANCELLED.name))}
                val next=queued.firstOrNull{it.id !in cancelledIds}
                if(next==null) {
                    if(observed!=generation)continue
                    current=null;worker=null;stopForeground(STOP_FOREGROUND_REMOVE);stopSelf();break
                }
                current=next;stoppedReason=null
                taskJob=launch { execute(next) };taskJob?.join();taskJob=null
                if(fatalPersistenceError)break
            }
        }
        return START_NOT_STICKY
    }
    private suspend fun execute(task: DownloadTask) {
        val cm=getSystemService(ConnectivityManager::class.java)
        val allowMobile=app.settings.allowMobile.first()
        fun eligible(): Boolean {
            val c=cm.getNetworkCapabilities(cm.activeNetwork) ?: return false
            return c.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) &&
                (allowMobile || (!cm.isActiveNetworkMetered && !c.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR)))
        }
        var record=task.copy(state=TaskState.RESOLVING.name,error=null,bytes=0,total=null,speed=null,eta=null)
        val updates=Channel<Progress>(Channel.CONFLATED)
        var updater: Job?=null;var networkWatch:Job?=null
        val wake=getSystemService(PowerManager::class.java).newWakeLock(PowerManager.PARTIAL_WAKE_LOCK,"Feiyu:download")
        try {
            check(eligible()){if(allowMobile)"当前没有可用网络，请联网后重试。" else "当前网络不可用于下载，请连接 Wi-Fi，或在设置中允许移动网络。"}
            dao.put(record);foreground("正在解析视频",false)
            wake.acquire(2*60*60*1000L)
            val owner=currentCoroutineContext()[Job]!!
            networkWatch=scope.launch {
                while(isActive){delay(1000);if(!eligible()){stoppedReason="网络已断开或切换到受限网络，请检查后手动重试。";owner.cancel();app.engine.cancel(task.id);break}}
            }
            val info=app.engine.probe(task.id,task.source,task.authentication)
            record=record.copy(title=info.title,state=TaskState.DOWNLOADING.name);dao.put(record)
            updater=scope.launch {
                var previous=0L
                for(p in updates) {
                    val now=SystemClock.elapsedRealtime();if(now-previous<400 && !p.processing)continue;previous=now
                    record=record.copy(state=(if(p.processing)TaskState.PROCESSING else TaskState.DOWNLOADING).name,bytes=p.bytes,total=p.total,speed=p.speed,eta=p.eta,updatedAt=System.currentTimeMillis())
                    dao.put(record)
                    foreground("${record.status.label} · ${record.title.take(45)}" + (p.fraction?.let{" · ${(it*100).toInt()}%"} ?: ""),p.processing)
                }
            }
            val file=app.engine.download(task.id,task.source,Quality.valueOf(task.quality),task.authentication,info){updates.trySend(it)}
            updates.close();updater.join();updater=null
            record=record.copy(state=TaskState.SAVING.name);dao.put(record);foreground("保存至系统媒体库",true)
            MediaPublisher(this,dao).publish(record,file)
        } catch(e: Throwable) {
            updates.close();updater?.cancelAndJoin()
            withContext(NonCancellable) {
                if(dao.get(task.id)?.status!=TaskState.COMPLETED) {
                    val cancelled=e is CancellationException
                    dao.put(record.copy(state=(if(stoppedReason!=null)TaskState.INTERRUPTED else if(cancelled)TaskState.CANCELLED else TaskState.FAILED).name,
                        pendingUri=null,error=stoppedReason ?: if(cancelled)null else readableError(e.message ?: "下载失败"),speed=null,eta=null,updatedAt=System.currentTimeMillis()))
                }
            }
        } finally {
            networkWatch?.cancel();updates.close();updater?.cancel()
            withContext(NonCancellable+Dispatchers.IO){app.engine.cancel(task.id);app.engine.cleanup(task.id)}
            if(wake.isHeld)wake.release()
        }
    }
    override fun onTimeout(startId: Int, fgsType: Int) {
        stoppedReason="已达到系统后台处理时限，请回到应用后手动重试。"
        taskJob?.cancel();app.engine.cancelAll();stopForeground(STOP_FOREGROUND_REMOVE);stopSelf()
    }
    override fun onDestroy() { running=false;taskJob?.cancel();scope.cancel();app.engine.cancelAll();super.onDestroy() }
    companion object {
        @Volatile var running=false
        const val CHANNEL="feiyu_downloads";const val NOTIFICATION=41;const val CANCEL="feiyu.cancel"
        fun start(context: Context,retryId:String?=null){androidx.core.content.ContextCompat.startForegroundService(context,Intent(context,DownloadService::class.java).putExtra("retryId",retryId))}
        fun cancel(context: Context,id: String){context.startService(Intent(context,DownloadService::class.java).setAction(CANCEL).putExtra("id",id))}
    }
}
