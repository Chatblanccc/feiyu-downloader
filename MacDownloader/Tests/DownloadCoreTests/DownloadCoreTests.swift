#if FEATHER_STANDALONE
import Foundation
class XCTestCase { }
private func XCTFail(_ message: String = "Assertion failed", file: StaticString = #filePath, line: UInt = #line) {
    fatalError(message, file: (file), line: line)
}
private func XCTAssertTrue(_ value: @autoclosure () -> Bool, _ message: String = "Expected true", file: StaticString = #filePath, line: UInt = #line) {
    if !value() { XCTFail(message, file: file, line: line) }
}
private func XCTAssertFalse(_ value: @autoclosure () -> Bool, _ message: String = "Expected false", file: StaticString = #filePath, line: UInt = #line) {
    if value() { XCTFail(message, file: file, line: line) }
}
private func XCTAssertEqual<T: Equatable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T, file: StaticString = #filePath, line: UInt = #line) rethrows {
    let first = try a(), second = try b()
    if first != second { XCTFail("Expected \(first) == \(second)", file: file, line: line) }
}
private func XCTAssertNotEqual<T: Equatable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T, file: StaticString = #filePath, line: UInt = #line) rethrows {
    if try a() == b() { XCTFail("Expected unequal values", file: file, line: line) }
}
private func XCTAssertLessThan<T: Comparable>(_ a: @autoclosure () -> T, _ b: @autoclosure () -> T, file: StaticString = #filePath, line: UInt = #line) {
    if !(a() < b()) { XCTFail("Expected first value less than second", file: file, line: line) }
}
private func XCTAssertNil<T>(_ a: @autoclosure () -> T?, file: StaticString = #filePath, line: UInt = #line) {
    if a() != nil { XCTFail("Expected nil", file: file, line: line) }
}
private func XCTUnwrap<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) throws -> T {
    guard let value = value else { XCTFail("Expected non-nil", file: file, line: line); throw DownloadError.invalidMetadata }
    return value
}
#else
import XCTest
@testable import DownloadCore
#endif
import Darwin

final class DownloadCoreTests: XCTestCase {
    private let tools = ToolPaths(ytDLP: URL(fileURLWithPath: "/usr/bin/true"),
                                  ffmpeg: URL(fileURLWithPath: "/usr/bin/true"),
                                  deno: URL(fileURLWithPath: "/usr/bin/true"))
    private let metadataJSON = #"{"id":"abc","title":"中文标题","webpage_url":"https://video.example/watch?v=abc","thumbnail":"https://video.example/cover.jpg","duration":12.5,"formats":[{"format_id":"v1","height":1080,"width":1920,"fps":30,"ext":"mp4","vcodec":"h264","acodec":"none","filesize":12345},{"format_id":"a1","ext":"m4a","vcodec":"none","acodec":"aac"}],"extractor_key":"Example"}"#

    func testShareTextPreservesSignedQueryAndRemovesSentenceWrappers() throws {
        let source = "4.72 复制打开抖音（https://v.douyin.com/abc/?x=1&token=a%2Fb%3D）。 YouTube: <https://www.youtube.com/watch?v=x&list=y> 重复 https://v.douyin.com/abc/?x=1&token=a%2Fb%3D"
        let urls = ShareLinkParser.urls(in: source)
        XCTAssertEqual(urls.map(\.absoluteString), [
            "https://v.douyin.com/abc/?x=1&token=a%2Fb%3D",
            "https://www.youtube.com/watch?v=x&list=y"
        ])
        XCTAssertTrue(ShareLinkParser.urls(in: "file:///etc/passwd ftp://test.com https://user:password@example.com").isEmpty)
        XCTAssertEqual(ShareLinkParser.urls(in: "(https://example.com/a_(b))").first?.absoluteString, "https://example.com/a_(b)")
    }

    func testResolveUsesStructuredMetadataAndNoImplicitCookies() async throws {
        let runner = RecordingRunner { _ in ProcessResult(exitCode: 0, stdout: Data(self.metadataJSON.utf8)) }
        let engine = DownloadEngine(tools: tools, environment: ["DENO_DIR": "/tmp/test-deno"], runner: runner)
        let original = "https://video.example/watch?v=abc&signature=foo%2Bbar"
        let info = try await engine.resolve(shareText: "请下载 \(original)")
        XCTAssertEqual(info.title, "中文标题")
        XCTAssertEqual(info.sourceURL.absoluteString, original)
        XCTAssertEqual(info.availableHeights, [1080])
        XCTAssertEqual(info.duration, 12.5)
        XCTAssertFalse(info.formats[0].hasAudio)
        XCTAssertFalse(info.formats[1].hasVideo)
        let command = try XCTUnwrap(runner.commands.first)
        XCTAssertTrue(command.arguments.contains("--ignore-config"))
        XCTAssertTrue(command.arguments.contains("--no-plugin-dirs"))
        XCTAssertTrue(command.arguments.contains("--no-cookies"))
        XCTAssertTrue(command.arguments.contains("--no-cookies-from-browser"))
        XCTAssertFalse(command.arguments.contains("--cookies-from-browser"))
        XCTAssertTrue(command.arguments.contains("--skip-download"))
        XCTAssertEqual(Array(command.arguments.suffix(2)), ["--", original])
        XCTAssertEqual(command.environment["DENO_DIR"], "/tmp/test-deno")
    }

    func testDownloadOnlyAcceptsStructuredProgressAndAfterMoveFile() async throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let final = folder.appendingPathComponent("测试视频 [abc].mp4")
        try Data("video-content".utf8).write(to: final)
        let recorder = ProgressRecorder()
        let runner = RecordingRunner { _ in ProcessResult(exitCode: 0) }
        runner.outputs = [
            ProcessOutput(channel: .stdout, line: "[download] 100% fake file.mp4"),
            ProcessOutput(channel: .stderr, line: "__FEATHER_PROGRESS__{\"downloaded_bytes\":99,\"total_bytes\":100}"),
            ProcessOutput(channel: .stdout, line: "__FEATHER_PROGRESS__{\"status\":\"downloading\",\"downloaded_bytes\":25,\"total_bytes\":100,\"speed\":2048,\"eta\":3}"),
            ProcessOutput(channel: .stdout, line: "__FEATHER_FINAL__" + String(data: try JSONEncoder().encode(final.path), encoding: .utf8)!)
        ]
        let info = VideoMetadata(id: "abc", sourceURL: URL(string: "https://video.example/watch?v=abc&x=$(touch%20bad)")!, title: "Test")
        let result = try await DownloadEngine(tools: tools, runner: runner).download(metadata: info, quality: .p720, directory: folder) { progress in
            recorder.add(progress)
        }
        XCTAssertEqual(result.fileURL, final)
        XCTAssertEqual(recorder.values.count, 1)
        XCTAssertEqual(recorder.values[0].fraction, 0.99)
        let command = try XCTUnwrap(runner.commands.first)
        XCTAssertEqual(Array(command.arguments.suffix(2)), ["--", info.sourceURL.absoluteString])
        XCTAssertTrue(command.arguments.contains("bv*[height<=720]+ba/b[height<=720]"))
        XCTAssertTrue(command.arguments.contains("after_move:__FEATHER_FINAL__%(filepath)j"))
    }

    func testExitZeroAndOrdinaryStdoutCannotClaimCompletion() async throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let runner = RecordingRunner { _ in ProcessResult(exitCode: 0, stdout: Data("[download] 100% Done".utf8)) }
        do {
            _ = try await DownloadEngine(tools: tools, runner: runner).download(
                metadata: VideoMetadata(id: "a", sourceURL: URL(string: "https://example.com/a")!, title: "Test"),
                quality: .best, directory: folder)
            XCTFail("An unverified filename must not count as completion")
        } catch DownloadError.missingFinalFile { }
    }

    func testVerifiedCompletedDownloadWinsCancellationAfterHelperSuccess() async throws {
        let directory = temporaryFolder(); defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let final = directory.appendingPathComponent("already-downloaded.mp4")
        try Data("complete-video".utf8).write(to: final)
        let runner = RecordingRunner { _ in
            withUnsafeCurrentTask { $0?.cancel() }
            return ProcessResult(exitCode: 0)
        }
        runner.outputs = [ProcessOutput(channel: .stdout, line: "__FEATHER_FINAL__" + String(data: try JSONEncoder().encode(final.path), encoding: .utf8)!)]
        let engine = DownloadEngine(tools: tools, runner: runner)
        let task = Task {
            try await engine.download(metadata: VideoMetadata(id: "saved", sourceURL: URL(string: "https://example.com/video")!, title: "Saved"),
                                      quality: .best, directory: directory)
        }
        let result = try await task.value
        XCTAssertTrue(task.isCancelled)
        XCTAssertEqual(result.fileURL, final)
        CoreResourceReport.record("verified_success_wins_late_cancellation", elapsed: 0,
                                  detail: ["nonemptyAfterMoveFileRequired": true, "lateTaskCancellation": true])
    }

    func testExplicitCookieFileIsPrivateTemporaryCopyAndRemoved() async throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let original = folder.appendingPathComponent("cookies.txt")
        let cookieContent = "# Netscape HTTP Cookie File\n.example.com\tTRUE\t/\tTRUE\t9999999999\tsession\tsecret\n"
        try cookieContent.write(to: original, atomically: true, encoding: .utf8)
        let runner = RecordingRunner { command in
            let flag = command.arguments.firstIndex(of: "--cookies")!
            let copy = URL(fileURLWithPath: command.arguments[flag + 1])
            XCTAssertNotEqual(copy, original)
            let actualContent = try String(contentsOf: copy, encoding: .utf8)
            XCTAssertEqual(actualContent, cookieContent)
            let permissions = try FileManager.default.attributesOfItem(atPath: copy.path)[.posixPermissions] as? NSNumber
            XCTAssertEqual(permissions?.intValue, 0o600)
            return ProcessResult(exitCode: 0, stdout: Data(self.metadataJSON.utf8))
        }
        _ = try await DownloadEngine(tools: tools, runner: runner).resolve(shareText: "https://example.com/a", authentication: .netscapeFile(original))
        let command = runner.commands[0]
        let copiedPath = command.arguments[command.arguments.firstIndex(of: "--cookies")! + 1]
        XCTAssertFalse(FileManager.default.fileExists(atPath: copiedPath))
        let savedContent = try String(contentsOf: original, encoding: .utf8)
        XCTAssertEqual(savedContent, cookieContent)
    }

    func testZeroByteFileCannotClaimCompletion() async throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let final = folder.appendingPathComponent("empty.mp4")
        try Data().write(to: final)
        let runner = RecordingRunner { _ in ProcessResult(exitCode: 0) }
        runner.outputs = [ProcessOutput(channel: .stdout, line: "__FEATHER_FINAL__" + String(data: try JSONEncoder().encode(final.path), encoding: .utf8)!)]
        do {
            _ = try await DownloadEngine(tools: tools, runner: runner).download(
                metadata: VideoMetadata(id: "a", sourceURL: URL(string: "https://example.com/a")!, title: "Test"),
                quality: .best, directory: folder)
            XCTFail("A zero-byte file is not complete")
        } catch DownloadError.missingFinalFile { }
    }

    func testKuaishouShareRedirectUsesOfficialAPIAndPreservesOriginal() async throws {
        let original = URL(string: "https://v.kuaishou.com/EXAMPLE")!
        let redirected = URL(string: "https://www.kuaishou.com/short-video/3x5jvmsmmiahx3m?authorId=3xt4m66xxjt3qgq&shareToken=retain")!
        let response = #"{"data":{"result":1,"currentWork":{"id":"3x5jvmsmmiahx3m","playUrl":"https://tymov2.a.kwimgs.com/video.mp4?signature=a%2Fb&tt=b","poster":"https://p2.a.yximgs.com/poster.jpg","width":1280,"height":720,"author":{"name":"作者"}}}}"#
        let http = FixtureHTTP { url in
            if url == original { return HTTPFetchResult(data: Data(), finalURL: redirected, statusCode: 200) }
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
            XCTAssertEqual(url.host, "live.kuaishou.com")
            XCTAssertEqual(url.path, "/live_api/profile/feedbyid")
            XCTAssertEqual(query?.first(where: { $0.name == "photoId" })?.value, "3x5jvmsmmiahx3m")
            XCTAssertEqual(query?.first(where: { $0.name == "principalId" })?.value, "3xt4m66xxjt3qgq")
            return HTTPFetchResult(data: Data(response.utf8), finalURL: url, statusCode: 200)
        }
        let runner = RecordingRunner { _ in XCTFail("The adapter should resolve without launching yt-dlp"); return ProcessResult(exitCode: 1) }
        let info = try await DownloadEngine(tools: tools, runner: runner, http: http).resolve(shareText: "快手 \(original)")
        XCTAssertEqual(info.sourceURL, original)
        XCTAssertEqual(info.webpageURL, redirected)
        XCTAssertEqual(info.resolvedMediaURL?.absoluteString, "https://tymov2.a.kwimgs.com/video.mp4?signature=a%2Fb&tt=b")
        XCTAssertEqual(info.httpHeaders["Referer"], "https://live.kuaishou.com/")
        XCTAssertEqual(info.availableHeights, [720])
        XCTAssertEqual(info.title, "快手视频 · 作者")
        XCTAssertEqual(http.requests.count, 2)
        XCTAssertTrue(http.requests.allSatisfy { $0.headers["Cookie"] == nil })
    }

    func testKuaishouMissingAuthorAndUnsafeMediaCannotClaimResolution() async throws {
        let withoutAuthor = URL(string: "https://www.kuaishou.com/short-video/abc")!
        XCTAssertNil(KuaishouAdapter.identity(withoutAuthor))
        XCTAssertFalse(KuaishouAdapter.supports(URL(string: "https://kuaishou.com.evil.example/f/a")!))
        let http = FixtureHTTP { _ in XCTFail("Missing author should not request API"); return HTTPFetchResult(data: Data(), finalURL: withoutAuthor, statusCode: 200) }
        do { _ = try await KuaishouAdapter(http: http).resolve(withoutAuthor); XCTFail("Expected full share link request") }
        catch DownloadError.kuaishouShareLinkRequired { }
        for response in [#"{"data":{"result":21}}"#,
                         #"{"data":{"result":1,"currentWork":{"id":"abc","playUrl":"file:///etc/passwd"}}}"#,
                         #"{"data":{"result":1,"currentWork":{"id":"abc","playUrl":"https://evil.example/video.mp4"}}}"#] {
            do { _ = try KuaishouAdapter.parse(Data(response.utf8), sourceURL: withoutAuthor, webpageURL: withoutAuthor); XCTFail("Expected invalid metadata") }
            catch DownloadError.invalidMetadata { }
        }
    }

    func testEstimatedTotalProgressAndMalformedChannels() {
        let recorder = ProgressRecorder()
        let output = StructuredDownloadOutput { recorder.add($0) }
        output.consume("__FEATHER_PROGRESS__{\"total_bytes\":null,\"total_bytes_estimate\":200,\"downloaded_bytes\":100}")
        output.consume("__FEATHER_PROGRESS__not-json")
        output.consume("__FEATHER_FINAL__\"relative/path.mp4\"")
        XCTAssertEqual(recorder.values.first?.fraction, 0.5)
        XCTAssertNil(output.finalFileURL)
    }

    func testDualStreamsUsePrivateInfoJSONAndCleanItAfterDownload() async throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let final = folder.appendingPathComponent("merged.mp4")
        try Data("merged-video-audio".utf8).write(to: final)
        let metadata = VideoMetadata(id: "dual", sourceURL: URL(string: "https://www.douyin.com/video/123")!, title: "Dual stream",
                                     formats: [MediaFormat(id: "video", width: 1280, height: 720)],
                                     resolvedMediaURL: URL(string: "https://video.douyinvod.com/media-video-signature.mp4?token=secretV")!,
                                     httpHeaders: ["Referer": "https://www.douyin.com/"],
                                     resolvedAudioURL: URL(string: "https://audio.douyinvod.com/media-audio-signature.mp4?token=secretA")!)
        let runner = RecordingRunner { command in
            let flag = try XCTUnwrap(command.arguments.firstIndex(of: "--load-info-json"))
            let file = URL(fileURLWithPath: command.arguments[flag + 1])
            let data = try Data(contentsOf: file)
            let info = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let formats = try XCTUnwrap(info["formats"] as? [[String: Any]])
            XCTAssertEqual(formats.count, 2)
            XCTAssertEqual(formats[0]["url"] as? String, metadata.resolvedMediaURL?.absoluteString)
            XCTAssertEqual(formats[1]["url"] as? String, metadata.resolvedAudioURL?.absoluteString)
            XCTAssertEqual(formats[0]["height"] as? Int, 720)
            XCTAssertTrue(command.arguments.contains("bv+ba"))
            XCTAssertTrue(command.arguments.contains("vcodec:h264,lang,quality,res,fps,hdr:12,acodec:aac"))
            XCTAssertFalse(command.arguments.joined().contains("secretV"))
            XCTAssertFalse(command.arguments.joined().contains("secretA"))
            return ProcessResult(exitCode: 0)
        }
        runner.outputs = [ProcessOutput(channel: .stdout, line: "__FEATHER_FINAL__" + String(data: try JSONEncoder().encode(final.path), encoding: .utf8)!)]
        let result = try await DownloadEngine(tools: tools, runner: runner).download(metadata: metadata, quality: .p720, directory: folder)
        XCTAssertEqual(result.fileURL, final)
        let arguments = runner.commands[0].arguments
        let file = arguments[arguments.firstIndex(of: "--load-info-json")! + 1]
        XCTAssertFalse(FileManager.default.fileExists(atPath: file))
    }

    func testDirectMediaCannotSilentlyExceedRequestedHeight() async throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let runner = RecordingRunner { _ in XCTFail("Oversize source should never launch a download"); return ProcessResult(exitCode: 0) }
        for heights in [[MediaFormat(id: "source", height: 1080)], []] {
            let metadata = VideoMetadata(id: "source", sourceURL: URL(string: "https://www.kuaishou.com/short-video/abc?authorId=def")!,
                                         title: "Source", formats: heights, resolvedMediaURL: URL(string: "https://video.kwimgs.com/a.mp4")!)
            do {
                _ = try await DownloadEngine(tools: tools, runner: runner).download(metadata: metadata, quality: .p720, directory: folder)
                XCTFail("A direct source with unknown/greater height must not be labelled 720p")
            } catch DownloadError.processFailed(_, let detail) {
                XCTAssertTrue(detail.contains("Requested format"))
            }
        }
    }

    func testDouyinFailureUsesAnonymousBrowserFallbackWithOriginalURL() async throws {
        let source = URL(string: "https://www.douyin.com/video/7697905487832958400?share=retained")!
        let expected = VideoMetadata(id: "7697905487832958400", sourceURL: source, title: "Matched original video",
                                     resolvedMediaURL: URL(string: "https://www.douyinvod.com/original.mp4")!)
        let runner = RecordingRunner { _ in ProcessResult(exitCode: 1, stderr: Data("fresh cookies required".utf8)) }
        let engine = DownloadEngine(tools: tools, runner: runner, browserResolver: { url in
            XCTAssertEqual(url, source)
            return expected
        })
        let result = try await engine.resolve(shareText: "复制 \(source.absoluteString)")
        XCTAssertEqual(result, expected)
        XCTAssertEqual(runner.commands.count, 1)
    }

    func testCancellationNeverStartsBrowserFallback() async throws {
        let source = "https://www.douyin.com/video/7697905487832958400"
        let runner = RecordingRunner { _ in throw CancellationError() }
        let engine = DownloadEngine(tools: tools, runner: runner, browserResolver: { _ in
            XCTFail("Cancelling yt-dlp must never start a browser")
            throw DownloadError.invalidMetadata
        })
        do { _ = try await engine.resolve(shareText: source); XCTFail("Expected cancellation") }
        catch is CancellationError { }
    }

    func testAudioDownloadCannotReuseEarlierVideoFilename() async throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let original = folder.appendingPathComponent("Original [id].mp4")
        let final = folder.appendingPathComponent("Original [id] · 音频.m4a")
        try Data("original video".utf8).write(to: original)
        try Data("audio".utf8).write(to: final)
        let runner = RecordingRunner { command in
            let index = try XCTUnwrap(command.arguments.firstIndex(of: "--output"))
            XCTAssertTrue(command.arguments[index + 1].contains("· 音频"))
            XCTAssertTrue(command.arguments.contains("--extract-audio"))
            XCTAssertTrue(command.arguments.contains("m4a"))
            return ProcessResult(exitCode: 0)
        }
        runner.outputs = [ProcessOutput(channel: .stdout, line: "__FEATHER_FINAL__" + String(data: try JSONEncoder().encode(final.path), encoding: .utf8)!)]
        let metadata = VideoMetadata(id: "id", sourceURL: URL(string: "https://example.com/video")!, title: "Original")
        let result = try await DownloadEngine(tools: tools, runner: runner).download(metadata: metadata, quality: .audio, directory: folder)
        XCTAssertEqual(result.fileURL, final)
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
    }

    func testRejectsPlaylistAndLiveMetadata() async throws {
        for input in [#"{"_type":"playlist","entries":[],"id":"x","title":"Collection"}"#,
                      #"{"id":"x","title":"Live","is_live":true}"#] {
            let runner = RecordingRunner { _ in ProcessResult(exitCode: 0, stdout: Data(input.utf8)) }
            do {
                _ = try await DownloadEngine(tools: tools, runner: runner).resolve(shareText: "https://example.com/a")
                XCTFail("Expected collection/live rejection")
            } catch is DownloadError { }
        }
    }

    func testFailureDoesNotExposeCredentialBearingURL() async throws {
        let detail = "ERROR: HTTP Error 403: Forbidden at https://example.com/?token=TOP_SECRET"
        let runner = RecordingRunner { _ in ProcessResult(exitCode: 1, stderr: Data(detail.utf8)) }
        do {
            _ = try await DownloadEngine(tools: tools, runner: runner).resolve(shareText: "https://example.com/a")
            XCTFail("Expected failure")
        } catch {
            XCTAssertFalse(error.localizedDescription.contains("TOP_SECRET"))
            XCTAssertTrue(error.localizedDescription.contains("拒绝"))
        }
    }

    func testXMissingMediaReportsVisibilityWithoutInventingDeletion() {
        for detail in ["ERROR: [twitter] 2111774420838814156: Video #1 is unavailable",
                       "ERROR: [twitter] 2111774420838814156: No video could be found in this tweet"] {
            XCTAssertEqual(DownloadError.processFailed(1, detail).localizedDescription, DownloadError.xMediaVisibilityMessage)
        }
        CoreResourceReport.record("x_actual_no_media_errors_are_visibility_neutral", elapsed: 0,
                                  detail: ["indexedError": true, "noMediaError": true, "actualLoginMenuNamed": true])
    }

    func testGenericUnavailableDoesNotInventDeletionOrRegion() {
        for detail in ["ERROR: Video unavailable", "ERROR: This video is not available", "ERROR: No video formats found"] {
            let message = DownloadError.processFailed(1, detail).localizedDescription
            XCTAssertTrue(message.contains("没有返回可下载"))
            XCTAssertFalse(message.contains("已被删除"))
            XCTAssertFalse(message.contains("当前地区"))
        }
    }

    func testExplicitPlatformRestrictionsRemainSpecific() {
        for (detail, expected) in [
            ("ERROR: This video is private", "访问权限"),
            ("ERROR: This video has been deleted", "已被删除"),
            ("ERROR: The uploader has not made available in your country", "当前地区"),
            ("ERROR: Sign in to confirm your age", "登录状态"),
            ("ERROR: HTTP Error 429: Too Many Requests", "请求频率"),
            ("ERROR: Requested format is not available", "所选清晰度"),
            ("ERROR: Unsupported URL", "暂时无法解析")
        ] { XCTAssertTrue(DownloadError.processFailed(1, detail).localizedDescription.contains(expected), detail) }
    }

    func testActualFailureWinsWarningsAndURLKeywords() {
        let warning = "WARNING: Cookies unavailable; private video cache removed\n"
        let detail = warning + "ERROR: Network connection failed for https://example.com/private?token=TOP_SECRET&cookies=unavailable"
        let message = DownloadError.processFailed(1, detail).localizedDescription
        XCTAssertTrue(message.contains("网络连接"))
        XCTAssertFalse(message.contains("TOP_SECRET"))
        XCTAssertFalse(message.contains("访问权限"))
    }

    func testXResolveKeepsIndexedURLAndRequiresExplicitBrowserAuthentication() async throws {
        let original = "https://x.com/example/status/2111774420838814156/video/1?s=46"
        let anonymous = RecordingRunner { _ in
            ProcessResult(exitCode: 1, stderr: Data("ERROR: [twitter] 2111774420838814156: Video #1 is unavailable".utf8))
        }
        do {
            _ = try await DownloadEngine(tools: tools, runner: anonymous).resolve(shareText: original)
            XCTFail("Anonymous missing media must remain a failed resolve")
        } catch {
            XCTAssertEqual(error.localizedDescription, DownloadError.xMediaVisibilityMessage)
        }
        XCTAssertEqual(anonymous.commands.count, 1)
        let anonCommand = try XCTUnwrap(anonymous.commands.first)
        XCTAssertTrue(anonCommand.arguments.contains("--no-cookies-from-browser"))
        XCTAssertFalse(anonCommand.arguments.contains("--cookies-from-browser"))
        XCTAssertEqual(Array(anonCommand.arguments.suffix(2)), ["--", original])
        let authenticated = RecordingRunner { _ in ProcessResult(exitCode: 0, stdout: Data(self.metadataJSON.utf8)) }
        let metadata = try await DownloadEngine(tools: tools, runner: authenticated).resolve(shareText: original, authentication: .browser(.chrome))
        XCTAssertEqual(metadata.sourceURL.absoluteString, original)
        XCTAssertEqual(authenticated.commands.count, 1)
        let command = try XCTUnwrap(authenticated.commands.first)
        let cookieIndex = try XCTUnwrap(command.arguments.firstIndex(of: "--cookies-from-browser"))
        XCTAssertEqual(command.arguments[cookieIndex + 1], "chrome")
        XCTAssertFalse(command.arguments.contains("--no-cookies-from-browser"))
        XCTAssertTrue(command.arguments.contains("--skip-download"))
        XCTAssertEqual(Array(command.arguments.suffix(2)), ["--", original])
        CoreResourceReport.record("x_original_url_explicit_auth_only", elapsed: 0,
                                  detail: ["anonymousResolverCount": 1, "automaticCookieRead": false,
                                           "explicitChromeMetadataSucceeds": true, "indexedQueryURLPreserved": true])
    }

    func testProcessRunnerPreservesLiteralArgumentsAndDrainsOutput() async throws {
        let literal = "spaces 中文 & $(touch /tmp/feather-should-not-run)"
        let result = try await FoundationProcessRunner().run(ProcessCommand(
            executable: URL(fileURLWithPath: "/usr/bin/printf"), arguments: ["%s", literal]))
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(String(decoding: result.stdout, as: UTF8.self), literal)
    }

    func testProcessRunnerDeliversFirstLineWhileRealChildIsStillRunning() async throws {
        let start = Date()
        let recorder = OutputTimingRecorder()
        let result = try await FoundationProcessRunner().run(ProcessCommand(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf 'first\\n'; /bin/sleep 1; printf 'second\\n'"], timeout: 5
        )) { output in
            guard case .stdout = output.channel else { return }
            recorder.add(line: output.line, elapsed: Date().timeIntervalSince(start))
        }
        let exitTime = Date().timeIntervalSince(start)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(String(decoding: result.stdout, as: UTF8.self), "first\nsecond\n")
        let lines = recorder.values
        XCTAssertEqual(lines.count, 2)
        guard lines.count == 2 else { return }
        XCTAssertEqual(lines[0].line, "first")
        XCTAssertEqual(lines[1].line, "second")
        // A fill-until-EOF reader delivers both at exit; a live reader delivers first
        // before the child's one-second sleep, comfortably ahead of the final line.
        XCTAssertLessThan(lines[0].elapsed, exitTime - 0.5)
        XCTAssertLessThan(lines[0].elapsed, lines[1].elapsed - 0.5)
    }

    func testProcessRunnerTimeoutAndTaskCancellationActuallyStopProcess() async throws {
        let runner = FoundationProcessRunner()
        let beginning = Date()
        do {
            _ = try await runner.run(ProcessCommand(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["20"], timeout: 0.1))
            XCTFail("Expected timeout")
        } catch DownloadError.timedOut { }
        XCTAssertLessThan(Date().timeIntervalSince(beginning), 3)
        let task = Task {
            try await runner.run(ProcessCommand(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["20"], timeout: 30))
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError { }
        XCTAssertLessThan(Date().timeIntervalSince(beginning), 3)
    }

    func testProcessOutputLimitStopsUnboundedOutput() async throws {
        do {
            _ = try await FoundationProcessRunner().run(ProcessCommand(
                executable: URL(fileURLWithPath: "/usr/bin/yes"), arguments: [], timeout: 3, maximumOutputBytes: 16_384))
            XCTFail("Expected bounded output error")
        } catch DownloadError.outputTooLarge { }
    }

    func testIdleWatchdogIgnoresLogsAndRepeatedByteCounts() async throws {
        let start = Date()
        let script = "while :; do printf '__FEATHER_PROGRESS__{\"status\":\"downloading\",\"downloaded_bytes\":100}\\n'; printf 'still waiting\\n' >&2; /bin/sleep 0.04; done"
        do {
            _ = try await FoundationProcessRunner().run(ProcessCommand(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script],
                timeout: 5, preparationTimeout: 0.3, inactivityTimeout: 0.3, progressJSONPrefix: "__FEATHER_PROGRESS__"))
            XCTFail("Repeated logs and unchanged byte counts must not renew a download")
        } catch DownloadError.stalled { }
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 2)
        CoreResourceReport.record("logs_do_not_renew_inactivity", elapsed: elapsed, detail: ["idleLimitSeconds": 0.3])
    }

    func testPreparationAndPostprocessingHaveIndependentDeadlines() async throws {
        for (name, script) in [("first_byte", "/bin/sleep 20"),
                               ("postprocessing", "while :; do printf '__FEATHER_PROGRESS__{\"status\":\"started\",\"postprocessor\":\"ExtractAudio\"}\\n'; /bin/sleep 0.04; done")] {
            let start = Date()
            do {
                _ = try await FoundationProcessRunner().run(ProcessCommand(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script],
                    timeout: 5, preparationTimeout: 0.25, inactivityTimeout: 2, processingTimeout: 0.25, progressJSONPrefix: "__FEATHER_PROGRESS__"))
                XCTFail("A stage cannot wait forever")
            } catch DownloadError.stalled { }
            let elapsed = Date().timeIntervalSince(start)
            XCTAssertLessThan(elapsed, 2)
            CoreResourceReport.record(name + "_deadline", elapsed: elapsed, detail: ["stageLimitSeconds": 0.25])
        }
    }

    func testRealByteGrowthKeepsAHealthyDownloadAlive() async throws {
        let start = Date()
        let script = "for bytes in 1 2 3 4; do printf '__FEATHER_PROGRESS__{\"downloaded_bytes\":%s}\\n' \"$bytes\"; /bin/sleep 0.1; done"
        let result = try await FoundationProcessRunner().run(ProcessCommand(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script],
            timeout: 3, preparationTimeout: 0.3, inactivityTimeout: 0.3, progressJSONPrefix: "__FEATHER_PROGRESS__"))
        XCTAssertEqual(result.exitCode, 0)
        CoreResourceReport.record("real_byte_growth_is_allowed", elapsed: Date().timeIntervalSince(start))
    }

    func testStderrAndCompleteOrIncompleteLongLinesAreBounded() async throws {
        let cases = [("stderr_total", "while :; do printf 'warning\\n' >&2; done", 4_096, 512),
                     ("stdout_complete_line", "printf '%020000d\\n' 0", 65_536, 1_024),
                     ("stderr_incomplete_line", "printf '%020000d' 0 >&2", 65_536, 1_024)]
        for (name, script, errorLimit, lineLimit) in cases {
            let start = Date(), recorder = OutputTimingRecorder()
            do {
                _ = try await FoundationProcessRunner().run(ProcessCommand(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script],
                    timeout: 5, maximumOutputBytes: 65_536, maximumStandardErrorBytes: errorLimit, maximumLineBytes: lineLimit)) { output in
                    XCTAssertTrue(output.line.utf8.count <= lineLimit)
                    recorder.add(line: output.line, elapsed: 0)
                }
                XCTFail("Output budgets must stop the actual child")
            } catch DownloadError.outputTooLarge { }
            let elapsed = Date().timeIntervalSince(start)
            XCTAssertLessThan(elapsed, 2)
            if name != "stderr_total" { XCTAssertEqual(recorder.values.count, 0) }
            CoreResourceReport.record(name + "_bounded", elapsed: elapsed, detail: ["lineLimitBytes": lineLimit, "stderrLimitBytes": errorLimit])
        }
    }

    func testDownloadOutputIsNotRetainedAndProgressFloodIsCoalesced() async throws {
        let start = Date(), recorder = OutputTimingRecorder()
        let result = try await FoundationProcessRunner().run(ProcessCommand(executable: URL(fileURLWithPath: "/usr/bin/printf"),
            arguments: ["first\nsecond\n"], captureStandardOutput: false)) { recorder.add(line: $0.line, elapsed: 0) }
        XCTAssertTrue(result.stdout.isEmpty)
        XCTAssertEqual(recorder.values.count, 2)
        let progress = ProgressRecorder(), output = StructuredDownloadOutput { progress.add($0) }
        for _ in 0..<10_000 { output.consume("__FEATHER_PROGRESS__{\"downloaded_bytes\":100,\"total_bytes\":200}") }
        XCTAssertLessThan(progress.values.count, 10)
        let before = progress.values.count
        output.consume("__FEATHER_PROGRESS__{\"info_dict\":{\"large\":\"ignored\"}}")
        output.consume("__FEATHER_PROGRESS__" + String(repeating: "x", count: 20_000))
        XCTAssertEqual(progress.values.count, before)
        CoreResourceReport.record("progress_capture_and_dispatch_bounded", elapsed: Date().timeIntervalSince(start),
                                  detail: ["inputProgressEvents": 10_000, "emittedProgressEvents": progress.values.count])
    }

    func testParentExitCannotLeaveTermIgnoringChildHoldingPipes() async throws {
        for run in 0..<3 {
            let start = Date(), pids = FixturePIDRecorder()
            let script = "echo ROOT:$$; (trap '' TERM; exec /bin/sleep 20) & echo CHILD:$!; exit 0"
            do {
                _ = try await FoundationProcessRunner().run(ProcessCommand(executable: URL(fileURLWithPath: "/bin/sh"),
                    arguments: ["-c", script], timeout: 5)) { pids.record($0.line) }
                XCTFail("An abandoned inherited pipe must produce a bounded failure")
            } catch DownloadError.helperDidNotExit { }
            let elapsed = Date().timeIntervalSince(start)
            XCTAssertLessThan(elapsed, 2)
            XCTAssertTrue(pids.values.count >= 2)
            XCTAssertTrue(pids.observedGroups.allSatisfy { $0 != getpgrp() })
            for pid in pids.values { XCTAssertFalse(FixturePIDRecorder.isAlive(pid)) }
            CoreResourceReport.record("parent_exit_held_pipe_\(run)", elapsed: elapsed, detail: ["allFixturePIDsStopped": true])
        }
    }

    func testCancellationKillsTermIgnoringGrandchildren() async throws {
        let start = Date(), pids = FixturePIDRecorder()
        let script = "echo ROOT:$$; (trap '' TERM; (trap '' TERM; exec /bin/sleep 20) & echo GRANDCHILD:$!; wait) & echo CHILD:$!; wait"
        let task = Task {
            try await FoundationProcessRunner().run(ProcessCommand(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script], timeout: 5)) { pids.record($0.line) }
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch is CancellationError { }
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 2)
        XCTAssertTrue(pids.values.count >= 3)
        for pid in pids.values { XCTAssertFalse(FixturePIDRecorder.isAlive(pid)) }
        CoreResourceReport.record("cancel_term_ignoring_grandchildren", elapsed: elapsed, detail: ["allFixturePIDsStopped": true])
    }

    func testRSSBudgetStopsRealAllocatingDescendant() async throws {
        let start = Date(), pids = FixturePIDRecorder()
        // A shell leader stays small on both CLT and hosted-Xcode machines.
        // Launch Python as the descendant instead of forking a Python leader:
        // some hosted Python runtimes exceed the old 32 MiB budget themselves.
        let script = """
        printf 'ROOT:%s\\n' "$$"
        /usr/bin/python3 -c 'import os,signal,time
        signal.signal(signal.SIGTERM,signal.SIG_IGN)
        print("CHILD:"+str(os.getpid()),flush=True)
        payload=bytearray(128*1024*1024)
        for i in range(0,len(payload),4096): payload[i]=1
        time.sleep(20)' &
        wait
        """
        do {
            _ = try await FoundationProcessRunner().run(ProcessCommand(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script],
                timeout: 8, maximumMemoryBytes: 96 * 1_024 * 1_024)) { pids.record($0.line) }
            XCTFail("The descendant's real allocated pages must exceed the group budget")
        } catch DownloadError.memoryLimitExceeded { }
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 5)
        XCTAssertTrue(pids.values.count >= 2)
        for pid in pids.values { XCTAssertFalse(FixturePIDRecorder.isAlive(pid)) }
        CoreResourceReport.record("rss_limit_real_descendant", elapsed: elapsed,
            detail: ["rssBudgetBytes": 96 * 1_024 * 1_024, "allocatedTouchedBytes": 128 * 1_024 * 1_024, "sampleIntervalSeconds": 0.5, "allFixturePIDsStopped": true])
    }

    func testFastExitRaceDoesNotRejectOrLeakFileDescriptors() async throws {
        let start = Date(), before = FixturePIDRecorder.openDescriptors()
        for _ in 0..<40 {
            let result = try await FoundationProcessRunner().run(ProcessCommand(executable: URL(fileURLWithPath: "/usr/bin/true"), arguments: [], timeout: 2))
            XCTAssertEqual(result.exitCode, 0)
        }
        let after = FixturePIDRecorder.openDescriptors()
        XCTAssertTrue(after <= before + 2)
        CoreResourceReport.record("fast_exit_race_and_fd_cleanup", elapsed: Date().timeIntervalSince(start),
                                  detail: ["childRuns": 40, "descriptorsBefore": before, "descriptorsAfter": after])
    }

    func testEngineAppliesBudgetsAndWhitelistedProgressTemplates() async throws {
        let folder = temporaryFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let final = folder.appendingPathComponent("video.mp4"); try Data("content".utf8).write(to: final)
        let runner = RecordingRunner { command in
            XCTAssertFalse(command.captureStandardOutput)
            XCTAssertEqual(command.preparationTimeout, 90); XCTAssertEqual(command.inactivityTimeout, 60)
            XCTAssertEqual(command.processingTimeout, 600); XCTAssertLessThan(command.timeout, 6 * 60 * 60)
            XCTAssertEqual(command.maximumMemoryBytes, 768 * 1_024 * 1_024)
            XCTAssertEqual(command.maximumLineBytes, 16 * 1_024)
            XCTAssertFalse(command.arguments.joined().contains("%(progress)j"))
            XCTAssertFalse(command.arguments.joined().contains("info_dict"))
            XCTAssertTrue(command.arguments.joined().contains("%(progress.speed|null)j"))
            XCTAssertTrue(command.arguments.joined().contains("%(progress.total_bytes_estimate|null)j"))
            XCTAssertTrue(command.arguments.joined().contains("%(progress.postprocessor|null)j"))
            return ProcessResult(exitCode: 0)
        }
        runner.outputs = [ProcessOutput(channel: .stdout, line: "__FEATHER_FINAL__" + String(data: try JSONEncoder().encode(final.path), encoding: .utf8)!)]
        _ = try await DownloadEngine(tools: tools, runner: runner).download(metadata: VideoMetadata(id: "x", sourceURL: URL(string: "https://example.com/video")!, title: "Video"), quality: .best, directory: folder)
        CoreResourceReport.record("engine_safety_contract", elapsed: 0, detail: ["whitelistedProgressOnly": true])
    }

    func testEmergencyGuardKeepsOneHeartbeatAndResetsSleepGap() async throws {
        let directory = temporaryFolder(); defer { try? FileManager.default.removeItem(at: directory) }
        let inputs = EmergencyGuardInputs()
        let diagnostic = directory.appendingPathComponent("stop.json")
        var policy = AppEmergencyGuard.Policy()
        policy.cleanupSeconds = 0.05
        let guardrail = AppEmergencyGuard(policy: policy, clock: { inputs.now }, residentBytes: { inputs.bytes },
            enqueueHeartbeat: { inputs.enqueue($0) }, beginShutdown: { inputs.didStop() },
            killRemaining: {}, terminate: { inputs.didTerminate($0) }, diagnosticURL: diagnostic)
        // Unresponsive alone does not exit; only one ping is retained.
        for second in 1...20 { inputs.set(time: Double(second), bytes: 1); guardrail.sample() }
        XCTAssertEqual(inputs.pingCount, 1)
        XCTAssertEqual(inputs.stopCount, 0)
        // A large scheduling gap resets the observation period after sleep.
        inputs.set(time: 100, bytes: 600 * 1_024 * 1_024); guardrail.sample()
        for second in 101...114 { inputs.set(time: Double(second)); guardrail.sample() }
        XCTAssertEqual(inputs.stopCount, 0)
        inputs.set(time: 115); guardrail.sample()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(inputs.stopCount, 1)
        XCTAssertEqual(inputs.exitCodes, [70])
        XCTAssertEqual(inputs.pingCount, 1)
        let data = try Data(contentsOf: diagnostic)
        XCTAssertLessThan(data.count, 4_097)
        let permissions = try FileManager.default.attributesOfItem(atPath: diagnostic.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
        let payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(payload["reason"] as? String, "unresponsive_gui_memory_budget")
        XCTAssertEqual(payload["heartbeatLagSeconds"] as? Double, 15)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("http"))
        CoreResourceReport.record("emergency_guard_combined_budget_single_ping_sleep_reset", elapsed: 0,
            detail: ["maximumPendingHeartbeats": 1, "diagnosticBytes": data.count, "diagnosticPermissions": "0600"])
    }

    func testEmergencyGuardAllowsHealthyHeartbeatsAboveMemoryBudget() throws {
        let inputs = EmergencyGuardInputs()
        let guardrail = AppEmergencyGuard(clock: { inputs.now }, residentBytes: { 600 * 1_024 * 1_024 },
            enqueueHeartbeat: { inputs.enqueue($0) }, beginShutdown: { inputs.didStop() },
            killRemaining: {}, terminate: { inputs.didTerminate($0) })
        for second in 1...40 {
            inputs.set(time: Double(second)); guardrail.sample(); inputs.acknowledge()
        }
        XCTAssertEqual(inputs.pingCount, 40)
        XCTAssertEqual(inputs.stopCount, 0)
        XCTAssertTrue(inputs.exitCodes.isEmpty)
        // A clock discontinuity must not create a false timeout either.
        inputs.set(time: -1); guardrail.sample()
        XCTAssertEqual(inputs.stopCount, 0)
        CoreResourceReport.record("emergency_guard_healthy_heartbeat", elapsed: 0,
            detail: ["highMemoryHealthyTicks": 40, "triggered": false])
    }

    #if FEATHER_STANDALONE
    func testEmergencyGuardReallyExitsHungFixtureAndCleansOnlyOwnedGroups() async throws {
        let directory = temporaryFolder(); defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let start = Date()
        let result = try await FoundationProcessRunner().run(ProcessCommand(
            executable: URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL,
            arguments: ["--emergency-guard-fixture", directory.path], timeout: 7))
        XCTAssertEqual(result.exitCode, 70)
        XCTAssertLessThan(Date().timeIntervalSince(start), 4)
        let pids = try String(contentsOf: directory.appendingPathComponent("pids"), encoding: .utf8)
            .split(separator: "\n").compactMap { pid_t($0) }
        XCTAssertTrue(pids.count >= 2)
        for pid in pids { XCTAssertFalse(FixturePIDRecorder.isAlive(pid)) }
        let rejected = try String(contentsOf: directory.appendingPathComponent("launch-rejected"), encoding: .utf8)
        XCTAssertEqual(rejected, "true")
        let diagnostic = try Data(contentsOf: directory.appendingPathComponent("stop.json"))
        XCTAssertLessThan(diagnostic.count, 4_097)
        CoreResourceReport.record("emergency_guard_real_hung_main_and_owned_cleanup", elapsed: Date().timeIntervalSince(start),
            detail: ["exitCode": result.exitCode, "allFixturePIDsStopped": true,
                     "newLaunchRejectedAfterShutdown": true, "actualMainAllocationBytes": 96 * 1_024 * 1_024,
                     "testBudgetBytes": 32 * 1_024 * 1_024, "testHeartbeatSeconds": 0.25, "cleanupSeconds": 1.8])
    }

    func testEmergencyGuardRealHealthyMainDoesNotExit() async throws {
        let directory = temporaryFolder(); defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let start = Date()
        let result = try await FoundationProcessRunner().run(ProcessCommand(
            executable: URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL,
            arguments: ["--emergency-guard-healthy-fixture", directory.path], timeout: 5))
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("stop.json").path))
        CoreResourceReport.record("emergency_guard_real_healthy_main", elapsed: Date().timeIntervalSince(start),
            detail: ["exitCode": result.exitCode, "aboveRSSBudget": true, "triggered": false])
    }
    #endif

    private func temporaryFolder() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("FeatherCoreTests-" + UUID().uuidString, isDirectory: true)
    }
}

private final class FixtureHTTP: HTTPFetching, @unchecked Sendable {
    struct Request { let url: URL; let headers: [String: String] }
    private let lock = NSLock()
    private var storage: [Request] = []
    var requests: [Request] { lock.lock(); defer { lock.unlock() }; return storage }
    let body: @Sendable (URL) throws -> HTTPFetchResult
    init(body: @escaping @Sendable (URL) throws -> HTTPFetchResult) { self.body = body }
    func fetch(_ url: URL, headers: [String: String]) async throws -> HTTPFetchResult { record(url, headers); return try body(url) }
    private func record(_ url: URL, _ headers: [String: String]) { lock.lock(); defer { lock.unlock() }; storage.append(Request(url: url, headers: headers)) }
}

private final class EmergencyGuardInputs: @unchecked Sendable {
    private let lock = NSLock()
    private var time: TimeInterval = 0
    private var memory: UInt64 = 0
    private var pending: (@Sendable () -> Void)?
    private var pings = 0
    private var stops = 0
    private var exits: [Int32] = []
    var now: TimeInterval { lock.lock(); defer { lock.unlock() }; return time }
    var bytes: UInt64 { lock.lock(); defer { lock.unlock() }; return memory }
    var pingCount: Int { lock.lock(); defer { lock.unlock() }; return pings }
    var stopCount: Int { lock.lock(); defer { lock.unlock() }; return stops }
    var exitCodes: [Int32] { lock.lock(); defer { lock.unlock() }; return exits }
    func set(time: TimeInterval, bytes: UInt64? = nil) {
        lock.lock(); defer { lock.unlock() }; self.time = time
        if let bytes { memory = bytes }
    }
    func enqueue(_ callback: @escaping @Sendable () -> Void) {
        lock.lock(); defer { lock.unlock() }; pings += 1; pending = callback
    }
    func acknowledge() {
        lock.lock(); let callback = pending; pending = nil; lock.unlock(); callback?()
    }
    func didStop() { lock.lock(); stops += 1; lock.unlock() }
    func didTerminate(_ code: Int32) { lock.lock(); exits.append(code); lock.unlock() }
}

private final class RecordingRunner: ProcessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [ProcessCommand] = []
    var commands: [ProcessCommand] { lock.lock(); defer { lock.unlock() }; return recorded }
    var outputs: [ProcessOutput] = []
    let body: @Sendable (ProcessCommand) throws -> ProcessResult
    init(body: @escaping @Sendable (ProcessCommand) throws -> ProcessResult) { self.body = body }
    func run(_ command: ProcessCommand, onOutput: @escaping @Sendable (ProcessOutput) -> Void) async throws -> ProcessResult {
        record(command)
        let result = try body(command)
        outputs.forEach(onOutput)
        return result
    }
    private func record(_ command: ProcessCommand) { lock.lock(); defer { lock.unlock() }; recorded.append(command) }
}

private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [DownloadProgress] = []
    var values: [DownloadProgress] { lock.lock(); defer { lock.unlock() }; return storage }
    func add(_ value: DownloadProgress) { lock.lock(); defer { lock.unlock() }; storage.append(value) }
}

private final class OutputTimingRecorder: @unchecked Sendable {
    struct Entry { let line: String; let elapsed: TimeInterval }
    private let lock = NSLock()
    private var storage: [Entry] = []
    var values: [Entry] { lock.lock(); defer { lock.unlock() }; return storage }
    func add(line: String, elapsed: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        storage.append(Entry(line: line, elapsed: elapsed))
    }
}

private final class FixturePIDRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var pids: [pid_t] = []
    private var groups: [pid_t] = []
    var values: [pid_t] { lock.lock(); defer { lock.unlock() }; return pids }
    var observedGroups: [pid_t] { lock.lock(); defer { lock.unlock() }; return groups }
    func record(_ line: String) {
        guard ["ROOT:", "CHILD:", "GRANDCHILD:"].contains(where: line.hasPrefix),
              let value = line.split(separator: ":").last, let pid = pid_t(value), pid > 0 else { return }
        lock.lock(); pids.append(pid)
        let group = getpgid(pid); if group > 0 { groups.append(group) }
        lock.unlock()
    }
    static func isAlive(_ pid: pid_t) -> Bool {
        var info = proc_bsdinfo()
        let size = withUnsafeMutablePointer(to: &info) { proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, $0, Int32(MemoryLayout<proc_bsdinfo>.size)) }
        return size > 0 && info.pbi_status != UInt32(SZOMB)
    }
    static func openDescriptors() -> Int { (0..<256).reduce(0) { $0 + (fcntl(Int32($1), F_GETFD) >= 0 ? 1 : 0) } }
}

private enum CoreResourceReport {
    static let lock = NSLock()
    static var rows: [[String: Any]] = []
    static func record(_ name: String, elapsed: TimeInterval, detail: [String: Any] = [:]) {
        lock.lock(); defer { lock.unlock() }
        rows.append(["case": name, "passed": true, "elapsedSeconds": elapsed, "details": detail])
    }
    static func write(totalTests: Int, elapsed: TimeInterval) throws {
        guard let path = ProcessInfo.processInfo.environment["FEATHER_CORE_REPORT"] else { return }
        let report: [String: Any] = ["version": "0.2.1", "passed": true, "testCount": totalTests,
            "mode": "same XCTest bodies via FEATHER_STANDALONE on CLT-only host", "elapsedSeconds": elapsed,
            "newResourceCases": rows,
            "productionDefaults": ["rssBudgetBytes": 768 * 1_024 * 1_024, "rssSampleSeconds": 0.5,
                "preparationSeconds": 90, "noByteProgressSeconds": 60, "processingStageSeconds": 600,
                "totalSeconds": 5_400, "stdoutBudgetBytes": 8 * 1_024 * 1_024, "stderrBudgetBytes": 512 * 1_024,
                "lineBudgetBytes": 16 * 1_024, "downloadStdoutRetained": false],
            "scope": "Only self-spawned isolated process groups; no system WebKit or other apps signalled"]
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
    }
}

#if FEATHER_STANDALONE
/// Run the exact same regression cases on Macs with Command Line Tools but no XCTest/Xcode.
@main
private struct StandaloneCoreTests {
    static func main() async throws {
        if CommandLine.arguments.count == 3,
           ["--emergency-guard-fixture", "--emergency-guard-healthy-fixture"].contains(CommandLine.arguments[1]) {
            try await runEmergencyGuardFixture(directory: URL(fileURLWithPath: CommandLine.arguments[2]),
                healthy: CommandLine.arguments[1] == "--emergency-guard-healthy-fixture")
            return
        }
        let start = Date()
        let tests = DownloadCoreTests()
        try tests.testShareTextPreservesSignedQueryAndRemovesSentenceWrappers()
        try await tests.testResolveUsesStructuredMetadataAndNoImplicitCookies()
        try await tests.testDownloadOnlyAcceptsStructuredProgressAndAfterMoveFile()
        try await tests.testExitZeroAndOrdinaryStdoutCannotClaimCompletion()
        try await tests.testExplicitCookieFileIsPrivateTemporaryCopyAndRemoved()
        try await tests.testZeroByteFileCannotClaimCompletion()
        try await tests.testKuaishouShareRedirectUsesOfficialAPIAndPreservesOriginal()
        try await tests.testKuaishouMissingAuthorAndUnsafeMediaCannotClaimResolution()
        tests.testEstimatedTotalProgressAndMalformedChannels()
        try await tests.testDualStreamsUsePrivateInfoJSONAndCleanItAfterDownload()
        try await tests.testDirectMediaCannotSilentlyExceedRequestedHeight()
        try await tests.testDouyinFailureUsesAnonymousBrowserFallbackWithOriginalURL()
        try await tests.testCancellationNeverStartsBrowserFallback()
        try await tests.testAudioDownloadCannotReuseEarlierVideoFilename()
        try await tests.testRejectsPlaylistAndLiveMetadata()
        try await tests.testFailureDoesNotExposeCredentialBearingURL()
        tests.testXMissingMediaReportsVisibilityWithoutInventingDeletion()
        tests.testGenericUnavailableDoesNotInventDeletionOrRegion()
        tests.testExplicitPlatformRestrictionsRemainSpecific()
        tests.testActualFailureWinsWarningsAndURLKeywords()
        try await tests.testXResolveKeepsIndexedURLAndRequiresExplicitBrowserAuthentication()
        try await tests.testProcessRunnerPreservesLiteralArgumentsAndDrainsOutput()
        try await tests.testProcessRunnerDeliversFirstLineWhileRealChildIsStillRunning()
        try await tests.testProcessRunnerTimeoutAndTaskCancellationActuallyStopProcess()
        try await tests.testProcessOutputLimitStopsUnboundedOutput()
        try await tests.testIdleWatchdogIgnoresLogsAndRepeatedByteCounts()
        try await tests.testPreparationAndPostprocessingHaveIndependentDeadlines()
        try await tests.testRealByteGrowthKeepsAHealthyDownloadAlive()
        try await tests.testStderrAndCompleteOrIncompleteLongLinesAreBounded()
        try await tests.testDownloadOutputIsNotRetainedAndProgressFloodIsCoalesced()
        try await tests.testParentExitCannotLeaveTermIgnoringChildHoldingPipes()
        try await tests.testCancellationKillsTermIgnoringGrandchildren()
        try await tests.testRSSBudgetStopsRealAllocatingDescendant()
        try await tests.testFastExitRaceDoesNotRejectOrLeakFileDescriptors()
        try await tests.testEngineAppliesBudgetsAndWhitelistedProgressTemplates()
        try await tests.testVerifiedCompletedDownloadWinsCancellationAfterHelperSuccess()
        try await tests.testEmergencyGuardKeepsOneHeartbeatAndResetsSleepGap()
        try tests.testEmergencyGuardAllowsHealthyHeartbeatsAboveMemoryBudget()
        try await tests.testEmergencyGuardReallyExitsHungFixtureAndCleansOnlyOwnedGroups()
        try await tests.testEmergencyGuardRealHealthyMainDoesNotExit()
        try CoreResourceReport.write(totalTests: 40, elapsed: Date().timeIntervalSince(start))
        print("PASS: 40 DownloadCore regression tests including X visibility diagnostics and explicit authentication.")
    }

    private static func runEmergencyGuardFixture(directory: URL, healthy: Bool) async throws {
        let payload = UnsafeMutableRawPointer.allocate(byteCount: 96 * 1_024 * 1_024, alignment: 4_096)
        payload.initializeMemory(as: UInt8.self, repeating: 1, count: 96 * 1_024 * 1_024)
        defer { payload.deallocate() }
        if !healthy {
            let pidFile = directory.appendingPathComponent("pids")
            FileManager.default.createFile(atPath: pidFile.path, contents: Data(), attributes: [.posixPermissions: 0o600])
            let handle = try FileHandle(forWritingTo: pidFile)
            let script = "echo ROOT:$$; (trap '' TERM; exec /bin/sleep 20) & echo CHILD:$!; trap '' TERM; wait"
            Task.detached {
                _ = try? await FoundationProcessRunner().run(ProcessCommand(executable: URL(fileURLWithPath: "/bin/sh"),
                    arguments: ["-c", script], timeout: 10, maximumMemoryBytes: nil)) { line in
                    if let pid = line.line.split(separator: ":").last, pid_t(pid) != nil {
                        try? handle.write(contentsOf: Data((pid + "\n").utf8))
                    }
                }
                try? handle.close()
            }
            for _ in 0..<100 {
                let text = (try? String(contentsOf: pidFile, encoding: .utf8)) ?? ""
                if text.split(separator: "\n").count >= 2 { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
        }
        var policy = AppEmergencyGuard.Policy()
        policy.interval = 0.05; policy.unresponsiveSeconds = 0.25
        policy.residentByteBudget = 32 * 1_024 * 1_024; policy.resetGapSeconds = 2
        let guardrail = AppEmergencyGuard(policy: policy, diagnosticURL: directory.appendingPathComponent("stop.json"))
        guardrail.startMonitoring()
        if healthy {
            try await Task.sleep(nanoseconds: 1_000_000_000)
            guardrail.stopMonitoring()
        } else {
            Task.detached {
                try? await Task.sleep(nanoseconds: 700_000_000)
                var rejected = false
                do {
                    _ = try await FoundationProcessRunner().run(ProcessCommand(executable: URL(fileURLWithPath: "/usr/bin/true"), arguments: []))
                } catch is CancellationError { rejected = true } catch { }
                try? String(rejected).write(to: directory.appendingPathComponent("launch-rejected"), atomically: true, encoding: .utf8)
            }
            DispatchQueue.main.async { while true { usleep(100_000) } }
            try await Task.sleep(nanoseconds: 10_000_000_000)
            XCTFail("The emergency guard did not exit its deliberately blocked-main fixture")
        }
        withExtendedLifetime(guardrail) { }
    }
}
#endif
