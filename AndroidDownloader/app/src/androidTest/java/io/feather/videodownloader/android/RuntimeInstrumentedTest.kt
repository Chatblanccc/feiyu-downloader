package io.feather.videodownloader.android

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import io.feather.videodownloader.android.download.*
import io.feather.videodownloader.android.core.*
import io.feather.videodownloader.android.data.DownloadTask
import kotlinx.coroutines.*
import org.junit.*
import org.junit.Assert.*
import org.junit.runner.RunWith
import java.io.File
import java.util.UUID

@RunWith(AndroidJUnit4::class)
class RuntimeInstrumentedTest {
    private val context get()=InstrumentationRegistry.getInstrumentation().targetContext
    @Test fun bundledPythonQuickJsAndYtDlpStart(): Unit=runBlocking {
        val runtime=NativeRuntime(context)
        val result=runtime.run("version",listOf("--version"),context.cacheDir,true)
        assertTrue(result,result.contains("2026.08.19"))
        val qjs=runtime.run("quickjs",listOf("-e","console.log(6*7)"),context.cacheDir,true,"libqjs.so")
        assertTrue(qjs,qjs.contains("42"))
    }
    @Test fun ffmpegLoadsAndHasRequiredMuxers(): Unit=runBlocking {
        val runtime=NativeRuntime(context)
        val result=runtime.run("ffmpeg",listOf("-hide_banner","-muxers"),context.cacheDir,true,"libffmpeg.so")
        assertTrue(result,result.contains("mp4"));assertTrue(result.contains("matroska"))
    }
    @Test fun htmlChallengeCannotBeAcceptedAsCompletedVideo():Unit=runBlocking {
        val file=File(context.cacheDir,"challenge-${UUID.randomUUID()}.mp4")
        file.writeText("<!doctype html><title>Verify your access</title>")
        try {
            val failure=runCatching{(context.applicationContext as FeiyuApp).engine.verifyMedia("invalid-media",file,false)}.exceptionOrNull()
            assertNotNull("An HTTP 200 challenge document must not become a completed video",failure)
        }finally{file.delete()}
    }
    @Test fun cancellationReapsTenIndependentProcessGroups(): Unit=runBlocking {
        val runtime=NativeRuntime(context)
        repeat(10){n->
            val work=async(Dispatchers.IO){runtime.run("cancel-$n",listOf("-c","import subprocess,time; subprocess.Popen(['sleep','120']); time.sleep(120)"),context.cacheDir,true,"libpython.so")}
            withTimeout(15000){while(runtime.activeProcessGroups().isEmpty())delay(50)}
            delay(200)
            val groups=runtime.activeProcessGroups();assertTrue(groups.isNotEmpty());work.cancelAndJoin()
            withTimeout(5000){while(groups.any{pid->runCatching{android.system.Os.kill(-pid,0);true}.getOrDefault(false)})delay(50)}
            assertTrue(runtime.activeProcessGroups().isEmpty())
        }
    }
    @Test fun actualLocalMediaPublishesAndRecovers(): Unit=runBlocking {
        val app=context.applicationContext as FeiyuApp;val dao=app.database.tasks()
        val file=File(context.cacheDir,"test-${UUID.randomUUID()}.mp4")
        NativeRuntime(context).run("fixture",listOf("-y","-f","lavfi","-i","color=c=blue:s=320x240:r=24","-f","lavfi","-i","sine=frequency=440:sample_rate=44100","-t","2","-c:v","mpeg4","-q:v","5","-c:a","aac","-movflags","+faststart",file.path),context.cacheDir,true,"libffmpeg.so")
        val task=DownloadTask(source="https://example.test/feiyu",title="本地验收样片",state=TaskState.SAVING.name)
        dao.put(task)
        try {
            val completed=MediaPublisher(context,dao).publish(task,file)
            assertEquals(TaskState.COMPLETED,completed.status)
            val uri=android.net.Uri.parse(completed.outputUri)
            val retriever=android.media.MediaMetadataRetriever()
            try{retriever.setDataSource(context,uri);assertTrue(retriever.extractMetadata(android.media.MediaMetadataRetriever.METADATA_KEY_DURATION)!!.toLong()>=1900)}finally{retriever.release()}
            val recovery=completed.copy(state=TaskState.SAVING.name,pendingUri=completed.outputUri,outputUri=null)
            dao.put(recovery);MediaPublisher(context,dao).recover();assertEquals(TaskState.COMPLETED,dao.get(task.id)!!.status)
            dao.remove(task.id);assertNotNull(context.contentResolver.openAssetFileDescriptor(uri,"r")?.use{it.length})
            context.contentResolver.delete(uri,null,null)
        }finally{file.delete();dao.remove(task.id)}
    }
}
