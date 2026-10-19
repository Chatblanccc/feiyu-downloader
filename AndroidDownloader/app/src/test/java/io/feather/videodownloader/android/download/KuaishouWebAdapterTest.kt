package io.feather.videodownloader.android.download

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class KuaishouWebAdapterTest {
    private val id = "3xqf2nbqfikruck"
    private val source = "https://www.kuaishou.com/short-video/$id?authorId=renminwang"
    private val media = "https://example.djvod.ndcimgs.com/upic/public.mp4"
    private val detailKey = "visionVideoDetail({\"page\":\"detail\",\"photoId\":\"$id\"})"

    // Projection of the public SSR schema, without real HTML, signed URLs,
    // request cookies, account information, or any challenge payload.
    private fun state(): JSONObject {
        val representation = JSONObject().put("url", media).put("width", 720).put("height", 1280).put("fileSize", 2553892)
        val h264 = JSONObject().put("adaptationSet", JSONArray().put(JSONObject().put("representation", JSONArray().put(representation))))
        val photo = JSONObject().put("id", id).put("caption", "公开测试视频").put("duration", 7766).put("photoUrl", media)
            .put("coverUrl", "https://p5.a.yximgs.com/public.jpg").put("videoResource", JSONObject().put("type", "json").put("json", JSONObject().put("h264", h264)))
        val detail = JSONObject().put("status", 1).put("type", 1)
            .put("photo", JSONObject().put("type", "id").put("id", "photo"))
            .put("author", JSONObject().put("type", "id").put("id", "author"))
        return JSONObject().put("defaultClient", JSONObject()
            .put("ROOT_QUERY", JSONObject().put(detailKey, JSONObject().put("type", "id").put("id", "detail")))
            .put("detail", detail).put("photo", photo).put("author", JSONObject().put("name", "公开作者")))
    }

    @Test fun publicSsrProducesRealDimensionsAndDuration() {
        val result = JSONObject(KuaishouWebAdapter.metadataFromState(state(), id, source))
        assertEquals(id, result.getString("id"))
        assertEquals(7.766, result.getDouble("duration"), 0.0001)
        assertEquals(media, result.getJSONArray("formats").getJSONObject(0).getString("url"))
        assertEquals(720, result.getJSONArray("formats").getJSONObject(0).getInt("width"))
        assertEquals(1280, result.getJSONArray("formats").getJSONObject(0).getInt("height"))
        assertFalse(result.getJSONObject("http_headers").has("Cookie"))
    }

    @Test fun normalizedManifestReferencesAreSupported() {
        val root = state(); val table = root.getJSONObject("defaultClient"); val photo = table.getJSONObject("photo")
        photo.remove("videoResource")
        photo.put("manifest", JSONObject().put("type", "id").put("id", "manifest"))
        table.put("manifest", JSONObject().put("adaptationSet", JSONArray().put(JSONObject().put("type", "id").put("id", "set"))))
        table.put("set", JSONObject().put("representation", JSONArray().put(JSONObject().put("type", "id").put("id", "representation"))))
        table.put("representation", JSONObject().put("url", media).put("width", 720).put("height", 1280))
        val result = JSONObject(KuaishouWebAdapter.metadataFromState(root, id, source))
        assertEquals(1280, result.getJSONArray("formats").getJSONObject(0).getInt("height"))
    }

    @Test fun escapedCaptionDoesNotTruncateTheJsonAssignment() {
        val root = state(); root.getJSONObject("defaultClient").getJSONObject("photo").put("caption", "引号\"和大括号 } ; </script>")
        val html = "<script>window.__APOLLO_STATE__ = $root;</script><script>window.other={};</script>"
        val result = JSONObject(KuaishouWebAdapter.metadataFromHtml(html, id, source))
        assertEquals("引号\"和大括号 } ; </script>", result.getString("title"))
    }

    @Test(expected = IllegalStateException::class) fun inaccessibleStatusIsRejected() {
        val root = state(); root.getJSONObject("defaultClient").getJSONObject("detail").put("status", 3)
        KuaishouWebAdapter.metadataFromState(root, id, source)
    }

    @Test(expected = IllegalStateException::class) fun privatePhotoIsRejectedEvenIfAUrlIsPresent() {
        val root = state(); root.getJSONObject("defaultClient").getJSONObject("photo").put("private", true)
        KuaishouWebAdapter.metadataFromState(root, id, source)
    }

    @Test(expected = IllegalStateException::class) fun anotherPhotoIsRejected() {
        val root = state(); root.getJSONObject("defaultClient").getJSONObject("photo").put("id", "different")
        KuaishouWebAdapter.metadataFromState(root, id, source)
    }

    @Test(expected = IllegalStateException::class) fun anotherQueryIdIsRejected() {
        KuaishouWebAdapter.metadataFromState(state(), "different", source)
    }

    @Test(expected = IllegalStateException::class) fun evilCdnInAFormatIsRejected() {
        val root = state(); root.getJSONObject("defaultClient").getJSONObject("photo").getJSONObject("videoResource")
            .getJSONObject("json").getJSONObject("h264").getJSONArray("adaptationSet").getJSONObject(0)
            .getJSONArray("representation").getJSONObject(0).put("url", "https://ndcimgs.com.evil.example/video.mp4")
        KuaishouWebAdapter.metadataFromState(root, id, source)
    }

    @Test fun cdnBoundsRejectCredentialsAndForeignHosts() {
        assertTrue(KuaishouWebAdapter.allowedMedia(media))
        assertTrue(KuaishouWebAdapter.allowedMedia("https://v1.kwaicdn.com/a.mp4"))
        assertFalse(KuaishouWebAdapter.allowedMedia("https://ndcimgs.com.evil.test/a.mp4"))
        assertFalse(KuaishouWebAdapter.allowedMedia("https://user:pass@v1.kwaicdn.com/a.mp4"))
        assertFalse(KuaishouWebAdapter.allowedMedia("http://v1.kwaicdn.com/a.mp4"))
        assertFalse(KuaishouWebAdapter.allowedMedia("https://127.0.0.1/a.mp4"))
    }
}
