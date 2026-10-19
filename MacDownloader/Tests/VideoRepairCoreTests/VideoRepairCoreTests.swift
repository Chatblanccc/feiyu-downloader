import Darwin
import DownloadCore
import Foundation
import VideoRepairCore
#if FEATHER_REPAIR_STANDALONE
class XCTestCase { }
private struct XCTSkip: Error { let message: String; init(_ message: String) { self.message = message } }
private func XCTFail(_ message: String, file: StaticString = #filePath, line: UInt = #line) {
    fatalError(message, file: (file), line: line)
}
private func XCTAssertTrue(_ value: @autoclosure () -> Bool, _ message: String = "Expected true", file: StaticString = #filePath, line: UInt = #line) {
    if !value() { XCTFail(message, file: file, line: line) }
}
private func XCTAssertFalse(_ value: @autoclosure () -> Bool, file: StaticString = #filePath, line: UInt = #line) {
    if value() { XCTFail("Expected false", file: file, line: line) }
}
private func XCTAssertEqual<T: Equatable>(_ first: T, _ second: T, file: StaticString = #filePath, line: UInt = #line) {
    if first != second { XCTFail("Expected equal values: \(first), \(second)", file: file, line: line) }
}
private func XCTAssertNotEqual<T: Equatable>(_ first: T, _ second: T, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
    if first == second { XCTFail(message, file: file, line: line) }
}
private func XCTAssertGreaterThan<T: Comparable>(_ first: T, _ second: T, file: StaticString = #filePath, line: UInt = #line) {
    if !(first > second) { XCTFail("Expected greater value", file: file, line: line) }
}
private func XCTAssertLessThan<T: Comparable>(_ first: T, _ second: T, file: StaticString = #filePath, line: UInt = #line) {
    if !(first < second) { XCTFail("Expected lesser value", file: file, line: line) }
}
private func XCTUnwrap<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) throws -> T {
    guard let value else { XCTFail("Expected value", file: file, line: line); throw VideoRepairError.invalidMedia }
    return value
}
#else
import XCTest
#endif

/// Real helper processes and real MP4 streams exercise the commit/cancellation boundary.
/// These tests validate orchestration; model quality is covered by the packaged-video acceptance run.
final class VideoRepairCoreTests: XCTestCase {
    private var workspace: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    private func fixture(mode: String) throws -> (URL, VideoRepairRequest, VideoRepairEngine, URL) {
        let source = ProcessInfo.processInfo.environment["FEATHER_TEST_VIDEO"].map(URL.init(fileURLWithPath:))
            ?? workspace.appendingPathComponent("work/android-toolchain/sample-probe/youtube-second.mp4")
        let tools = ProcessInfo.processInfo.environment["FEATHER_TOOLS_DIR"].map(URL.init(fileURLWithPath:))
            ?? workspace.appendingPathComponent("outputs/飞羽下载.app/Contents/Resources/tools", isDirectory: true)
        guard FileManager.default.isReadableFile(atPath: source.path), FileManager.default.isExecutableFile(atPath: tools.appendingPathComponent("ffmpeg").path) else {
            throw XCTSkip("Set FEATHER_TEST_VIDEO and FEATHER_TOOLS_DIR for real-media lifecycle tests")
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("FeatherRepairTests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let input = folder.appendingPathComponent("真实视频.mp4")
        try FileManager.default.copyItem(at: source, to: input)
        let worker = folder.appendingPathComponent("worker.sh")
        let script = #"""
        while [ "$#" -gt 0 ]; do
          case "$1" in
            --input) input="$2"; shift 2 ;;
            --output) output="$2"; shift 2 ;;
            --ffmpeg) ffmpeg="$2"; shift 2 ;;
            --ffprobe) ffprobe="$2"; shift 2 ;;
            *) shift ;;
          esac
        done
        case "$FEATHER_TEST_WORKER_MODE" in
          fail) printf 'partial' > "$output"; printf 'intentional model failure\n' >&2; exit 19 ;;
          wait) /bin/sleep 30 & child=$!; printf '%s' "$child" > "$input.child"; printf '{"type":"progress","stage":"processing","progress":0.1}\n'; wait "$child" ;;
          no-audio) "$ffmpeg" -hide_banner -loglevel error -nostdin -i "$input" -map 0:v:0 -an -c:v copy "$output" ;;
          no-event) /bin/cp "$input" "$output"; exit 0 ;;
          source-change) /bin/cp "$input" "$output"; /usr/bin/touch "$input" ;;
          *) /bin/cp "$input" "$output" ;;
        esac
        frames=$("$ffprobe" -v error -select_streams v:0 -count_packets -show_entries stream=nb_read_packets -of csv=p=0 "$output")
        printf '{"type":"completed","output":"%s","framesProcessed":%s,"framesTotal":%s,"regionsRepaired":2}\n' "$output" "$frames" "$frames"
        """#
        try script.write(to: worker, atomically: false, encoding: .utf8)
        let runtime = VideoRepairRuntime(python: URL(fileURLWithPath: "/bin/sh"), worker: worker,
            ffmpeg: tools.appendingPathComponent("ffmpeg"), ffprobe: tools.appendingPathComponent("ffprobe"),
            environment: ["FEATHER_TEST_WORKER_MODE": mode])
        return (folder, VideoRepairRequest(input: input, destination: folder.appendingPathComponent("exports", isDirectory: true)),
                VideoRepairEngine(runtime: runtime), folder.appendingPathComponent("receipts/completion.json"))
    }

    private func assertNoCommittedResult(_ request: VideoRepairRequest, receipt: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertFalse(FileManager.default.fileExists(atPath: receipt.path), file: file, line: line)
        let exported = try FileManager.default.contentsOfDirectory(at: request.destination, includingPropertiesForKeys: nil)
        XCTAssertTrue(exported.isEmpty, "No partial video or staging folder may survive", file: file, line: line)
    }

    func testCompleteMP4KeepsAllAudioAndRecoversDurableReceipt() async throws {
        let (folder, request, engine, receipt) = try fixture(mode: "copy")
        defer { try? FileManager.default.removeItem(at: folder) }
        let result = try await engine.run(request, receiptURL: receipt)
        XCTAssertTrue(result.filesExist())
        XCTAssertGreaterThan(result.inputInfo.audioTrackCount, 0)
        XCTAssertEqual(result.outputInfo.audioTrackCount, result.inputInfo.audioTrackCount)
        XCTAssertEqual(result.outputInfo.width, result.inputInfo.width)
        let recovered = try await VideoRepairReceipt.recover(at: receipt)
        XCTAssertEqual(recovered.request, request)
        XCTAssertEqual(recovered.result.video, result.video)
        let permissions = try FileManager.default.attributesOfItem(atPath: receipt.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
        let files = try FileManager.default.contentsOfDirectory(atPath: result.folder.path)
        XCTAssertEqual(Set(files), Set(["AI修复视频.mp4", "修复报告.json"]))
        // A receipt cannot turn a deleted/truncated export back into a completed task.
        try Data("broken".utf8).write(to: result.video)
        XCTAssertFalse(result.filesExist())
        do { _ = try await VideoRepairReceipt.recover(at: receipt); XCTFail("Modified export must not recover") }
        catch VideoRepairError.invalidReceipt { }
    }

    func testHelperFailureRemovesIncompleteFileAndNeverCommitsReceipt() async throws {
        let (folder, request, engine, receipt) = try fixture(mode: "fail")
        defer { try? FileManager.default.removeItem(at: folder) }
        do { _ = try await engine.run(request, receiptURL: receipt); XCTFail("Model failure must fail the task") }
        catch VideoRepairError.operation(let detail) { XCTAssertTrue(detail.contains("intentional model failure")) }
        try assertNoCommittedResult(request, receipt: receipt)
    }

    func testSuccessfulExitWithoutCompletionCannotClaimSuccess() async throws {
        let (folder, request, engine, receipt) = try fixture(mode: "no-event")
        defer { try? FileManager.default.removeItem(at: folder) }
        do { _ = try await engine.run(request, receiptURL: receipt); XCTFail("An ordinary exit is insufficient") }
        catch VideoRepairError.invalidWorkerOutput { }
        try assertNoCommittedResult(request, receipt: receipt)
    }

    func testExportThatLosesAudioIsRejectedDespiteWorkerCompletion() async throws {
        let (folder, request, engine, receipt) = try fixture(mode: "no-audio")
        defer { try? FileManager.default.removeItem(at: folder) }
        do { _ = try await engine.run(request, receiptURL: receipt); XCTFail("Lost audio must not pass validation") }
        catch VideoRepairError.invalidWorkerOutput { }
        try assertNoCommittedResult(request, receipt: receipt)
    }

    func testCancellationKillsDescendantAndRemovesTemporaryExport() async throws {
        let (folder, request, engine, receipt) = try fixture(mode: "wait")
        defer { try? FileManager.default.removeItem(at: folder) }
        let task = Task { try await engine.run(request, receiptURL: receipt) }
        let marker = URL(fileURLWithPath: request.input.path + ".child")
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: marker.path) { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let pid = try XCTUnwrap(Int32(String(contentsOf: marker, encoding: .utf8)))
        let began = Date()
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancellation must stop the operation") }
        catch is CancellationError { }
        XCTAssertLessThan(Date().timeIntervalSince(began), 4)
        for _ in 0..<50 {
            if kill(pid, 0) != 0 { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertNotEqual(kill(pid, 0), 0, "Worker descendants must not keep running")
        try assertNoCommittedResult(request, receipt: receipt)
    }

    func testChangedSourceCannotCommitAResultFromOldContent() async throws {
        let (folder, request, engine, receipt) = try fixture(mode: "source-change")
        defer { try? FileManager.default.removeItem(at: folder) }
        do { _ = try await engine.run(request, receiptURL: receipt); XCTFail("Changed source must be rejected") }
        catch VideoRepairError.sourceChanged { }
        try assertNoCommittedResult(request, receipt: receipt)
    }
}

#if FEATHER_REPAIR_STANDALONE
@main enum VideoRepairStandaloneTests {
    static func main() async throws {
        let started = Date()
        let tests = VideoRepairCoreTests()
        try await tests.testCompleteMP4KeepsAllAudioAndRecoversDurableReceipt()
        try await tests.testHelperFailureRemovesIncompleteFileAndNeverCommitsReceipt()
        try await tests.testSuccessfulExitWithoutCompletionCannotClaimSuccess()
        try await tests.testExportThatLosesAudioIsRejectedDespiteWorkerCompletion()
        try await tests.testCancellationKillsDescendantAndRemovesTemporaryExport()
        try await tests.testChangedSourceCannotCommitAResultFromOldContent()
        let object: [String: Any] = ["passed": true, "testCount": 6, "elapsedSeconds": Date().timeIntervalSince(started),
            "mode": "same XCTest bodies via FEATHER_REPAIR_STANDALONE on CLT-only host", "usesRealProcessesAndMP4": true,
            "coversModelQuality": false]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        if let path = ProcessInfo.processInfo.environment["FEATHER_REPAIR_TEST_REPORT"] {
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
        print(String(decoding: data, as: UTF8.self))
    }
}
#endif
