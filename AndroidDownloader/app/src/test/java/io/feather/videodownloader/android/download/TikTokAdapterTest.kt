package io.feather.videodownloader.android.download

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class TikTokAdapterTest {
    private val id = "7059698374567611694"
    private val source = "https://www.tiktok.com/@example/video/$id"
    private fun page(item: JSONObject, route: String = "/embed/v2/$id"): String {
        val data = JSONObject().put(route, JSONObject().put("videoData", JSONObject().put("itemInfos", item)))
        return "<script type=\"application/json\" id=\"__FRONTITY_CONNECT_STATE__\">" +
            JSONObject().put("source", JSONObject().put("data", data)) + "</script>"
    }
    private fun item(url: String = "https://v16.tiktokcdn.com/video/example.mp4") = JSONObject().put("id", id).put("text", "")
        .put("video", JSONObject().put("urls", JSONArray().put(url)).put("videoMeta", JSONObject().put("width", 576).put("height", 1024).put("duration", 6)))

    @Test fun preservesPortraitDimensionsAndCombinedStream() {
        val raw = requireNotNull(TikTokAdapter.parse(page(item()), id, source))
        val result = JSONObject(raw); val format = result.getJSONArray("formats").getJSONObject(0)
        assertEquals(id, result.getString("id")); assertEquals(6.0, result.getDouble("duration"), 0.01)
        assertEquals(576, format.getInt("width")); assertEquals(1024, format.getInt("height"))
        assertEquals("h264", format.getString("vcodec")); assertEquals("aac", format.getString("acodec"))
        assertFalse(result.has("cookies")); assertFalse(result.getJSONObject("http_headers").has("Cookie"))
    }
    @Test fun excludesArbitraryHostsAndDowngradeUrls() {
        listOf("https://tiktokcdn.com.evil.example/video.mp4", "http://v16.tiktokcdn.com/video.mp4",
            "https://name@v16.tiktokcdn.com/video.mp4", "https://v16.tiktokcdn.com:8443/video.mp4")
            .forEach { assertNull(TikTokAdapter.parse(page(item(it)), id, source)) }
    }
    @Test(expected = IllegalStateException::class) fun rejectsDifferentVideo() {
        TikTokAdapter.parse(page(item().put("id", "6742501081818877190")), id, source)
    }
    @Test(expected = IllegalStateException::class) fun rejectsPrivateVideo() {
        TikTokAdapter.parse(page(item().put("privateItem", true)), id, source)
    }
    @Test fun rejectsMissingOfficialData() {
        assertNull(TikTokAdapter.parse("<html>Unavailable</html>", id, source))
    }
    @Test fun acceptsOfficialLocaleRouteAndRejectsForeignRoutes() {
        val raw = requireNotNull(TikTokAdapter.parse(page(item(), "/embed/v2/$id?lang=en"), id, source))
        assertEquals(id, JSONObject(raw).getString("id"))
        listOf("https://evil.example/embed/v2/$id?lang=en", "//evil.example/embed/v2/$id?lang=en",
            "/embed/v2/6742501081818877190?lang=en", "/embed/v2/${id}0?lang=en", "/embed/v2/$id?lang=en#other")
            .forEach { route -> assertNull(TikTokAdapter.parse(page(item(), route), id, source)) }
    }
}
