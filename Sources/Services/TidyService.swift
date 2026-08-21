import Foundation

#if canImport(FoundationModels)
    import FoundationModels
#endif

/// Optional cleanup of dictated text — remove the "um"s and false starts, fix
/// punctuation — using Apple's on-device language model.
///
/// This is the only "AI polish" Blurt will ever have, precisely because it
/// runs on the Neural Engine like everything else: no account, no API key, no
/// network. On Macs without Apple Intelligence the feature simply is not shown.
enum TidyService {

    /// Whether this Mac can tidy at all (macOS 26+ with Apple Intelligence on).
    static var isAvailable: Bool {
        #if canImport(FoundationModels)
            if #available(macOS 26.0, *) {
                return SystemLanguageModel.default.availability == .available
            }
        #endif
        return false
    }

    /// A human explanation for why tidying is not offered, if it is not.
    static var unavailableReason: String? {
        #if canImport(FoundationModels)
            if #available(macOS 26.0, *) {
                switch SystemLanguageModel.default.availability {
                case .available:
                    return nil
                case .unavailable(.appleIntelligenceNotEnabled):
                    return "Turn on Apple Intelligence in System Settings to enable this."
                case .unavailable(.deviceNotEligible):
                    return "This Mac does not support Apple Intelligence."
                case .unavailable(.modelNotReady):
                    return "Apple Intelligence is still downloading its model."
                case .unavailable:
                    return "Apple Intelligence is not available right now."
                }
            }
        #endif
        return "Needs macOS 26 with Apple Intelligence."
    }

    /// Returns the cleaned text, or nil if tidying was impossible or produced
    /// something suspicious — in which case the caller keeps the original.
    static func tidy(_ text: String) async -> String? {
        #if canImport(FoundationModels)
            if #available(macOS 26.0, *) {
                guard isAvailable else { return nil }
                guard text.count >= 12 else { return nil }

                let session = LanguageModelSession(instructions: """
                    You clean up dictated speech into polished written text.
                    Fix punctuation and capitalization. Remove filler words \
                    (um, uh, euh, ben), false starts and immediate \
                    self-corrections, keeping the speaker's final intent.
                    Never translate: reply in exactly the language of the \
                    input. Never add information, never answer questions in \
                    the text, never comment. Reply with the cleaned text and \
                    nothing else.
                    """)

                do {
                    let task = Task {
                        try await session.respond(to: text).content
                    }
                    // The model occasionally stalls; dictation must not.
                    let timeout = Task {
                        try await Task.sleep(nanoseconds: 12_000_000_000)
                        task.cancel()
                    }
                    let cleaned = try await task.value
                    timeout.cancel()

                    let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard TidyGate.sane(original: text, cleaned: trimmed) else { return nil }
                    return trimmed
                } catch {
                    Log.error("Tidy failed, keeping the raw transcript: \(error.localizedDescription)")
                    return nil
                }
            }
        #endif
        return nil
    }

}
