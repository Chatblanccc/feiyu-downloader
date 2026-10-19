import Foundation

@MainActor
final class SubtitleFeature {
    private var storage: AnyObject?
    @available(macOS 26.0, *)
    var model: SubtitleApplicationModel {
        if let model = storage as? SubtitleApplicationModel { return model }
        let model = SubtitleApplicationModel()
        storage = model
        return model
    }
    var hasActiveWorkForUpdate: Bool {
        if #available(macOS 26.0, *), let model = storage as? SubtitleApplicationModel {
            return model.hasActiveWorkForUpdate
        }
        return false
    }
    func shutdown() async {
        if #available(macOS 26.0, *), let model = storage as? SubtitleApplicationModel { await model.shutdown() }
    }
}
