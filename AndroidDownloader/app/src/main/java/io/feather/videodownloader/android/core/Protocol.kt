package io.feather.videodownloader.android.core

import java.net.URI
import org.json.JSONObject

fun java.io.InputStream.readBounded(limit: Int): ByteArray {
    val output=java.io.ByteArrayOutputStream();val buffer=ByteArray(16384)
    while(true){val n=read(buffer);if(n<0)break;check(output.size()+n<=limit){"文件或响应数据超过大小限制。"};output.write(buffer,0,n)}
    return output.toByteArray()
}

enum class Quality(val label: String, val format: String) {
    BEST("最佳画质", "bv*+ba/b"), P1080("1080p 以下", "bv*[feiyu_resolution<=1080]+ba/b[feiyu_resolution<=1080]"),
    P720("720p 以下", "bv*[feiyu_resolution<=720]+ba/b[feiyu_resolution<=720]"), AUDIO("仅音频", "ba/b")
}
enum class TaskState(val label: String) {
    QUEUED("排队中"), RESOLVING("解析中"), DOWNLOADING("下载中"), PROCESSING("合并中"), SAVING("保存中"),
    COMPLETED("已完成"), FAILED("失败"), CANCELLED("已取消"), INTERRUPTED("已中断");
    val active get() = this in setOf(RESOLVING, DOWNLOADING, PROCESSING, SAVING)
}
enum class Site(val label: String, val domain: String) {
    DOUYIN("抖音", "www.douyin.com"), KUAISHOU("快手", "www.kuaishou.com"), BILIBILI("B站", "www.bilibili.com"),
    YOUTUBE("YouTube", "www.youtube.com"), X("X", "x.com"), TIKTOK("TikTok", "www.tiktok.com");
    companion object {
        fun from(url: String): Site? {
            val h = runCatching { URI(url).host?.lowercase() }.getOrNull() ?: return null
            fun domain(d: String) = h == d || h.endsWith(".$d")
            return when { domain("douyin.com") || domain("iesdouyin.com") -> DOUYIN
                domain("kuaishou.com") -> KUAISHOU; domain("bilibili.com") || domain("b23.tv") -> BILIBILI
                domain("youtube.com") || domain("youtu.be") -> YOUTUBE; domain("x.com") || domain("twitter.com") -> X
                domain("tiktok.com") -> TIKTOK; else -> null }
        }
    }
}
object ShareLinks {
    fun parse(text: String): List<String> {
        require(text.toByteArray().size <= 65536) { "分享文案过长，请缩短后重试。" }
        return Regex("https?://[^\\s<>\"“”‘’「」『』【】《》。，、！？；：]+", RegexOption.IGNORE_CASE)
            .findAll(text).map { it.value.trimEnd('。','，','、','！','？','；','：','…','.',',','!',';',':','\'') }
            .map { raw -> var s = raw; val pairs = mapOf(')' to '(', ']' to '[', '}' to '{', '）' to '（')
                while (s.isNotEmpty()) { val c = s.last(); val o = pairs[c] ?: break
                    if (s.count { it == c } <= s.count { it == o }) break; s = s.dropLast(1) }; s }
            .filter { runCatching { val u = URI(it); u.scheme.lowercase() in listOf("http","https") && !u.host.isNullOrBlank() && u.userInfo == null }.getOrDefault(false) }
            .distinct().take(50).toList()
    }
}
data class MediaInfo(val id: String, val title: String, val duration: Double?, val thumbnail: String?, val heights: List<Int>, val raw: String? = null)
data class Progress(val bytes: Long, val total: Long?, val speed: Double?, val eta: Long?, val processing: Boolean = false) {
    val fraction get() = total?.takeIf { it > 0 }?.let { (bytes.toDouble() / it).coerceIn(0.0,1.0).toFloat() }
    companion object {
        const val PREFIX = "__FEATHER_PROGRESS__"
        const val FINAL = "__FEATHER_FINAL__"
        fun parse(line: String): Progress? = runCatching {
            if (!line.startsWith(PREFIX) || line.length > 16384) return null
            val j = JSONObject(line.removePrefix(PREFIX))
            fun number(k: String) = j.optDouble(k, Double.NaN).takeIf { it.isFinite() && it >= 0 }
            Progress(number("downloaded_bytes")?.toLong() ?: 0, (number("total_bytes") ?: number("total_bytes_estimate"))?.toLong(), number("speed"), number("eta")?.toLong(), j.optString("status") == "processing")
        }.getOrNull()
    }
}
fun readableError(text: String): String {
    val s = text.lowercase()
    return when {
        "no space left" in s || "enospc" in s -> "手机剩余空间不足，请清理空间后重试。"
        "private" in s || "login" in s || "sign in" in s || "cookies" in s -> "网站需要登录或有效会话，请主动选择网站登录状态后重试。"
        "429" in s || "too many requests" in s -> "网站暂时限制了请求频率，请稍后重试。"
        "403" in s || "captcha" in s -> "网站拒绝了请求，可能需要登录、验证或稍后重试。"
        "unsupported url" in s -> "暂时无法解析这个链接，请使用单个视频的分享链接。"
        "requested format" in s -> "视频没有返回所选清晰度，请选择最佳画质后重试。"
        "incompleteread" in s || "bytes read" in s -> "网络响应未完整接收，请检查网络或代理后重试。"
        "cannot link executable" in s -> "下载组件无法在这台设备上启动，请记录手机型号和系统版本后反馈。"
        "timed out" in s || "network" in s || "connection" in s -> "网络连接未成功，请检查网络后重试。"
        else -> text.replace(Regex("https?://\\S+"), "[链接]").takeLast(700).ifBlank { "这次下载未成功，请重试。" }
    }
}
