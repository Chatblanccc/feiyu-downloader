package io.feather.videodownloader.android.download

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.net.CookieManager
import java.net.CookiePolicy
import java.net.HttpURLConnection
import java.net.URI
import java.net.URL
import kotlin.coroutines.coroutineContext

/** Reads only the public website's server-rendered state, using a fresh local cookie jar. */
internal object KuaishouWebAdapter {
    private const val USER_AGENT = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
    private const val MAX_BODY = 2 * 1024 * 1024
    private const val DEADLINE_NANOS = 45_000_000_000L
    private val VIDEO_PATH = Regex("^/short-video/([A-Za-z0-9_-]{1,64})/?$")
    private val CDN_DOMAINS = listOf("kwimgs.com", "yximgs.com", "gifshow.com", "kuaishouzt.com", "ndcimgs.com", "kwaicdn.com")

    suspend fun resolve(source: String, connection: (HttpURLConnection?) -> Unit = {}): String = withContext(Dispatchers.IO) {
        val start = System.nanoTime()
        // This CookieManager is never installed globally or populated from a
        // WebView/login store. It exists only for this one anonymous resolution.
        val cookies = CookieManager(null, CookiePolicy.ACCEPT_ORIGINAL_SERVER)
        var redirects = 0
        suspend fun remainingMillis(): Int {
            coroutineContext.ensureActive()
            val left = DEADLINE_NANOS - (System.nanoTime() - start)
            check(left > 0) { "快手公开网页解析超时，请稍后重试。" }
            return (left / 1_000_000L).coerceIn(1, 10_000).toInt()
        }
        suspend fun read(initial: String): Pair<String, String> {
            var address = initial
            while (true) {
                val uri = URI(address)
                check(allowedPage(uri)) { "快手分享地址或重定向地址无效。" }
                remainingMillis()
                val current = URL(address).openConnection() as HttpURLConnection
                connection(current)
                try {
                    current.instanceFollowRedirects = false
                    current.useCaches = false
                    current.connectTimeout = remainingMillis()
                    current.readTimeout = remainingMillis()
                    current.setRequestProperty("User-Agent", USER_AGENT)
                    current.setRequestProperty("Referer", "https://www.kuaishou.com/")
                    current.setRequestProperty("Accept", "text/html,application/xhtml+xml")
                    // Send only cookies issued to this request's private jar.
                    val localCookies = cookies.get(uri, emptyMap())["Cookie"]?.joinToString("; ").orEmpty()
                    current.setRequestProperty("Cookie", localCookies)
                    val status = current.responseCode
                    remainingMillis()
                    cookies.put(uri, current.headerFields.filterKeys { it != null })
                    if (status in 300..399) {
                        check(++redirects <= 5) { "快手分享链接重定向次数过多。" }
                        address = URL(URL(address), requireNotNull(current.getHeaderField("Location"))).toString()
                        continue
                    }
                    check(status in 200..299) { "快手网页返回 HTTP $status，请稍后重试。" }
                    check(current.contentLengthLong <= MAX_BODY) { "快手网页数据过大。" }
                    val body = ByteArrayOutputStream()
                    current.inputStream.use { input ->
                        val buffer = ByteArray(16 * 1024)
                        while (true) {
                            current.readTimeout = remainingMillis()
                            val count = input.read(buffer)
                            remainingMillis()
                            if (count < 0) break
                            check(body.size() + count <= MAX_BODY) { "快手网页数据过大。" }
                            body.write(buffer, 0, count)
                        }
                    }
                    return body.toString("UTF-8") to address
                } finally {
                    current.disconnect()
                    connection(null)
                }
            }
        }
        try {
            check(allowedPage(URI(source))) { "快手分享地址无效。" }
            // A normal anonymous homepage visit provides the first-party device
            // cookies required by the public SSR page. No challenge is solved.
            read("https://www.kuaishou.com/")
            val (html, finalAddress) = read(source)
            remainingMillis()
            val sourceId = VIDEO_PATH.matchEntire(URI(source).path.orEmpty())?.groupValues?.get(1)
            val finalId = VIDEO_PATH.matchEntire(URI(finalAddress).path.orEmpty())?.groupValues?.get(1)
            val id = requireNotNull(finalId) { "快手没有返回单个公开视频的页面，请复制完整分享链接。" }
            check(sourceId == null || sourceId == id) { "快手分享链接返回了其他视频。" }
            metadataFromHtml(html, id, source)
        } finally {
            cookies.cookieStore.removeAll()
        }
    }

    private fun allowedPage(uri: URI): Boolean {
        val host = uri.host?.lowercase() ?: return false
        return uri.scheme == "https" && uri.userInfo == null && uri.port in listOf(-1, 443) &&
            (host == "kuaishou.com" || host.endsWith(".kuaishou.com"))
    }

    internal fun allowedMedia(value: String): Boolean = runCatching {
        val uri = URI(value)
        val host = uri.host?.lowercase() ?: return@runCatching false
        uri.scheme == "https" && uri.userInfo == null && uri.port in listOf(-1, 443) &&
            CDN_DOMAINS.any { host == it || host.endsWith(".$it") }
    }.getOrDefault(false)

    /** Balanced JSON extraction avoids regex truncation inside escaped captions. */
    internal fun metadataFromHtml(html: String, requestedId: String, source: String): String {
        check(html.toByteArray(Charsets.UTF_8).size <= MAX_BODY) { "快手网页数据过大。" }
        val assignment = Regex("window\\.__APOLLO_STATE__\\s*=\\s*").find(html)
            ?: error("快手公开网页没有返回视频信息，请确认访问权限后重试。")
        val start = assignment.range.last + 1
        check(html.getOrNull(start) == '{') { "快手网页数据格式无效。" }
        var depth = 0
        var quoted = false
        var escaped = false
        var end = -1
        for (index in start until html.length) {
            val char = html[index]
            if (quoted) {
                if (escaped) escaped = false
                else if (char == '\\') escaped = true
                else if (char == '"') quoted = false
            } else when (char) {
                '"' -> quoted = true
                '{', '[' -> depth++
                '}', ']' -> { depth--; if (depth == 0) { end = index + 1; break } }
            }
        }
        check(end > start) { "快手网页数据不完整。" }
        return metadataFromState(JSONObject(html.substring(start, end)), requestedId, source)
    }

    internal fun metadataFromState(root: JSONObject, requestedId: String, source: String): String {
        check(requestedId.matches(Regex("[A-Za-z0-9_-]{1,64}"))) { "快手视频编号无效。" }
        val table = root.getJSONObject("defaultClient")
        val query = table.getJSONObject("ROOT_QUERY")
        val key = query.keys().asSequence().firstOrNull { key ->
            if (!key.startsWith("visionVideoDetail(") || !key.endsWith(")")) false
            else runCatching {
                val arguments = JSONObject(key.substringAfter('(').dropLast(1))
                arguments.optString("photoId") == requestedId && arguments.optString("page") == "detail"
            }.getOrDefault(false)
        } ?: error("快手网页没有返回所请求的视频。")
        fun objectAt(value: JSONObject?): JSONObject? {
            if (value == null) return null
            return if (value.optString("type") == "id") table.optJSONObject(value.optString("id")) else value
        }
        val detail = requireNotNull(objectAt(query.optJSONObject(key))) { "快手网页的视频引用无效。" }
        check(detail.optInt("status") == 1 && detail.optInt("type") == 1 && !detail.optBoolean("private") && !detail.optBoolean("isPrivate")) {
            "快手视频当前不是可访问的公开单视频，请检查访问权限。"
        }
        val photo = requireNotNull(objectAt(detail.optJSONObject("photo"))) { "快手网页没有返回视频内容。" }
        check(photo.optString("id") == requestedId && !photo.optBoolean("private") && !photo.optBoolean("isPrivate")) { "快手网页的视频编号或访问状态不匹配。" }
        val author = objectAt(detail.optJSONObject("author"))
        check(author?.optBoolean("private") != true && author?.optBoolean("isPrivate") != true) { "快手作者当前不允许公开访问。" }
        val formats = JSONArray()
        fun append(representation: JSONObject) {
            if (formats.length() >= 32) return
            val media = representation.optString("url")
            check(allowedMedia(media)) { "快手网页返回了不受支持的视频地址。" }
            val width = representation.optInt("width")
            val height = representation.optInt("height")
            check(width in 0..16384 && height in 0..16384) { "快手网页返回的视频尺寸无效。" }
            val format = JSONObject().put("format_id", "kuaishou-web-${formats.length()}").put("url", media)
                .put("ext", "mp4").put("vcodec", "h264").put("acodec", "aac")
            if (width > 0) format.put("width", width)
            if (height > 0) format.put("height", height)
            representation.optLong("fileSize").takeIf { it > 0 }?.let { format.put("filesize", it) }
            formats.put(format)
        }
        val h264 = photo.optJSONObject("videoResource")?.optJSONObject("json")?.optJSONObject("h264")
        val sets = h264?.optJSONArray("adaptationSet")
        if (sets != null) for (index in 0 until minOf(sets.length(), 32)) {
            val representations = sets.optJSONObject(index)?.optJSONArray("representation") ?: continue
            for (entry in 0 until minOf(representations.length(), 32)) representations.optJSONObject(entry)?.let(::append)
        }
        if (formats.length() == 0) {
            val manifest = objectAt(photo.optJSONObject("manifest"))
            val adaptation = manifest?.optJSONArray("adaptationSet")
            if (adaptation != null) for (index in 0 until minOf(adaptation.length(), 32)) {
                val set = objectAt(adaptation.optJSONObject(index)) ?: continue
                val representations = set.optJSONArray("representation") ?: continue
                for (entry in 0 until minOf(representations.length(), 32)) objectAt(representations.optJSONObject(entry))?.let(::append)
            }
        }
        if (formats.length() == 0) append(JSONObject().put("url", photo.optString("photoUrl")))
        val title = photo.optString("caption").take(4096).ifBlank { "快手视频" + (author?.optString("name")?.takeIf { it.isNotBlank() }?.let { " · $it" } ?: "") }
        val result = JSONObject().put("id", requestedId).put("title", title).put("webpage_url", source)
            .put("extractor", "KuaishouWeb").put("extractor_key", "Generic").put("formats", formats)
            .put("http_headers", JSONObject().put("Referer", "https://www.kuaishou.com/").put("User-Agent", USER_AGENT))
        photo.optLong("duration").takeIf { it > 0 }?.let { result.put("duration", it / 1000.0) }
        photo.optString("coverUrl").takeIf(::allowedMedia)?.let { result.put("thumbnail", it) }
        return result.toString()
    }
}
