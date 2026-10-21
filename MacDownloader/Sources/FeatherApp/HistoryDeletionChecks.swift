import Foundation
import SubtitleCore
import VideoRepairCore

/// Private fixtures exercise real model persistence without valid media or AI work.
@MainActor
enum HistoryDeletionChecks {
    static func run() async -> [String: Any] {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FeatherHistoryDeletion-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var checks: [String: Bool] = [:]
        do {
            let fixture = try Fixture(root: root.appendingPathComponent("repair"), receiptsName: "video-repair-receipts")
            let result: VideoRepairExportResult = try fixture.decodeResult([
                "folder": fixture.media.absoluteString, "video": fixture.video.absoluteString,
                "report": fixture.report.absoluteString, "videoBytes": fixture.bytes[fixture.video]!.count,
                "reportBytes": fixture.bytes[fixture.report]!.count,
                "inputInfo": fixture.info, "outputInfo": fixture.info, "receiptSaved": true
            ])
            let states: [VideoRepairHistoryItem.State] = [.completed, .failed, .cancelled, .interrupted]
            let items = states.map { state in
                var item = VideoRepairHistoryItem(request: VideoRepairRequest(input: fixture.source, destination: fixture.media))
                item.state = state
                if state == .completed { item.result = result }
                return item
            }
            let seed = try JSONEncoder().encode(items)
            checks.merge(try fixture.exercise(seed: seed, ids: items.map(\.id)) {
                let model = VideoRepairApplicationModel(historyFile: fixture.history)
                return Access(ids: { model.records.map(\.id) }, current: { model.current?.id },
                              canRemove: model.canRemove, remove: model.remove, notice: { model.notice },
                              snapshot: { try Self.snapshot(model.records) })
            }.mapKeys { "repair." + $0 }) { _, new in new }

            let active = VideoRepairApplicationModel(historyFile: fixture.root.appendingPathComponent("active.json"))
            active.selectFile(fixture.source)
            active.destination = fixture.media
            active.start()
            let id = active.current?.id
            if let id {
                active.remove(id)
                checks["repair.preparingCannotBeRemoved"] = active.current?.id == id && !active.canRemove(id) && active.current?.state == .preparing
                active.cancel()
                active.remove(id)
                checks["repair.cancellingCannotBeRemoved"] = active.current?.id == id && !active.canRemove(id) && active.current?.state == .cancelling
            } else { checks["repair.activeTaskStarted"] = false }
            // Cancellation happens before yielding the MainActor. The fixture is also
            // deliberately invalid media, so it can never reach an AI worker.
            await active.shutdown()
            checks["repair.allProcessingStatesAreActive"] = [VideoRepairHistoryItem.State.preparing, .processing, .cancelling].allSatisfy(\.active)

            if #available(macOS 26.0, *) {
                let fixture = try Fixture(root: root.appendingPathComponent("subtitle"), receiptsName: "subtitle-receipts")
                let result: SubtitleExportResult = try fixture.decodeResult([
                    "folder": fixture.media.absoluteString, "subtitles": fixture.subtitles.absoluteString,
                    "video": fixture.video.absoluteString, "subtitleBytes": fixture.bytes[fixture.subtitles]!.count,
                    "videoBytes": fixture.bytes[fixture.video]!.count, "cueCount": 1, "receiptSaved": true
                ])
                let states: [SubtitleHistoryItem.State] = [.completed, .failed, .cancelled, .interrupted]
                let items = states.map { state in
                    var item = SubtitleHistoryItem(request: SubtitleRequest(input: fixture.source, destination: fixture.media,
                        source: "en-US", target: "zh", textMode: .original, videoMode: .none))
                    item.state = state
                    if state == .completed { item.result = result }
                    return item
                }
                checks.merge(try fixture.exercise(seed: JSONEncoder().encode(items), ids: items.map(\.id)) {
                    let model = SubtitleApplicationModel(historyFile: fixture.history)
                    return Access(ids: { model.records.map(\.id) }, current: { model.current?.id },
                                  canRemove: model.canRemove, remove: model.remove, notice: { model.notice },
                                  snapshot: { try Self.snapshot(model.records) })
                }.mapKeys { "subtitle." + $0 }) { _, new in new }
                checks["subtitle.allProcessingStatesAreActive"] = [SubtitleHistoryItem.State.preparing, .processing, .cancelling].allSatisfy(\.active)
            } else {
                return ["success": false, "checks": checks, "error": "Subtitle model checks require macOS 26 or later."]
            }
            return ["success": !checks.isEmpty && checks.values.allSatisfy { $0 }, "checks": checks]
        } catch {
            return ["success": false, "checks": checks, "error": error.localizedDescription]
        }
    }

    private static func snapshot<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    private struct Access {
        let ids: () -> [UUID]
        let current: () -> UUID?
        let canRemove: (UUID) -> Bool
        let remove: (UUID) -> Void
        let notice: () -> String?
        let snapshot: () throws -> Data
    }

    private struct Fixture {
        let root: URL
        let history: URL
        let receipts: URL
        let media: URL
        let source: URL
        let video: URL
        let report: URL
        let subtitles: URL
        let bytes: [URL: Data]
        let info: [String: Any] = ["duration": 1.0, "videoDuration": 1.0, "width": 16,
            "height": 16, "frameRate": 1.0, "videoFrameCount": 1, "audioDurations": []]

        init(root: URL, receiptsName: String) throws {
            self.root = root
            history = root.appendingPathComponent("history.json")
            receipts = root.appendingPathComponent(receiptsName)
            media = root.appendingPathComponent("media")
            source = media.appendingPathComponent("original.mp4")
            video = media.appendingPathComponent("export.mp4")
            report = media.appendingPathComponent("report.json")
            subtitles = media.appendingPathComponent("subtitles.srt")
            bytes = [source: Data("unchanged original fixture".utf8), video: Data("unchanged export fixture".utf8),
                     report: Data("unchanged report fixture".utf8), subtitles: Data("1\n00:00:00,000 --> 00:00:01,000\nFixture\n".utf8)]
            try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: receipts, withIntermediateDirectories: true)
            for (url, data) in bytes { try data.write(to: url) }
        }

        func decodeResult<T: Decodable>(_ object: [String: Any]) throws -> T {
            try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: object))
        }

        func receipt(_ id: UUID) -> URL { receipts.appendingPathComponent(id.uuidString + ".json") }

        func exercise(seed: Data, ids: [UUID], make: () -> Access) throws -> [String: Bool] {
            let fm = FileManager.default
            let receiptData = Data("private recovery fixture".utf8)
            func seedHistory() throws {
                try seed.write(to: history, options: .atomic)
                for id in ids { try receiptData.write(to: receipt(id)) }
            }
            try seedHistory()
            let unrelated = receipt(UUID())
            try receiptData.write(to: unrelated)
            let model = make()
            var checks = ["terminalStatesRemovable": model.ids() == ids && ids.allSatisfy(model.canRemove)]
            let missing = UUID()
            let beforeNoOp = try model.snapshot()
            model.remove(missing)
            let afterNoOp = try model.snapshot()
            checks["unknownIDIsNoOp"] = !model.canRemove(missing) && afterNoOp == beforeNoOp
            var expected = ids
            var removed: [UUID] = []
            var deletionOK = true
            for id in ids {
                model.remove(id)
                expected.removeAll { $0 == id }
                removed.append(id)
                let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: history)) as? [[String: Any]]
                let savedIDs = saved?.compactMap { ($0["request"] as? [String: Any])?["id"] as? String }.compactMap(UUID.init(uuidString:))
                deletionOK = deletionOK && model.ids() == expected && model.current() == expected.first
                    && savedIDs == expected && make().ids() == expected
                    && removed.allSatisfy { !fm.fileExists(atPath: receipt($0).path) }
                    && expected.allSatisfy { fm.fileExists(atPath: receipt($0).path) }
            }
            checks["eachDeletionPersistsAndCurrentAdvances"] = deletionOK
            checks["emptyHistoryStaysEmptyAfterRecreation"] = model.ids().isEmpty && model.current() == nil && make().ids().isEmpty
            checks["unrelatedReceiptPreserved"] = try Data(contentsOf: unrelated) == receiptData

            try seedHistory()
            let failing = make()
            let beforeFailure = try failing.snapshot()
            let originalHistory = try Data(contentsOf: history)
            try fm.removeItem(at: history)
            try fm.createDirectory(at: history, withIntermediateDirectories: false)
            try Data("force an atomic-write failure".utf8).write(to: history.appendingPathComponent("blocker"))
            failing.remove(ids[0])
            checks["writeFailureRollsBackAndReportsNotice"] = try failing.snapshot() == beforeFailure
                && failing.ids() == ids && !(failing.notice() ?? "").isEmpty
                && Data(contentsOf: receipt(ids[0])) == receiptData
            try fm.removeItem(at: history)
            try originalHistory.write(to: history, options: .atomic)
            checks["originalAndExportedFilesUnchanged"] = try bytes.allSatisfy { try Data(contentsOf: $0.key) == $0.value }
            return checks
        }
    }
}

private extension Dictionary where Key == String {
    func mapKeys(_ transform: (String) -> String) -> [String: Value] {
        Dictionary(uniqueKeysWithValues: map { (transform($0.key), $0.value) })
    }
}
