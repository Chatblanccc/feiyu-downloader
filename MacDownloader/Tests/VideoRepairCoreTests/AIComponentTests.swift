import Darwin
import Foundation
import VideoRepairCore
#if FEATHER_AI_COMPONENT_STANDALONE
class AIComponentTestCase { }
#else
import XCTest
typealias AIComponentTestCase = XCTestCase
#endif

private struct AIComponentCheckFailure: Error, CustomStringConvertible {
    let description: String
}

/// No downloads, model loads or GPU operations. These exercise persisted input and activation boundaries.
final class AIComponentTests: AIComponentTestCase {
    private func require(_ value: @autoclosure () throws -> Bool, _ message: String,
                         file: StaticString = #filePath, line: UInt = #line) throws {
        guard try value() else { throw AIComponentCheckFailure(description: "\(file):\(line): \(message)") }
    }

    private func rejects(_ description: String, _ action: () throws -> Void) throws {
        var rejected = false
        do { try action() } catch { rejected = true }
        try require(rejected, "Accepted invalid input: " + description)
    }

    private struct Fixture {
        let root: URL
        var resources: URL { root.appendingPathComponent("Resources") }
        var support: URL { root.appendingPathComponent("Application Support") }
        var catalogURL: URL { resources.appendingPathComponent("AIComponents/catalog.json") }
        var destination: URL { support.appendingPathComponent("AI/test-component/revision-1") }
        var store: VideoRepairComponentStore {
            .init(supportDirectory: support, resourcesDirectory: resources)
        }
        // The transaction is shared by both engines. Use the legacy profile for process tests so
        // ARM CI runners with less than 32 GiB can test cancellation without invoking a Seed GPU.
        var transactionStore: VideoRepairComponentStore {
            .init(supportDirectory: support, resourcesDirectory: resources, engine: .realesrgan)
        }
        func write(_ value: [String: Any]) throws {
            let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
            try data.write(to: catalogURL)
            try data.write(to: resources.appendingPathComponent("AIComponents/catalog-realesrgan.json"))
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    private func catalog() -> [String: Any] {
        ["schemaVersion": 1, "id": "test-component", "revision": "revision-1", "architecture": "arm64",
         "minimumMacOS": "14.0", "pythonRelativePath": "python/bin/python3", "upstreamRelativePath": "upstream",
         "downloads": [
            ["id": "python", "kind": "python", "filename": "python.tar.gz", "url": "https://example.invalid/python.tar.gz",
             "sha256": String(repeating: "a", count: 64), "bytes": 4],
            ["id": "model", "kind": "model", "filename": "model.bin", "url": "https://example.invalid/model.bin",
             "sha256": "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "bytes": 3]
         ]]
    }

    private func fixture() throws -> Fixture {
        let value = Fixture(root: FileManager.default.temporaryDirectory.appendingPathComponent("FeatherAIComponentTests-" + UUID().uuidString))
        try FileManager.default.createDirectory(at: value.catalogURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try value.write(catalog())
        return value
    }

    func testValidCatalogAndKnownArtifactDigest() throws {
        let f = try fixture(); defer { f.remove() }
        let decoded = try VideoRepairComponentCatalog.load(f.catalogURL)
        try require(decoded.totalDownloadBytes == 7 && decoded.downloads.count == 2, "Valid manifest lost its download budget")
        let file = f.root.appendingPathComponent("digest-input")
        try Data("abc".utf8).write(to: file)
        try require(try VideoRepairComponentStore.sha256(file) == decoded.downloads[1].sha256, "Known SHA-256 vector differs")
        try require(try Data(contentsOf: file) == Data("abc".utf8), "Integrity check altered the source")
    }

    func testCatalogRejectsPathTraversalAndAlternateRuntimePaths() throws {
        let f = try fixture(); defer { f.remove() }
        for (key, values) in ["id": ["..", "../outside", "/tmp/component", "a\\b"],
                              "revision": ["..", "one/two"],
                              "pythonRelativePath": ["../bin/python3", "/usr/bin/python3"],
                              "upstreamRelativePath": ["../upstream", "/tmp/upstream"]] {
            for invalid in values {
                var value = catalog(); value[key] = invalid; try f.write(value)
                try rejects("\(key)=\(invalid)") { _ = try VideoRepairComponentCatalog.load(f.catalogURL) }
            }
        }
        for invalid in ["../model.bin", "/tmp/model.bin", "a\\model.bin", ".", ".."] {
            var value = catalog(); var files = value["downloads"] as! [[String: Any]]
            files[1]["filename"] = invalid; value["downloads"] = files; try f.write(value)
            try rejects("filename=\(invalid)") { _ = try VideoRepairComponentCatalog.load(f.catalogURL) }
        }
    }

    func testCatalogRejectsNonHTTPSCredentialsAndMissingHost() throws {
        let f = try fixture(); defer { f.remove() }
        for invalid in ["http://example.invalid/model", "file:///tmp/model", "https://user:secret@example.invalid/model",
                        "https:/missing-host/model", "https:relative-model"] {
            var value = catalog(); var files = value["downloads"] as! [[String: Any]]
            files[1]["url"] = invalid; value["downloads"] = files; try f.write(value)
            try rejects("download URL \(invalid)") { _ = try VideoRepairComponentCatalog.load(f.catalogURL) }
        }
    }

    func testCatalogRejectsInvalidHashesSizesAndMissingPython() throws {
        let f = try fixture(); defer { f.remove() }
        for (key, invalid): (String, Any) in [("sha256", "abc"), ("sha256", String(repeating: "G", count: 64)),
                                            ("sha256", String(repeating: "A", count: 64)), ("bytes", 0), ("bytes", -1),
                                            ("bytes", Int64(16_000_000_000)), ("kind", "executable")] {
            var value = catalog(); var files = value["downloads"] as! [[String: Any]]
            files[1][key] = invalid; value["downloads"] = files; try f.write(value)
            try rejects("artifact \(key)=\(invalid)") { _ = try VideoRepairComponentCatalog.load(f.catalogURL) }
        }
        var value = catalog(); value["downloads"] = [(value["downloads"] as! [[String: Any]])[1]]; try f.write(value)
        try rejects("missing interpreter archive") { _ = try VideoRepairComponentCatalog.load(f.catalogURL) }
    }

    func testCatalogRejectsDuplicateArtifactIdentitiesAndCaseCollidingFiles() throws {
        let f = try fixture(); defer { f.remove() }
        var value = catalog(); var files = value["downloads"] as! [[String: Any]]
        files[1]["id"] = files[0]["id"]; value["downloads"] = files; try f.write(value)
        try rejects("duplicate download id overwrites bootstrap artifact lookup") { _ = try VideoRepairComponentCatalog.load(f.catalogURL) }
        files = catalog()["downloads"] as! [[String: Any]]
        var extra = files[1]; extra["id"] = "other-model"; files.append(extra)
        value = catalog(); value["downloads"] = files; try f.write(value)
        try rejects("duplicate filename") { _ = try VideoRepairComponentCatalog.load(f.catalogURL) }
        files[1]["filename"] = "Model.bin"; files[2]["filename"] = "model.bin"
        value["downloads"] = files; try f.write(value)
        try rejects("case-folded filename collision on common macOS volumes") { _ = try VideoRepairComponentCatalog.load(f.catalogURL) }
    }

    func testLegacyHistoryKeepsRealESRGANAndOriginalGeometry() throws {
        let request = VideoRepairRequest(input: URL(fileURLWithPath: "/tmp/input.mp4"), destination: URL(fileURLWithPath: "/tmp/out"))
        var value = try JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as! [String: Any]
        for key in ["engine", "performance", "outputSize"] { value.removeValue(forKey: key) }
        let decoded = try JSONDecoder().decode(VideoRepairRequest.self, from: JSONSerialization.data(withJSONObject: value))
        try require(decoded.engine == .realesrgan, "Legacy repair history changed engine")
        try require(decoded.outputSize == .source && decoded.performance == .quality, "Legacy history changed processing semantics")
    }

    func testSeed720RoundTripAndDecodedFlagsRespectEngineCapabilities() throws {
        let request = VideoRepairRequest(input: URL(fileURLWithPath: "/tmp/input.mp4"), destination: URL(fileURLWithPath: "/tmp/out"),
                                        enhance: false, repairMosaic: true, outputSize: .hd720, engine: .seedvr2)
        try require(request.enhance && !request.repairMosaic, "Seed initializer did not enforce supported capabilities")
        try require(try JSONDecoder().decode(VideoRepairRequest.self, from: JSONEncoder().encode(request)) == request, "Seed/720 request lost state in history")
        var value = try JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as! [String: Any]
        value["enhance"] = false; value["repairMosaic"] = true
        let decoded = try JSONDecoder().decode(VideoRepairRequest.self, from: JSONSerialization.data(withJSONObject: value))
        try require(decoded.enhance && !decoded.repairMosaic, "Decoded Seed history bypassed engine capability normalization")
    }

    func test720GeometryKeepsAspectOrientationAndLargerSources() throws {
        for (width, height, expectedWidth, expectedHeight) in [(540, 960, 720, 1280), (640, 360, 1280, 720),
            (480, 480, 720, 720), (854, 480, 1280, 718), (480, 854, 718, 1280),
            (1080, 1920, 1080, 1920), (2560, 720, 2560, 720)] {
            let target = VideoRepairMedia.outputDimensions(width: width, height: height, outputSize: .hd720)
            try require(target.width == expectedWidth && target.height == expectedHeight, "Unexpected 720 geometry for \(width)x\(height)")
        }
        func info(_ width: Int, _ height: Int, frames: Int = 90, frameRate: Double = 30) throws -> VideoRepairMediaInfo {
            try JSONDecoder().decode(VideoRepairMediaInfo.self, from: JSONSerialization.data(withJSONObject: [
                "width": width, "height": height, "duration": 3, "videoDuration": 3, "frameRate": frameRate,
                "videoFrameCount": frames, "audioDurations": [3]]))
        }
        let input = try info(540, 960)
        try VideoRepairMedia.validateOutput(info(720, 1280), against: input, outputSize: .hd720)
        try rejects("worker completion with the unscaled source dimensions") {
            try VideoRepairMedia.validateOutput(input, against: input, outputSize: .hd720)
        }
        try rejects("same-duration output that silently discards half of the original frames") {
            try VideoRepairMedia.validateOutput(info(720, 1280, frames: 45, frameRate: 15), against: input, outputSize: .hd720)
        }
    }

    private func prefix(_ directory: URL, fixture f: Fixture, marker: Bool, receipt: Bool = true, modelBytes: String = "abc") throws {
        let fm = FileManager.default
        let python = directory.appendingPathComponent("python/bin/python3")
        try fm.createDirectory(at: python.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: python)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: python.path)
        for path in ["upstream/inference_cli.py", "worker.py", "python/lib/python3.11/encodings/__init__.py"] {
            let entry = directory.appendingPathComponent(path)
            try fm.createDirectory(at: entry.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("# fixture entry point\n".utf8).write(to: entry)
        }
        try fm.createDirectory(at: directory.appendingPathComponent("models"), withIntermediateDirectories: true)
        try Data(modelBytes.utf8).write(to: directory.appendingPathComponent("models/model.bin"))
        if receipt { try Data("{}".utf8).write(to: directory.appendingPathComponent("component-receipt.json")) }
        if marker {
            try JSONSerialization.data(withJSONObject: ["catalogSHA256": VideoRepairComponentStore.sha256(f.catalogURL)])
                .write(to: directory.appendingPathComponent("feather-component.json"))
        }
    }

    func testStagingMissingMarkerAndStaleCatalogNeverActivate() throws {
        let f = try fixture(); defer { f.remove() }
        try prefix(f.support.appendingPathComponent("AI/.staging-interrupted"), fixture: f, marker: true)
        try require(try f.store.installedDirectory() == nil, "Staging prefix was treated as active")
        try prefix(f.destination, fixture: f, marker: false)
        try require(try f.store.installedDirectory() == nil, "Uncommitted prefix was treated as active")
        try prefix(f.destination, fixture: f, marker: true)
        try require(try f.store.installedDirectory() == f.destination, "Activation marker positive control failed")
        let replacement = f.destination.deletingLastPathComponent().appendingPathComponent("revision-1-new-prefix")
        try prefix(replacement, fixture: f, marker: true)
        let pointer = f.destination.deletingLastPathComponent().appendingPathComponent("active.json")
        try JSONSerialization.data(withJSONObject: ["directory": replacement.lastPathComponent]).write(to: pointer)
        try require(try f.store.installedDirectory()?.standardizedFileURL.path == replacement.standardizedFileURL.path,
                    "Active pointer did not select the completed new prefix")
        try require(FileManager.default.fileExists(atPath: f.destination.path), "Switching active prefix removed the previous path")
        for invalid in ["../outside", "/tmp/outside", "revision-1-../../outside", "revision-2-other"] {
            try JSONSerialization.data(withJSONObject: ["directory": invalid]).write(to: pointer)
            try require(try f.store.installedDirectory() == f.destination, "Invalid active pointer escaped the safe legacy fallback")
        }
        var changed = catalog(); changed["minimumMacOS"] = "14.1"; try f.write(changed)
        try require(try f.store.installedDirectory() == nil, "Receipt for a different catalog was reused")
    }

    func testMissingReceiptAndTruncatedModelNeverActivate() throws {
        let f = try fixture(); defer { f.remove() }
        try prefix(f.destination, fixture: f, marker: true, receipt: false)
        try require(try f.store.installedDirectory() == nil, "Prefix without installation receipt was treated as active")
        try prefix(f.destination, fixture: f, marker: true, modelBytes: "a")
        try require(try f.store.installedDirectory() == nil, "Truncated model was treated as installed")
        try prefix(f.destination, fixture: f, marker: true)
        try FileManager.default.removeItem(at: f.destination.appendingPathComponent("upstream/inference_cli.py"))
        try require(try f.store.installedDirectory() == nil, "Missing inference entry point prevented reinstall detection")
        try prefix(f.destination, fixture: f, marker: true)
        try FileManager.default.removeItem(at: f.destination.appendingPathComponent("python/lib/python3.11/encodings/__init__.py"))
        try require(try f.store.installedDirectory() == nil, "Missing standard library prevented reinstall detection")
        try prefix(f.destination, fixture: f, marker: true)
        let legacyCatalog = f.resources.appendingPathComponent("AIComponents/catalog-realesrgan.json")
        try Data(contentsOf: f.catalogURL).write(to: legacyCatalog)
        let legacy = VideoRepairComponentStore(supportDirectory: f.support, resourcesDirectory: f.resources, engine: .realesrgan)
        try require(try legacy.installedDirectory() == f.destination, "Legacy entry point positive control failed")
        try FileManager.default.removeItem(at: f.destination.appendingPathComponent("worker.py"))
        try require(try legacy.installedDirectory() == nil, "Missing legacy worker prevented reinstall detection")
    }

    func testCancelledPreparationDoesNotDownloadOrActivate() async throws {
        let f = try fixture(); defer { f.remove() }
        // Cancel inside this new task before the installer has an opportunity to start a URLSession request.
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await f.transactionStore.ensureInstalled { _ in }
        }
        var cancelled = false
        do { _ = try await task.value } catch is CancellationError { cancelled = true }
        try require(cancelled, "Cancelled preparation did not propagate cancellation")
        try require(try f.store.installedDirectory() == nil, "Cancelled preparation activated a component")
        let cache = f.store.componentRoot.appendingPathComponent("Downloads")
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: cache.path)) ?? []
        try require(entries.isEmpty, "Cancelled preflight downloaded or retained an artifact")
        let roots = (try? FileManager.default.contentsOfDirectory(atPath: f.store.componentRoot.path)) ?? []
        try require(!roots.contains(where: { $0.hasPrefix(".staging-") }), "Cancelled preflight left a staging prefix")
    }

    /// A tiny executable fixture replaces Python, while the host still runs its real tar/process transaction.
    /// All artifacts are pre-cached and SHA pinned; no URLSession request or Python dependency install occurs.
    private func offlineInstallerFixture(hold: Bool) throws -> (Fixture, URL) {
        let f = try fixture()
        do {
            let fm = FileManager.default
            let archiveRoot = f.root.appendingPathComponent("archive-input")
            let python = archiveRoot.appendingPathComponent("python/bin/python3")
            let started = f.root.appendingPathComponent("bootstrap-started")
            try fm.createDirectory(at: python.deletingLastPathComponent(), withIntermediateDirectories: true)
            // The fixture UUID path consists of the controlled temporary prefix and a UUID.
            let script = "#!/bin/sh\n/usr/bin/touch '\(started.path)'\n" + (hold ? "/bin/sleep 30\n" : "exit 37\n")
            try Data(script.utf8).write(to: python)
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: python.path)
            let cache = f.store.componentRoot.appendingPathComponent("Downloads")
            try fm.createDirectory(at: cache, withIntermediateDirectories: true)
            let archive = cache.appendingPathComponent("python.tar.gz")
            let tar = Process(); tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            tar.arguments = ["-czf", archive.path, "-C", archiveRoot.path, "python"]
            try tar.run(); tar.waitUntilExit()
            try require(tar.terminationStatus == 0, "Could not create offline process fixture")
            try Data("abc".utf8).write(to: cache.appendingPathComponent("model.bin"))
            var value = catalog(); var files = value["downloads"] as! [[String: Any]]
            files[0]["bytes"] = try archive.resourceValues(forKeys: [.fileSizeKey]).fileSize!
            files[0]["sha256"] = try VideoRepairComponentStore.sha256(archive)
            value["downloads"] = files; try f.write(value)
            return (f, started)
        } catch { f.remove(); throw error }
    }

    private func requireUnactivatedAndClean(_ f: Fixture, preserving old: URL? = nil) throws {
        try require(try f.store.installedDirectory() == old, "Incomplete installer changed the active component")
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: f.store.componentRoot.path)) ?? []
        try require(!entries.contains(where: { $0.hasPrefix(".staging-") }), "Incomplete installer left a staging prefix")
    }

    func testCancellationDuringBootstrapRemovesStagingAndNeverActivates() async throws {
        let (f, started) = try offlineInstallerFixture(hold: true); defer { f.remove() }
        try prefix(f.destination, fixture: f, marker: true)
        let task = Task { try await f.transactionStore.ensureInstalled(forceRepair: true) { _ in } }
        defer { task.cancel() }
        let deadline = Date().addingTimeInterval(8)
        while !FileManager.default.fileExists(atPath: started.path), Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        try require(FileManager.default.fileExists(atPath: started.path), "Installer did not reach the real bootstrap process")
        task.cancel()
        var cancelled = false
        do { _ = try await task.value } catch is CancellationError { cancelled = true }
        try require(cancelled, "Mid-install cancellation did not propagate")
        try requireUnactivatedAndClean(f, preserving: f.destination)
    }

    func testBootstrapFailureRemovesStagingAndNeverActivates() async throws {
        let (f, started) = try offlineInstallerFixture(hold: false); defer { f.remove() }
        try prefix(f.destination, fixture: f, marker: true)
        var failed = false
        do { _ = try await f.transactionStore.ensureInstalled(forceRepair: true) { _ in } } catch { failed = true }
        try require(failed && FileManager.default.fileExists(atPath: started.path), "Fixture did not fail inside bootstrap")
        try requireUnactivatedAndClean(f, preserving: f.destination)
    }
}

#if FEATHER_AI_COMPONENT_STANDALONE
@main enum AIComponentStandaloneTests {
    static func main() async throws {
        let tests = AIComponentTests()
        let sync: [(String, () throws -> Void)] = [
            ("validCatalogAndDigest", tests.testValidCatalogAndKnownArtifactDigest),
            ("pathTraversal", tests.testCatalogRejectsPathTraversalAndAlternateRuntimePaths),
            ("URLPolicy", tests.testCatalogRejectsNonHTTPSCredentialsAndMissingHost),
            ("hashSizeAndKind", tests.testCatalogRejectsInvalidHashesSizesAndMissingPython),
            ("duplicateArtifacts", tests.testCatalogRejectsDuplicateArtifactIdentitiesAndCaseCollidingFiles),
            ("legacyHistory", tests.testLegacyHistoryKeepsRealESRGANAndOriginalGeometry),
            ("seedHistory", tests.testSeed720RoundTripAndDecodedFlagsRespectEngineCapabilities),
            ("720Geometry", tests.test720GeometryKeepsAspectOrientationAndLargerSources),
            ("activationMarker", tests.testStagingMissingMarkerAndStaleCatalogNeverActivate),
            ("incompleteInstallation", tests.testMissingReceiptAndTruncatedModelNeverActivate)]
        var results: [[String: Any]] = []
        for (name, action) in sync {
            do { try action(); results.append(["test": name, "passed": true]) }
            catch { results.append(["test": name, "passed": false, "error": String(describing: error)]) }
        }
        do { try await tests.testCancelledPreparationDoesNotDownloadOrActivate(); results.append(["test": "cancellation", "passed": true]) }
        catch { results.append(["test": "cancellation", "passed": false, "error": String(describing: error)]) }
        do { try await tests.testCancellationDuringBootstrapRemovesStagingAndNeverActivates(); results.append(["test": "midInstallCancellation", "passed": true]) }
        catch { results.append(["test": "midInstallCancellation", "passed": false, "error": String(describing: error)]) }
        do { try await tests.testBootstrapFailureRemovesStagingAndNeverActivates(); results.append(["test": "bootstrapFailure", "passed": true]) }
        catch { results.append(["test": "bootstrapFailure", "passed": false, "error": String(describing: error)]) }
        let passed = results.allSatisfy { $0["passed"] as? Bool == true }
        let data = try JSONSerialization.data(withJSONObject: ["passed": passed, "testCount": results.count,
            "mode": "same test bodies via FEATHER_AI_COMPONENT_STANDALONE on CLT-only host", "results": results], options: [.sortedKeys, .prettyPrinted])
        if let path = ProcessInfo.processInfo.environment["FEATHER_AI_COMPONENT_TEST_REPORT"] {
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
        print(String(decoding: data, as: UTF8.self))
        if !passed { exit(1) }
    }
}
#endif
