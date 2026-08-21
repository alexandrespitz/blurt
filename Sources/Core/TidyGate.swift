import Foundation

/// The sanity check between the tidy model and your clipboard.
///
/// Pure logic, kept apart from the Apple Intelligence plumbing so it can be
/// tested without the model: a tidied transcript must still be your words —
/// same or fewer of them, never gutted, never an essay.
enum TidyGate {

    static func sane(original: String, cleaned: String) -> Bool {
        guard !cleaned.isEmpty else { return false }
        let originalWords = original.split(separator: " ").count
        let cleanedWords = cleaned.split(separator: " ").count
        guard cleanedWords > 0 else { return false }
        // Tidying removes fillers; it must never grow the text much or gut it.
        return cleanedWords <= originalWords + 5
            && Double(cleanedWords) >= Double(originalWords) * 0.4
    }
}
