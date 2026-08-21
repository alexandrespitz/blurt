import Foundation

/// Keeps the live-preview line showing the *newest* words.
///
/// SwiftUI's head-truncation proved unreliable here — once the line filled, it
/// quietly kept the oldest text and hid everything new, which is exactly
/// backwards for dictation. So the trimming is done by hand: keep the tail,
/// cut at a word boundary, mark the cut with an ellipsis.
enum PreviewTail {

    static func trim(_ text: String, limit: Int = 56) -> String {
        guard text.count > limit else { return text }
        let tail = String(text.suffix(limit))
        // Drop the likely-partial first word so the line starts cleanly.
        if let space = tail.firstIndex(of: " "), space != tail.indices.last {
            return "…" + tail[tail.index(after: space)...]
        }
        return "…" + tail
    }
}
