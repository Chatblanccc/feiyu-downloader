package io.feather.videodownloader.android

import android.app.Application
import androidx.lifecycle.*
import io.feather.videodownloader.android.core.*
import io.feather.videodownloader.android.data.*
import io.feather.videodownloader.android.download.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import java.util.UUID

class MainViewModel(application: Application):AndroidViewModel(application) {
    private val app=application as FeiyuApp
    private val dao=app.database.tasks()
    val tasks=dao.observe().stateIn(viewModelScope,SharingStarted.WhileSubscribed(5000),emptyList())
    val allowMobile=app.settings.allowMobile.stateIn(viewModelScope,SharingStarted.WhileSubscribed(5000),false)
    val text=MutableStateFlow("");val quality=MutableStateFlow(Quality.BEST);val authentication=MutableStateFlow("none")
    val preview=MutableStateFlow<MediaInfo?>(null);val busy=MutableStateFlow(false);val ready=MutableStateFlow(false)
    val message=MutableStateFlow<String?>(null);val tab=MutableStateFlow(0)
    private var previewJob: Job?=null
    init {
        viewModelScope.launch { try{if(!DownloadService.running)MediaPublisher(app,dao).recover();ready.value=true}catch(_:Exception){message.value="无法读取任务记录，请检查手机剩余空间后重新打开应用。"} }
        viewModelScope.launch { app.downloadNotice.filterNotNull().collect{message.value=it} }
    }
    fun setInput(value:String){text.value=value;preview.value=null;previewJob?.cancel()}
    fun inspect(){
        previewJob?.cancel()
        previewJob=viewModelScope.launch {
            val id="preview-${UUID.randomUUID()}";busy.value=true;preview.value=null;message.value=null
            try {
                val url=ShareLinks.parse(text.value).firstOrNull() ?: error("请粘贴视频链接或完整分享文案。")
                preview.value=app.engine.probe(id,url,authentication.value)
            } catch(e:CancellationException){throw e}
            catch(e:Exception){message.value=readableError(e.message ?: "解析失败")}
            finally{withContext(NonCancellable+Dispatchers.IO){app.engine.cancel(id);app.engine.cleanup(id)};busy.value=false}
        }
    }
    fun enqueue(){viewModelScope.launch {
        if(!ready.value)return@launch
        message.value=null
        try {
            val urls=ShareLinks.parse(text.value);check(urls.isNotEmpty()){"请先粘贴视频链接或分享文案。"}
            val existing=dao.all().filter{it.status.active || it.status==TaskState.QUEUED}.map{it.source}.toSet()
            val added=urls.filterNot{it in existing}.map { DownloadTask(source=it,quality=quality.value.name,authentication=authentication.value) }
            check(added.isNotEmpty()){"这些链接已在任务列表中。"}
            added.forEach { dao.put(it) }
            try { DownloadService.start(app) } catch(e:Exception){added.forEach{dao.put(it.copy(state=TaskState.INTERRUPTED.name,error="无法启动后台任务，请回到应用后重试。"))};throw e}
            previewJob?.cancel();text.value="";preview.value=null;tab.value=1
        } catch(e:Exception){message.value=readableError(e.message ?: "无法添加任务")}
    } }
    fun retry(task:DownloadTask){viewModelScope.launch {
        if(task.status.active || task.status==TaskState.QUEUED)return@launch
        dao.put(task.copy(state=TaskState.QUEUED.name,error=null,outputUri=null,pendingUri=null,bytes=0,total=null,speed=null,eta=null))
        runCatching{DownloadService.start(app,task.id)}.onFailure{dao.put(task.copy(state=TaskState.INTERRUPTED.name,error="请在应用前台重试。"))}
    }}
    fun cancel(task:DownloadTask){DownloadService.cancel(app,task.id)}
    fun remove(task:DownloadTask){viewModelScope.launch{if(!task.status.active && task.status!=TaskState.QUEUED){dao.remove(task.id);withContext(Dispatchers.IO){app.engine.cleanup(task.id)}}}}
    fun mobile(value:Boolean){viewModelScope.launch{app.settings.setMobile(value)}}
    override fun onCleared(){previewJob?.cancel();super.onCleared()}
}
