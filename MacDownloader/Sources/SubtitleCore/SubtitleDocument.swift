import Foundation

public enum SubtitleDocument {
    private static let maximumCues = 10_000
    private static let maximumTextBytes = 2 * 1_024 * 1_024

    public static func validate(_ cues: [SubtitleCue], duration: Double) throws {
        guard duration.isFinite, duration > 0, duration <= 7_200 else { throw SubtitleError.invalidMedia }
        guard !cues.isEmpty else { throw SubtitleError.noSpeech }
        guard cues.count <= maximumCues else { throw SubtitleError.tooManyCues }
        var previousStart = -Double.infinity
        var totalBytes = 0
        for cue in cues {
            guard cue.start.isFinite, cue.end.isFinite, cue.start >= 0,
                  cue.end > cue.start, cue.end <= duration + 0.05,
                  cue.start >= previousStart, milliseconds(cue.end) > milliseconds(cue.start),
                  !normalized(cue.sourceText).isEmpty else { throw SubtitleError.invalidSubtitles }
            guard cue.sourceText.count <= 2_048, (cue.translatedText?.count ?? 0) <= 2_048 else {
                throw SubtitleError.tooManyCues
            }
            totalBytes += cue.sourceText.utf8.count + (cue.translatedText?.utf8.count ?? 0)
            guard totalBytes <= maximumTextBytes else { throw SubtitleError.tooManyCues }
            previousStart = cue.start
        }
    }

    public static func srt(cues: [SubtitleCue], mode: SubtitleTextMode) throws -> String {
        guard let end = cues.map(\.end).max(), end.isFinite, end > 0 else { throw SubtitleError.invalidSubtitles }
        try validate(cues, duration: min(7_200, max(end, 0.001)))
        return try cues.enumerated().map { index, cue in
            let text = try displayText(cue, mode: mode)
            return "\(index + 1)\n\(timestamp(cue.start)) --> \(timestamp(cue.end))\n\(text)\n"
        }.joined(separator: "\n")
    }

    static func displayText(_ cue: SubtitleCue, mode: SubtitleTextMode) throws -> String {
        let source = normalized(cue.sourceText)
        guard !source.isEmpty else { throw SubtitleError.invalidSubtitles }
        if mode == .original { return source }
        guard let raw = cue.translatedText else { throw SubtitleError.invalidSubtitles }
        let translated = normalized(raw)
        guard !translated.isEmpty else { throw SubtitleError.invalidSubtitles }
        return mode == .bilingual && source != translated ? source + "\n" + translated : translated
    }

    static func normalized(_ text: String) -> String {
        let newlines = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{2028}", with: "\n")
            .replacingOccurrences(of: "\u{2029}", with: "\n")
        let cleanScalars = newlines.unicodeScalars.filter {
            // Foundation's controlCharacters also contains format characters such
            // as the ZWJ in emoji. Remove C0/C1 controls while preserving Unicode
            // shaping, combining marks, RTL text and emoji sequences.
            $0 == "\n" || $0 == "\t" || ($0.value >= 0x20 && !(0x7F...0x9F).contains($0.value) && $0.value != 0xFEFF)
        }
        // Blank lines would terminate an SRT cue. Preserve visible line breaks only.
        return String(String.UnicodeScalarView(cleanScalars)).split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    private static func milliseconds(_ value: Double) -> Int64 {
        // Called only after finite, nonnegative, two-hour bounds were checked.
        guard value.isFinite, value >= 0, value <= 7_200.05 else { return -1 }
        return Int64((value * 1_000).rounded())
    }

    private static func timestamp(_ value: Double) -> String {
        let total = milliseconds(value)
        return String(format: "%02lld:%02lld:%02lld,%03lld", total / 3_600_000,
                      (total / 60_000) % 60, (total / 1_000) % 60, total % 1_000)
    }
}
