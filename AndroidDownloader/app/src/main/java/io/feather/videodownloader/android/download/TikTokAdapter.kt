// SPDX-License-Identifier: GPL-3.0-only
package io.feather.videodownloader.android.download

import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.net.HttpURLConnection
import java.net.URI
import java.net.URL
import java.security.MessageDigest
import java.util.Base64
import java.util.concurrent.CancellationException

/** Anonymous, first-party fallback. No saved WebView or imported cookies are read. */
object TikTokAdapter {
    private const val AGENT = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36"
    private val videoId = Regex("/(?:video/|embed/(?:v2/)?)((?:[0-9]){15,24})(?:/|$)")
    private val mediaDomains = listOf("tiktokcdn.com", "tiktokcdn-us.com", "tiktokcdn-eu.com", "tiktokv.com", "muscdn.com", "byteoversea.com", "ibytedtos.com")
    private fun hostIs(host: String, domain: String) = host == domain || host.endsWith(".$domain")
    private fun website(url: String): URI = URI(url).also {
        check(it.scheme == "https" && it.userInfo == null && it.port in listOf(-1, 443) &&
            listOf("tiktok.com", "tiktokv.com").any { domain -> hostIs(it.host?.lowercase().orEmpty(), domain) }) { "TikTok 分享地址无效。" }
    }

    suspend fun resolve(source: String, connection: (HttpURLConnection?) -> Unit = {}): String {
        val task = currentCoroutineContext()
        val deadline = System.nanoTime() + 45_000_000_000L
        val checkCancellation = {
            task.ensureActive()
            check(System.nanoTime() < deadline) { "TikTok 解析超时，已停止并释放网络连接。" }
        }
        var requested = website(source).toString()
        var id = videoId.find(URI(requested).path)?.groupValues?.get(1)
        // vm/vt short links are expanded only through TikTok's own redirect chain.
        if (id == null) {
            requested = fetch(requested, deadline, connection, checkCancellation).second
            id = videoId.find(URI(requested).path)?.groupValues?.get(1)
        }
        check(id != null) { "请复制 TikTok 单个公开视频的分享链接。" }
        val candidates = listOf("https://www.tiktok.com/embed/v2/$id?lang=en", "https://www.tiktok.com/embed/v2/$id", requested).distinct()
        var last: Exception? = null
        for (page in candidates) {
            repeat(2) {
                try {
                    val (html, _) = fetch(page, deadline, connection, checkCancellation)
                    parse(html, id, requested)?.let { return it }
                    // The challenge cookie is temporary and exists only for this request.
                    challengeCookie(html, checkCancellation)?.let { cookie ->
                        parse(fetch(page, deadline, connection, checkCancellation, cookie).first, id, requested)?.let { return it }
                    }
                    last = IllegalStateException("TikTok 没有返回此公开视频的信息；请确认视频可访问，或主动选择网站登录状态后重试。")
                } catch (e: Exception) {
                    checkCancellation()
                    if (e is CancellationException || Thread.currentThread().isInterrupted) throw e
                    last = e
                }
                check(System.nanoTime() < deadline) { "TikTok 解析超时，已停止并释放网络连接。" }
            }
        }
        throw IllegalStateException(last?.message ?: "TikTok 暂时没有返回视频信息。", last)
    }

    private fun fetch(source: String, deadline: Long, connection: (HttpURLConnection?) -> Unit,
                      checkCancellation: () -> Unit, cookie: String? = null): Pair<String, String> {
        var current = source
        repeat(6) {
            checkCancellation()
            val uri = website(current)
            val remaining = ((deadline - System.nanoTime()) / 1_000_000).coerceAtMost(12_000).toInt()
            check(remaining > 0 && !Thread.currentThread().isInterrupted) { "TikTok 解析超时或已取消。" }
            val c = URL(uri.toString()).openConnection() as HttpURLConnection
            connection(c)
            c.instanceFollowRedirects = false; c.connectTimeout = remaining; c.readTimeout = remaining
            c.setRequestProperty("User-Agent", AGENT)
            c.setRequestProperty("Referer", "https://www.tiktok.com/")
            c.setRequestProperty("Accept", "text/html,application/xhtml+xml")
            // Avoid the truncated compressed response seen in Python's urllib handler.
            c.setRequestProperty("Accept-Encoding", "identity")
            cookie?.takeIf { hostIs(uri.host.lowercase(), "tiktok.com") }?.let { c.setRequestProperty("Cookie", it) }
            try {
                val status = c.responseCode
                if (status in 300..399) {
                    current = URL(URL(current), requireNotNull(c.getHeaderField("Location"))).toString()
                    website(current)
                } else {
                    check(status in 200..299) { "TikTok 返回 HTTP $status，请检查当前网络与视频访问权限。" }
                    val body = c.inputStream.use { input ->
                        val output = ByteArrayOutputStream(); val buffer = ByteArray(32768)
                        while (true) {
                            checkCancellation()
                            val timeLeft = ((deadline - System.nanoTime()) / 1_000_000).coerceAtMost(12_000).toInt()
                            check(timeLeft > 0) { "TikTok 解析超时。" }
                            c.readTimeout = timeLeft
                            val count = input.read(buffer); if (count < 0) break
                            check(output.size() + count <= 2 * 1024 * 1024) { "TikTok 返回的信息超过大小限制。" }
                            output.write(buffer, 0, count)
                        }
                        output.toString("UTF-8")
                    }
                    check(System.nanoTime() < deadline) { "TikTok 解析超时。" }
                    return body to current
                }
            } finally { c.disconnect(); connection(null) }
        }
        error("TikTok 分享链接重定向次数过多。")
    }

    /** Parses only a matching, public video's data from TikTok's official HTML. */
    internal fun parse(html: String, id: String, source: String): String? {
        fun script(name: String): JSONObject? = Regex("<script\\b[^>]*\\bid=[\"']${Regex.escape(name)}[\"'][^>]*>(.*?)</script>",
            setOf(RegexOption.DOT_MATCHES_ALL, RegexOption.IGNORE_CASE)).find(html)?.groupValues?.get(1)?.let { runCatching { JSONObject(it) }.getOrNull() }
        val state = script("__FRONTITY_CONNECT_STATE__")
        val embedData = state?.optJSONObject("source")?.optJSONObject("data")
        // Frontity includes the locale query in its map key. Match the exact
        // local route rather than silently losing otherwise valid video data.
        val route = embedData?.keys()?.asSequence()?.take(64)?.firstOrNull { key ->
            runCatching {
                val uri = URI(key)
                key.startsWith("/") && !key.startsWith("//") && uri.scheme == null && uri.authority == null &&
                    uri.path == "/embed/v2/$id" && uri.fragment == null
            }.getOrDefault(false)
        }
        val embed = route?.let { embedData?.optJSONObject(it) }?.optJSONObject("videoData")?.optJSONObject("itemInfos")
        val regular = script("__UNIVERSAL_DATA_FOR_REHYDRATION__")?.optJSONObject("__DEFAULT_SCOPE__")?.optJSONObject("webapp.video-detail")?.optJSONObject("itemInfo")?.optJSONObject("itemStruct")
        val item = embed ?: regular ?: return null
        check(item.optString("id") == id) { "TikTok 返回的视频与分享链接不一致。" }
        check(!item.optBoolean("privateItem") && !item.optBoolean("isContentClassified")) { "此视频需要网站登录后访问。" }
        val video = item.optJSONObject("video") ?: return null
        val meta = video.optJSONObject("videoMeta") ?: video
        val formats = JSONArray(); val urls = linkedSetOf<String>()
        fun add(url: String, width: Int, height: Int, format: String) {
            val uri = runCatching { URI(url) }.getOrNull() ?: return
            if (uri.scheme != "https" || uri.userInfo != null || uri.port !in listOf(-1,443) ||
                !mediaDomains.any { hostIs(uri.host?.lowercase().orEmpty(), it) } || !urls.add(url)) return
            formats.put(JSONObject().put("format_id", format).put("url", url).put("ext", "mp4")
                .put("vcodec", "h264").put("acodec", "aac")
                .apply { if (width > 0) put("width", width); if (height > 0) put("height", height) })
        }
        val embedUrls = video.optJSONArray("urls")
        for (i in 0 until minOf(embedUrls?.length() ?: 0, 16))
            add(embedUrls!!.optString(i), meta.optInt("width"), meta.optInt("height"), "tiktok-embed-$i")
        video.optString("playAddr").takeIf { it.startsWith("https://") }?.let {
            add(it, meta.optInt("width"), meta.optInt("height"), "tiktok-web")
        }
        if (formats.length() == 0) return null
        val covers = item.optJSONArray("covers")
        val thumbnail = covers?.optString(0) ?: video.optString("cover")
        return JSONObject().put("id", id)
            .put("title", (item.optString(if (embed != null) "text" else "desc").ifBlank { "TikTok 视频 #$id" }).take(4096))
            .put("webpage_url", source).put("extractor", "TikTokOfficialWeb").put("extractor_key", "Generic")
            .put("http_headers", JSONObject().put("Referer", "https://www.tiktok.com/").put("User-Agent", AGENT))
            .put("formats", formats).apply {
                val duration = meta.optDouble("duration")
                if (duration.isFinite() && duration > 0) put("duration", duration)
                if (thumbnail.startsWith("https://")) put("thumbnail", thumbnail)
            }.toString()
    }

    // Same first-party proof-of-work protocol documented by yt-dlp's TikTok extractor.
    // At most one million hashes; no account credentials or persistent cookie jar.
    private fun challengeCookie(html: String, checkCancellation: () -> Unit): String? {
        fun attribute(id: String): String? {
            val tag = Regex("<[^>]+\\bid=[\"']$id[\"'][^>]*>", RegexOption.IGNORE_CASE).find(html)?.value ?: return null
            return Regex("\\bclass=[\"']([^\"']+)[\"']", RegexOption.IGNORE_CASE).find(tag)?.groupValues?.get(1)
        }
        val encoded = attribute("cs") ?: return null
        val challenge = runCatching { JSONObject(String(Base64.getDecoder().decode(encoded), Charsets.UTF_8)) }.getOrNull() ?: return null
        val values = challenge.optJSONObject("v") ?: return null
        val expected = runCatching { Base64.getDecoder().decode(values.getString("c")) }.getOrNull() ?: return null
        val base = runCatching { Base64.getDecoder().decode(values.getString("a")) }.getOrNull() ?: return null
        check(base.size <= 4096 && expected.size == 32) { "TikTok 返回了无效的网站校验信息。" }
        val digest = MessageDigest.getInstance("SHA-256")
        var answer: String? = null
        for (i in 0..1_000_000) {
            if (i % 4096 == 0) { checkCancellation(); if (Thread.currentThread().isInterrupted) throw CancellationException("TikTok 解析已取消。") }
            digest.update(base)
            val hash = digest.digest(i.toString().toByteArray(Charsets.UTF_8))
            if (hash.contentEquals(expected)) { answer = i.toString(); break }
        }
        answer ?: return null
        challenge.put("d", Base64.getEncoder().encodeToString(answer.toByteArray(Charsets.UTF_8)))
        val name = attribute("wci")?.takeIf { it.matches(Regex("[A-Za-z0-9_]{1,100}")) } ?: return null
        val result = "$name=${Base64.getEncoder().encodeToString(challenge.toString().toByteArray(Charsets.UTF_8))}"
        val originalName = attribute("rci")?.takeIf { it.matches(Regex("[A-Za-z0-9_]{1,100}")) }
        val originalValue = attribute("rs")?.takeIf { it.matches(Regex("[A-Za-z0-9_+=/-]{1,2048}")) }
        return result + if (originalName != null && originalValue != null) "; $originalName=$originalValue" else ""
    }
}
