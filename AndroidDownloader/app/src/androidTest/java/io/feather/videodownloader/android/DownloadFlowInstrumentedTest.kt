package io.feather.videodownloader.android

import android.content.Intent
import android.media.MediaMetadataRetriever
import android.net.Uri
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import io.feather.videodownloader.android.core.*
import io.feather.videodownloader.android.data.DownloadTask
import io.feather.videodownloader.android.download.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.first
import org.json.JSONObject
import org.junit.*
import org.junit.Assert.*
import org.junit.runner.RunWith
import java.io.File
import java.net.ServerSocket
import java.util.UUID

@RunWith(AndroidJUnit4::class)
class DownloadFlowInstrumentedTest {
    @Test fun auditInstalledStateWhenRequested():Unit=runBlocking {
        Assume.assumeTrue(InstrumentationRegistry.getArguments().getString("auditState")=="true")
        val context=InstrumentationRegistry.getInstrumentation().targetContext
        val app=context.applicationContext as FeiyuApp
        val tasks=app.database.tasks().all()
        val available=tasks.filter{it.status==TaskState.COMPLETED}.count{task->runCatching{context.contentResolver.openAssetFileDescriptor(Uri.parse(task.outputUri),"r")?.use{it.length>0}==true}.getOrDefault(false)}
        val detailed=InstrumentationRegistry.getArguments().getString("auditMediaDetails")=="true"
        val details=tasks.map{task->
            val row=JSONObject().put("id",task.id).put("state",task.state).put("bytes",task.bytes).put("uri",task.outputUri)
            val readable=runCatching{context.contentResolver.openAssetFileDescriptor(Uri.parse(task.outputUri),"r")?.use{it.length>0}==true}.getOrDefault(false)
            row.put("readableMedia",readable)
            if(detailed && readable) {
                val uri=Uri.parse(task.outputUri);val retriever=MediaMetadataRetriever()
                try{retriever.setDataSource(context,uri);row.put("width",retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)?.toIntOrNull());row.put("height",retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)?.toIntOrNull());row.put("durationMs",retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull())}finally{retriever.release()}
                val digest=java.security.MessageDigest.getInstance("SHA-256")
                context.contentResolver.openInputStream(uri)!!.use{input->val buffer=ByteArray(65536);while(true){val n=input.read(buffer);if(n<0)break;digest.update(buffer,0,n)}}
                row.put("sha256",digest.digest().joinToString(""){"%02x".format(it)})
            }
            row
        }
        val result=JSONObject().put("versionCode",context.packageManager.getPackageInfo(context.packageName,0).longVersionCode)
            .put("taskIds",org.json.JSONArray(tasks.map{it.id})).put("completed",tasks.count{it.status==TaskState.COMPLETED}).put("mediaAvailable",available)
            .put("allowMobile",app.settings.allowMobile.first())
            .put("taskDetails",org.json.JSONArray(details))
        println("FEIYU_UPGRADE_STATE "+result)
        InstrumentationRegistry.getInstrumentation().sendStatus(0,android.os.Bundle().apply{putString("stream","\nFEIYU_UPGRADE_STATE $result\n")})
    }
    @Test fun foregroundDownloadPublishesPlayableAudioAndVideo():Unit=runBlocking {
        val instrumentation=InstrumentationRegistry.getInstrumentation()
        val context=instrumentation.targetContext;val app=context.applicationContext as FeiyuApp
        val file=File(context.cacheDir,"fixture-${UUID.randomUUID()}.mp4")
        app.engine.runtime.run("flow-fixture",listOf("-y","-f","lavfi","-i","color=c=blue:s=320x240:r=24","-f","lavfi","-i","sine=frequency=440:sample_rate=44100","-t","2","-c:v","mpeg4","-q:v","5","-c:a","aac","-movflags","+faststart",file.path),context.cacheDir,true,"libffmpeg.so")
        val bytes=file.readBytes();val server=ServerSocket(0,10,java.net.InetAddress.getByName("127.0.0.1"))
        val thread=Thread {
            while(!server.isClosed)try{server.accept().use{socket->
                socket.soTimeout=5000;val reader=socket.getInputStream().bufferedReader()
                val request=reader.readLine() ?: return@use
                while(true){val line=reader.readLine() ?: break;if(line.isBlank())break}
                val out=socket.getOutputStream()
                out.write("HTTP/1.1 200 OK\r\nContent-Type: video/mp4\r\nContent-Length: ${bytes.size}\r\nConnection: close\r\n\r\n".toByteArray())
                if(!request.startsWith("HEAD "))out.write(bytes);out.flush()
            }}catch(_:Exception){}
        }.apply{isDaemon=true;start()}
        instrumentation.runOnMainSync{context.startActivity(Intent(context,MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))}
        instrumentation.waitForIdleSync();delay(500)
        val task=DownloadTask(source="http://127.0.0.1:${server.localPort}/feiyu-fixture.mp4",title="本地下载验收",quality=Quality.BEST.name)
        val dao=app.database.tasks();dao.put(task)
        try {
            instrumentation.runOnMainSync{DownloadService.start(context)}
            val result=withTimeout(90000){var item=dao.get(task.id)!!;while(item.status in listOf(TaskState.QUEUED,TaskState.RESOLVING,TaskState.DOWNLOADING,TaskState.PROCESSING,TaskState.SAVING)){delay(250);item=dao.get(task.id)!!};item}
            assertEquals(result.error,TaskState.COMPLETED,result.status)
            val uri=Uri.parse(result.outputUri);val media=MediaMetadataRetriever()
            try{media.setDataSource(context,uri);assertEquals("yes",media.extractMetadata(MediaMetadataRetriever.METADATA_KEY_HAS_AUDIO));assertEquals("yes",media.extractMetadata(MediaMetadataRetriever.METADATA_KEY_HAS_VIDEO));assertTrue(media.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)!!.toLong()>=1900)}finally{media.release()}
            assertTrue(result.bytes>0)
            val audioTask=DownloadTask(source=task.source,title="音频导出验收",quality=Quality.AUDIO.name)
            dao.put(audioTask);instrumentation.runOnMainSync{DownloadService.start(context)}
            val audio=withTimeout(45000){var item=dao.get(audioTask.id)!!;while(item.status.active || item.status==TaskState.QUEUED){delay(250);item=dao.get(audioTask.id)!!};item}
            assertEquals(audio.error,TaskState.COMPLETED,audio.status)
            assertTrue(context.contentResolver.getType(Uri.parse(audio.outputUri))!!.startsWith("audio/"))
            // Keep one synthetic completed task on the emulator for UI and overlay-install inspection.
        }finally{server.close();thread.join(1000);file.delete()}
    }
    @Test fun realSiteDownloadWhenUrlSupplied():Unit=runBlocking {
        val args=InstrumentationRegistry.getArguments();val source=args.getString("siteUrl")
        Assume.assumeTrue("A public site URL must be explicitly provided",!source.isNullOrBlank())
        val context=InstrumentationRegistry.getInstrumentation().targetContext
        val app=context.applicationContext as FeiyuApp
        val engine=app.engine;val id="site-${UUID.randomUUID()}"
        try {
            val info=engine.probe(id,source!!,"none")
            val file=engine.download(id,source,Quality.valueOf(args.getString("quality") ?: "P720"),"none",info){ }
            val probe=engine.runtime.run("probe-$id",listOf("-v","quiet","-show_entries","format=duration:stream=codec_type,codec_name,width,height","-of","json",file.path),context.cacheDir,true,"libffprobe.so")
            val json=JSONObject(probe)
            assertTrue(json.getJSONObject("format").getDouble("duration")>0)
            val streams=json.getJSONArray("streams");assertTrue((0 until streams.length()).any{streams.getJSONObject(it).optString("codec_type")=="video"})
            assertTrue((0 until streams.length()).any{streams.getJSONObject(it).optString("codec_type")=="audio"})
            val duration=json.getJSONObject("format").getDouble("duration")
            // Decode samples from the beginning, middle and end of the actual
            // result, including audio. A metadata-only response cannot pass.
            for((index,offset) in listOf(0.0,duration/2,(duration-1).coerceAtLeast(0.0)).withIndex())
                engine.runtime.run("decode-$id-$index",listOf("-v","error","-ss",offset.toString(),"-i",file.path,"-t","1","-f","null","-"),context.cacheDir,true,"libffmpeg.so")
            var savedUri:String?=null
            if(args.getString("retainMedia")=="true") {
                val task=DownloadTask(id=id,source=source,title=info.title,quality=args.getString("quality") ?: "P720",state=TaskState.SAVING.name)
                app.database.tasks().put(task)
                val saved=MediaPublisher(context,app.database.tasks()).publish(task,file)
                assertEquals(TaskState.COMPLETED,saved.status)
                savedUri=saved.outputUri
                val retriever=MediaMetadataRetriever()
                try {retriever.setDataSource(context,Uri.parse(savedUri));assertEquals("yes",retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_HAS_VIDEO));assertEquals("yes",retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_HAS_AUDIO));assertTrue(retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)!!.toLong()>0)}finally{retriever.release()}
            }
            val formats=JSONObject(info.raw!!).optJSONArray("formats") ?: org.json.JSONArray()
            val splitOnly=(0 until formats.length()).all{val f=formats.getJSONObject(it);f.optString("vcodec")=="none" || f.optString("acodec")=="none"}
            val result=JSONObject().put("site",Site.from(source)?.label).put("id",info.id).put("source",source).put("quality",args.getString("quality") ?: "P720").put("title",info.title).put("extractor",JSONObject(info.raw!!).optString("extractor")).put("bytes",file.length()).put("sha256",NativeRuntime.sha256(file)).put("uri",savedUri).put("decodedSamples",3).put("splitOnlySource",splitOnly).put("shortEdges",org.json.JSONArray(info.heights)).put("media",json)
            println("FEIYU_SITE_RESULT "+result)
            InstrumentationRegistry.getInstrumentation().sendStatus(0,android.os.Bundle().apply{putString("stream","\nFEIYU_SITE_RESULT $result\n")})
        } finally{engine.cancel(id);engine.cleanup(id)}
    }
}
