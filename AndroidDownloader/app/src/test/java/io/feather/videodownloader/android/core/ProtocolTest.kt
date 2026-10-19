package io.feather.videodownloader.android.core

import org.junit.Assert.*
import org.junit.Test
import io.feather.videodownloader.android.download.DownloadEngine
import io.feather.videodownloader.android.web.CookieVault

class ProtocolTest {
    @Test fun shareTextAcceptsCompleteChineseText(){assertEquals(listOf("https://v.douyin.com/abc/"),ShareLinks.parse("复制打开抖音，看看这个视频 https://v.douyin.com/abc/ 复制这段文案。"))}
    @Test fun linksRemoveUnbalancedClosingPunctuation(){assertEquals(listOf("https://x.com/a/status/1"),ShareLinks.parse("（https://x.com/a/status/1）。"))}
    @Test fun balancedParenthesesArePreserved(){assertEquals(listOf("https://example.com/a(b)"),ShareLinks.parse("https://example.com/a(b)"))}
    @Test fun duplicatesDoNotBecomeMultipleTasks(){assertEquals(1,ShareLinks.parse("https://b23.tv/abc https://b23.tv/abc").size)}
    @Test fun credentialsInURLsAreRejected(){assertTrue(ShareLinks.parse("https://secret:pass@x.com/a").isEmpty())}
    @Test fun nonHttpLinksAreRejected(){assertTrue(ShareLinks.parse("javascript:alert(1) file:///a").isEmpty())}
    @Test(expected=IllegalArgumentException::class) fun oversizedShareTextIsRejected(){ShareLinks.parse("字".repeat(30000))}
    @Test fun siteMatchingIsDomainBounded(){assertNull(Site.from("https://douyin.com.evil.example/a"));assertEquals(Site.X,Site.from("https://twitter.com/a/status/1"))}
    @Test fun shortLinksRecognizePlatform(){assertEquals(Site.BILIBILI,Site.from("https://b23.tv/abc"));assertEquals(Site.YOUTUBE,Site.from("https://youtu.be/a"))}
    @Test fun progressUsesActualBytes(){val p=Progress.parse(Progress.PREFIX+"{\"downloaded_bytes\":512,\"total_bytes\":1024,\"speed\":80,\"eta\":2}")!!;assertEquals(.5f,p.fraction!!);assertEquals(512L,p.bytes)}
    @Test fun unknownTotalDoesNotInventPercentage(){assertNull(Progress.parse(Progress.PREFIX+"{\"downloaded_bytes\":512}")!!.fraction)}
    @Test fun invalidProgressDoesNotCrashParser(){assertNull(Progress.parse(Progress.PREFIX+"garbage"));assertNull(Progress.parse("100%"))}
    @Test fun processingIsNotCompleted(){assertTrue(TaskState.PROCESSING.active);assertFalse(TaskState.COMPLETED.active)}
    @Test(expected=IllegalStateException::class) fun liveVideoIsRejected(){DownloadEngine.decode("{\"id\":\"a\",\"title\":\"live\",\"is_live\":true}")}
    @Test(expected=IllegalStateException::class) fun playlistIsRejected(){DownloadEngine.decode("{\"id\":\"a\",\"title\":\"list\",\"entries\":[]}")}
    @Test fun metadataHasBoundedSortedQualities(){val m=DownloadEngine.decode("{\"id\":\"a\",\"title\":\"视频\",\"formats\":[{\"height\":720},{\"height\":1080},{\"height\":720}]}");assertEquals(listOf(1080,720),m.heights)}
    @Test fun portraitResolutionUsesShortEdge(){val m=DownloadEngine.decode("{\"id\":\"portrait\",\"title\":\"竖屏\",\"formats\":[{\"width\":720,\"height\":1280},{\"width\":576,\"height\":1024},{\"width\":1920,\"height\":1080}]}");assertEquals(listOf(1080,720,576),m.heights);assertEquals(720,org.json.JSONObject(m.raw!!).getJSONArray("formats").getJSONObject(0).getInt("feiyu_resolution"))}
    @Test fun cookieDomainsCannotLeakToOtherSites(){assertTrue(CookieVault.allowed(Site.DOUYIN,"www.douyin.com"));assertFalse(CookieVault.allowed(Site.DOUYIN,"douyin.com.evil.test"));assertFalse(CookieVault.allowed(Site.X,"youtube.com"))}
    @Test fun errorsDoNotPrintSignedURLs(){assertFalse(readableError("failed https://cdn.example/a?token=secret").contains("secret"))}
}
