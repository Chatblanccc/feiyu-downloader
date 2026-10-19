// SPDX-License-Identifier: GPL-3.0-only
// Runtime layout adapted from yausername/youtubedl-android 0.18.1 (GPL-3.0).
// Feiyu changes: verified atomic extraction, read-only native files, bounded I/O,
// dedicated process groups, cancellation and resource deadlines. No online updater.
package io.feather.videodownloader.android.download

import android.content.Context
import android.system.Os
import android.system.OsConstants
import io.feather.videodownloader.android.BuildConfig
import io.feather.videodownloader.android.core.Progress
import kotlinx.coroutines.*
import org.json.JSONObject
import java.io.File
import java.io.ByteArrayOutputStream
import java.security.MessageDigest
import java.util.concurrent.*
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference
import java.util.zip.ZipInputStream

class NativeRuntime(private val context: Context) {
    private val root = File(context.noBackupFilesDir, "runtime-${BuildConfig.RUNTIME_VERSION}")
    private val native = File(context.applicationInfo.nativeLibraryDir)
    private val active = ConcurrentHashMap<String, Running>()
    private data class Running(val process: Process, @Volatile var group: Int = 0)
    @Synchronized fun prepare() {
        if (File(root, ".ready").isFile) return
        val stage = File(root.parentFile, root.name + ".preparing")
        stage.deleteRecursively(); stage.mkdirs()
        try {
            val manifest = JSONObject(context.assets.open("runtime/manifest.json").bufferedReader().use { it.readText() })
            val hashes = manifest.getJSONObject("files")
            hashes.keys().forEach { name ->
                val file = File(native, name)
                check(file.isFile && sha256(file) == hashes.getString(name)) { "下载运行时校验失败，请重新安装。" }
            }
            for ((archive, folder) in listOf("libpython.zip.so" to "python", "libffmpeg.zip.so" to "ffmpeg")) {
                val destination = File(stage, folder).apply { mkdirs() }
                val links=manifest.getJSONObject("symlinks").getJSONObject(folder)
                ZipInputStream(File(native, archive).inputStream().buffered()).use { zip ->
                    var total = 0L
                    while (true) {
                        val entry = zip.nextEntry ?: break
                        val file = File(destination, entry.name).canonicalFile
                        check(file.path.startsWith(destination.canonicalPath + File.separator)) { "运行时包含无效路径。" }
                        if (entry.isDirectory) { file.mkdirs(); continue }
                        if (links.has(entry.name)) continue
                        file.parentFile!!.mkdirs()
                        file.outputStream().use { output ->
                            val buffer = ByteArray(65536)
                            while (true) { val n = zip.read(buffer); if (n < 0) break
                                total += n; check(total <= 512L * 1024 * 1024) { "运行时解压大小异常。" }; output.write(buffer,0,n) }
                        }
                        file.setReadOnly()
                    }
                }
                links.keys().forEach { name ->
                    val file=File(destination,name)
                    val target=File(destination,links.getString(name)).canonicalFile
                    check(file.parentFile!!.canonicalPath.startsWith(destination.canonicalPath) && target.path.startsWith(destination.canonicalPath+File.separator)) { "运行时链接无效。" }
                    file.parentFile!!.mkdirs()
                    Os.symlink(target.relativeTo(file.parentFile!!.canonicalFile).path,file.path)
                }
                check(links.keys().asSequence().all { name -> File(destination,name).exists() }) { "运行时共享库链接无法解析。" }
            }
            context.assets.open("runtime/yt-dlp").use { input -> File(stage, "yt-dlp").outputStream().use { input.copyTo(it) } }
            check(sha256(File(stage,"yt-dlp")) == manifest.getString("ytDlpSha256")) { "解析组件校验失败。" }
            File(stage,"yt-dlp").setReadOnly()
            File(stage,".ready").writeText(BuildConfig.RUNTIME_VERSION)
            root.deleteRecursively(); check(stage.renameTo(root)) { "无法准备下载运行时。" }
            root.parentFile?.listFiles()?.filter{it.isDirectory && it.name.startsWith("runtime-") && it!=root && it!=stage}?.forEach{it.deleteRecursively()}
        } finally { stage.deleteRecursively() }
    }
    private fun environment(): Map<String,String> = mutableMapOf(
        "LD_LIBRARY_PATH" to "${root}/python/usr/lib:${root}/ffmpeg/usr/lib:${native}",
        "PYTHONHOME" to "$root/python/usr", "HOME" to root.path,
        "SSL_CERT_FILE" to "$root/python/usr/etc/tls/cert.pem", "TMPDIR" to context.cacheDir.path,
        "PYTHONDONTWRITEBYTECODE" to "1", "PYTHONUNBUFFERED" to "1"
    ).apply {
        // Respect a manually configured Android HTTP proxy; ordinary phone VPNs
        // continue to route traffic through Android without additional settings.
        val proxy=context.getSystemService(android.net.ConnectivityManager::class.java).defaultProxy
        if(proxy!=null && !proxy.host.isNullOrBlank() && proxy.port>0) {
            val url="http://${proxy.host}:${proxy.port}"
            put("HTTPS_PROXY",url);put("HTTP_PROXY",url);put("NO_PROXY","localhost,127.0.0.1")
        }
    }
    fun cancel(id: String) { active[id]?.let { terminate(it) } }
    fun cancelAll() { active.values.toList().forEach(::terminate) }
    fun activeProcessGroups(): List<Int> = active.values.map { it.group }.filter { it>1 }
    private fun terminate(running: Running) {
        if (running.group > 1) runCatching { Os.kill(-running.group, OsConstants.SIGTERM) }
        running.process.destroy()
        if (!running.process.waitFor(400, TimeUnit.MILLISECONDS)) {
            if (running.group > 1) runCatching { Os.kill(-running.group, OsConstants.SIGKILL) }
            running.process.destroyForcibly()
        }
        // A finished parent may still have living children.
        if (running.group > 1) runCatching { Os.kill(-running.group, OsConstants.SIGKILL) }
    }
    suspend fun run(id: String, arguments: List<String>, directory: File, metadata: Boolean = false,
                    tool: String? = null, onLine: (String) -> Unit = {}): String = withContext(Dispatchers.IO) {
        prepare(); ensureActive()
        val launcher = "import os,sys,runpy;os.setsid();print('__FEATHER_PID__'+str(os.getpid()),flush=True);p=sys.argv.pop(1);" +
            (if (tool == null) "sys.argv[0]=p;runpy.run_path(p,run_name='__main__')" else "os.execv(p,[p]+sys.argv[1:])")
        val executable = if (tool == null) File(root,"yt-dlp") else File(native,tool)
        val args = if (tool != null) arguments else listOf("--ignore-config", "--no-playlist", "--no-cache-dir", "--no-warnings",
            "--js-runtimes", "quickjs:${File(native,"libqjs.so")}", "--ffmpeg-location", File(native,"libffmpeg.so").path,
            "--socket-timeout", "20", "--retries", "2", "--fragment-retries", "2") + arguments
        val process = ProcessBuilder(listOf(File(native,"libpython.so").path,"-c",launcher,executable.path) + args)
            .directory(directory).apply { environment().putAll(this@NativeRuntime.environment()) }.start()
        val running = Running(process)
        check(active.putIfAbsent(id,running) == null) { "任务已在执行。" }
        val failure = AtomicReference<Throwable?>()
        val started = System.nanoTime(); val activity = AtomicLong(started); val lastBytes = AtomicLong(-1)
        val processing = AtomicLong(0); val pool = Executors.newFixedThreadPool(2)
        fun collect(stream: java.io.InputStream, stdout: Boolean): Future<String> = pool.submit<String> {
            val captured = StringBuilder(); val line = ByteArrayOutputStream()
            fun emit() {
                val s = line.toString("UTF-8"); line.reset()
                if (stdout && s.startsWith("__FEATHER_PID__")) { running.group = s.removePrefix("__FEATHER_PID__").trim().toInt(); return }
                Progress.parse(s)?.let { p ->
                    if (lastBytes.getAndSet(p.bytes) != p.bytes) activity.set(System.nanoTime())
                    if (p.processing) processing.compareAndSet(0,System.nanoTime())
                }
                if (stdout || s.startsWith(Progress.PREFIX)) onLine(s)
                if (metadata && stdout) { check(captured.length + s.length <= 8 * 1024 * 1024) { "网站返回的信息过大。" }; captured.append(s).append('\n') }
                else if (!stdout) { captured.append(s).append('\n'); if (captured.length > 32768) captured.delete(0,captured.length-32768) }
            }
            try {
                val buffer = ByteArray(8192)
                while (true) { val count = stream.read(buffer); if (count < 0) break
                    for (i in 0 until count) { val b = buffer[i]; if (b == 10.toByte() || b == 13.toByte()) { if (line.size()>0) emit() }
                        else { check(line.size() < if (metadata && stdout) 8*1024*1024 else 16384) { "组件输出超过限制。" }; line.write(b.toInt()) } }
                }; if (line.size()>0) emit()
                captured.toString()
            } catch (e: Throwable) { failure.compareAndSet(null,e); terminate(running); throw e }
        }
        val out = collect(process.inputStream,true); val err = collect(process.errorStream,false)
        fun dataBytes()=directory.walkTopDown().maxDepth(2).filter{it.isFile && it.name!="metadata.json"}.sumOf{it.length()}
        var previousDataBytes=dataBytes();var hasTransferred=false
        try {
            while (!process.waitFor(500,TimeUnit.MILLISECONDS)) {
                ensureActive(); failure.get()?.let { throw it }
                val now = System.nanoTime(); val elapsed = (now-started)/1_000_000_000
                check(elapsed < if (metadata || tool != null) 65 else 7200) { "处理等待过久，已停止并释放资源。" }
                if (!metadata && tool == null) {
                    val bytes=dataBytes()
                    if(bytes>previousDataBytes){activity.set(now);hasTransferred=true}
                    previousDataBytes=bytes
                    if (processing.get() > 0) check((now-processing.get())/1_000_000_000 < 600) { "媒体合并超时，已停止。" }
                    else check((now-activity.get())/1_000_000_000 < if (lastBytes.get()<0 && !hasTransferred) 65 else 120) { "下载长时间没有实际进展，已停止。" }
                }
                if (running.group>0) check(memoryBytes(running.group) < 768L*1024*1024) { "下载组件占用内存过多，已停止。" }
            }
            val result = out.get(5,TimeUnit.SECONDS); val errors = err.get(5,TimeUnit.SECONDS)
            ensureActive(); failure.get()?.let { throw it }
            check(process.exitValue() == 0) { io.feather.videodownloader.android.core.readableError(errors) }
            result
        } finally {
            active.remove(id); terminate(running)
            process.inputStream.close(); process.errorStream.close(); pool.shutdownNow()
        }
    }
    private fun memoryBytes(pid: Int): Long = runCatching {
        val children = File("/proc/$pid/task/$pid/children").takeIf { it.canRead() }?.readText()?.trim()?.split(' ')?.mapNotNull { it.toIntOrNull() } ?: emptyList()
        (listOf(pid)+children.take(32)).sumOf { p -> File("/proc/$p/status").readLines().firstOrNull { it.startsWith("VmRSS:") }?.filter { it.isDigit() }?.toLongOrNull()?.times(1024) ?: 0 }
    }.getOrDefault(0)
    companion object { fun sha256(file: File): String { val hash=MessageDigest.getInstance("SHA-256"); file.inputStream().use { input -> val b=ByteArray(65536); while (true) { val n=input.read(b); if(n<0)break; hash.update(b,0,n) } }; return hash.digest().joinToString("") { "%02x".format(it) } } }
}
