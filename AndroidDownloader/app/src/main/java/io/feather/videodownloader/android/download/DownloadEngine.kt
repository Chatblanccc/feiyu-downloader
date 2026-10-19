package io.feather.videodownloader.android.download

import android.content.Context
import io.feather.videodownloader.android.core.*
import io.feather.videodownloader.android.web.*
import kotlinx.coroutines.*
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.net.HttpURLConnection
import java.net.URI
import java.net.URL

class DownloadEngine(private val context: Context, val runtime: NativeRuntime = NativeRuntime(context)) {
    private val base = File(context.noBackupFilesDir,"downloads").apply { mkdirs() }
    private val httpRequests=java.util.concurrent.ConcurrentHashMap<String,HttpURLConnection>()
    fun cancel(id:String){httpRequests.remove(id)?.disconnect();runtime.cancel(id)}
    fun cancelAll(){httpRequests.values.toList().forEach{it.disconnect()};httpRequests.clear();runtime.cancelAll()}
    fun directory(id: String) = File(base,id).apply { mkdirs() }
    suspend fun probe(id: String, url: String, authentication: String): MediaInfo = withContext(Dispatchers.IO) {
        val work = directory(id)
        val cookie = CookieVault(context).snapshot(Site.from(url),authentication,id)
        try {
            withTimeoutOrNull(90000) {
            val cancellation=launch(start=CoroutineStart.UNDISPATCHED){try{awaitCancellation()}finally{httpRequests.remove(id)?.disconnect()}}
            try {
            val raw = try {
                if (Site.from(url)==Site.TIKTOK && authentication=="none") TikTokAdapter.resolve(url){c->if(c==null)httpRequests.remove(id)else httpRequests[id]=c}
                else if (Site.from(url)==Site.KUAISHOU && authentication=="none") {
                    try {kuaishou(url){c->if(c==null)httpRequests.remove(id)else httpRequests[id]=c}}
                    catch(e:Exception){if(e is CancellationException)throw e;KuaishouWebAdapter.resolve(url){c->if(c==null)httpRequests.remove(id)else httpRequests[id]=c}}
                }
                else runtime.run(id,listOf("--dump-single-json","--skip-download") + authArgs(cookie) + listOf("--",url),work,true)
            } catch (e: Exception) {
                if (e is CancellationException) throw e
                if (Site.from(url)==Site.DOUYIN && authentication=="none") AnonymousResolver.resolve(context,url)
                else throw e
            }
            decode(raw)
            } finally {cancellation.cancel();httpRequests.remove(id)?.disconnect()}
            } ?: error("视频解析等待过久，已停止并释放资源，请稍后重试。")
        } finally { httpRequests.remove(id)?.disconnect();cookie?.delete() }
    }
    private fun authArgs(cookie: File?) = if (cookie == null) listOf("--no-cookies","--no-cookies-from-browser") else listOf("--no-cookies-from-browser","--cookies",cookie.path)
    suspend fun download(id: String, url: String, quality: Quality, authentication: String, info: MediaInfo,
                         progress: (Progress)->Unit): File = withContext(Dispatchers.IO) {
        val work = directory(id); val cookie = CookieVault(context).snapshot(Site.from(url),authentication,id)
        var final: File? = null
        val metadata = File(work,"metadata.json").apply { writeText(requireNotNull(info.raw)) }
        try {
            val args = listOf("--newline","--continue","--no-simulate","--progress", "--progress-template",
                "download:${Progress.PREFIX}{\"status\":%(progress.status)j,\"downloaded_bytes\":%(progress.downloaded_bytes)j,\"total_bytes\":%(progress.total_bytes)j,\"total_bytes_estimate\":%(progress.total_bytes_estimate)j,\"speed\":%(progress.speed)j,\"eta\":%(progress.eta)j}",
                "--progress-template", "postprocess:${Progress.PREFIX}{\"status\":\"processing\",\"downloaded_bytes\":0}",
                "--print", "after_move:${Progress.FINAL}%(filepath)j", "--format",quality.format,
                "--output",File(work,"%(title).100B [%(id).40B].%(ext)s").path,
                "--load-info-json",metadata.path) + authArgs(cookie) +
                (if (quality==Quality.AUDIO) listOf("--extract-audio","--audio-format","m4a") else emptyList())
            runtime.run(id,args,work) { line ->
                Progress.parse(line)?.let(progress)
                if (line.startsWith(Progress.FINAL)) {
                    val value = JSONArray("[${line.removePrefix(Progress.FINAL)}]").getString(0)
                    val file = File(value).canonicalFile
                    check(file.path.startsWith(work.canonicalPath + File.separator)) { "组件返回了无效的完成路径。" }
                    final = file
                }
            }
            ensureActive()
            requireNotNull(final) { "下载组件没有返回可验证的完成文件。" }.also {
                check(it.isFile && it.length()>0) { "下载结果为空，请重试。" }
                verifyMedia(id,it,quality==Quality.AUDIO)
            }
        } finally { metadata.delete(); cookie?.delete() }
    }
    internal suspend fun verifyMedia(id:String,file:File,audio:Boolean) {
        // A CDN may return a 200 HTML challenge under an .mp4 filename.
        // Validate actual media before it can be published as completed.
        val raw=runtime.run(id,listOf("-v","error","-show_entries","format=duration:stream=codec_type","-of","json",file.path),file.parentFile!!,true,"libffprobe.so")
        val media=JSONObject(raw);val duration=media.optJSONObject("format")?.optDouble("duration") ?: Double.NaN
        val streams=media.optJSONArray("streams") ?: JSONArray()
        check(duration.isFinite() && duration>0 && (0 until streams.length()).any{streams.getJSONObject(it).optString("codec_type")==if(audio)"audio" else "video"}) {
            "网站没有返回有效的${if(audio)"音频" else "视频"}文件，请检查访问权限后重试。"
        }
    }
    fun cleanup(id: String) { File(base,id).deleteRecursively() }
    companion object {
        fun decode(raw: String): MediaInfo {
            val j = JSONObject(raw)
            check(!j.has("entries") && !j.optBoolean("is_live") && j.optString("live_status") != "is_live") { "首版支持已发布的单个视频，请勿使用直播或播放列表链接。" }
            val title=j.optString("title").take(4096); check(title.isNotBlank() && j.has("id")) { "没有获得有效的视频信息。" }
            val formats = j.optJSONArray("formats") ?: JSONArray()
            fun normalize(format:JSONObject):Int? {
                val dimensions=listOf(format.optInt("width"),format.optInt("height")).filter{it>0}
                return dimensions.minOrNull()?.also{format.put("feiyu_resolution",it)}
            }
            // Resolution caps apply to the short edge for both landscape and
            // portrait videos; 720x1280 is a 720p source, not a 1280p source.
            normalize(j)
            val heights = (0 until minOf(formats.length(),4096)).mapNotNull { formats.optJSONObject(it)?.let(::normalize) }.distinct().sortedDescending()
            return MediaInfo(j.get("id").toString().take(512),title,j.optDouble("duration").takeIf { it.isFinite() && it>=0 },j.optString("thumbnail").takeIf { it.startsWith("https://") },heights,j.toString())
        }
        fun http(url: String, headers: Map<String,String> = emptyMap(), connection:(HttpURLConnection?)->Unit = {},
                 deadlineNanos:Long=System.nanoTime()+30_000_000_000L): Pair<String,String> {
            var current=url
            repeat(7) {
                val uri=URI(current); check(uri.scheme in listOf("http","https") && uri.userInfo==null && uri.host!=null)
                fun remaining():Int {
                    val millis=((deadlineNanos-System.nanoTime())/1_000_000).coerceAtMost(15000).toInt()
                    check(millis>0){"网站解析超时，已停止并释放连接。"};return millis
                }
                val c=URL(current).openConnection() as HttpURLConnection
                connection(c)
                c.instanceFollowRedirects=false; c.connectTimeout=remaining();c.readTimeout=remaining()
                c.setRequestProperty("User-Agent","Mozilla/5.0")
                headers.forEach { (k,v)->c.setRequestProperty(k,v) }
                try {
                    if(c.responseCode in 300..399) { current=URL(URL(current),requireNotNull(c.getHeaderField("Location"))).toString();return@repeat }
                    check(c.responseCode in 200..299) { "网站返回 HTTP ${c.responseCode}。" }
                    val out=java.io.ByteArrayOutputStream()
                    c.inputStream.use { input -> val buffer=ByteArray(32768);while(true){c.readTimeout=remaining();val n=input.read(buffer);if(n<0)break;check(out.size()+n<=8*1024*1024){"网站返回的数据过大。"};out.write(buffer,0,n)} }
                    remaining()
                    return out.toString("UTF-8") to current
                } finally { c.disconnect();connection(null) }
            }; error("分享链接重定向次数过多。")
        }
        fun kuaishou(source: String, connection:(HttpURLConnection?)->Unit = {}): String {
            val page=if(URI(source).path.startsWith("/short-video/"))source else http(source,connection=connection).second
            check(Site.from(page)==Site.KUAISHOU) { "快手分享地址无效。" }
            val uri=URI(page);val id=uri.path.split('/').getOrNull(2)
            val author=uri.rawQuery?.split('&')?.firstOrNull{it.startsWith("authorId=")}?.substringAfter('=')
            check(!id.isNullOrBlank() && id.matches(Regex("[A-Za-z0-9_-]+")) && !author.isNullOrBlank()) { "请在快手复制完整分享链接（包含作者信息）后重试。" }
            val data=JSONObject(http("https://live.kuaishou.com/live_api/profile/feedbyid?photoId=$id&principalId=$author",mapOf("Referer" to "https://live.kuaishou.com/"),connection).first).getJSONObject("data")
            check(data.optInt("result")==1){"快手没有返回此视频的信息，请确认分享链接和访问权限。"}
            val work=data.getJSONObject("currentWork");check(work.getString("id")==id)
            val media=work.getString("playUrl");val host=URI(media).host ?: ""
            check(media.startsWith("https://") && listOf("kwimgs.com","yximgs.com","gifshow.com","kuaishouzt.com").any { host==it || host.endsWith(".$it") })
            return JSONObject().put("id",id).put("title",work.optString("caption").ifBlank{"快手视频"}).put("webpage_url",source)
                .put("thumbnail",work.optString("poster")).put("extractor","KuaishouShare").put("extractor_key","Generic")
                .put("http_headers",JSONObject().put("Referer","https://live.kuaishou.com/").put("User-Agent","Mozilla/5.0"))
                .put("formats",JSONArray().put(JSONObject().put("format_id","kuaishou-source").put("url",media).put("ext","mp4").put("vcodec","h264").put("acodec","aac").put("height",work.optInt("height")).put("width",work.optInt("width")))).toString()
        }
    }
}
