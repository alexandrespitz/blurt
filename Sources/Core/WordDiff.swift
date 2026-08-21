import Foundation

/// Finds what actually changed when a transcript was edited by hand.
///
/// This is the input side of the learning loop: an edit like
/// "git hub is hiring" → "GitHub is hiring" yields the pair
/// ("git hub", "GitHub"). See the same fix twice and it becomes a rule.
enum WordDiff {

    struct Change: Equatable {
        var heard: String
        var corrected: String
    }

    /// Longest-common-subsequence diff over words, with adjacent changed runs
    /// merged into single phrase pairs.
    static func changes(from old: String, to new: String) -> [Change] {
        let oldWords = words(old)
        let newWords = words(new)
        guard !oldWords.isEmpty, !newWords.isEmpty else { return [] }
        guard oldWords.count <= 400, newWords.count <= 400 else { return [] }

        // LCS table on lowercased words so a pure casing fix still registers
        // as a change pair (compared exactly below).
        let n = oldWords.count, m = newWords.count
        var lcs = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                if oldWords[i] == newWords[j] {
                    lcs[i][j] = lcs[i + 1][j + 1] + 1
                } else {
                    lcs[i][j] = max(lcs[i + 1][j], lcs[i][j + 1])
                }
            }
        }

        var result: [Change] = []
        var i = 0, j = 0
        var pendingOld: [String] = []
        var pendingNew: [String] = []

        func flush() {
            let heard = pendingOld.joined(separator: " ")
            let corrected = pendingNew.joined(separator: " ")
            if !heard.isEmpty && !corrected.isEmpty && heard != corrected {
                result.append(Change(heard: heard, corrected: corrected))
            }
            pendingOld = []
            pendingNew = []
        }

        while i < n && j < m {
            if oldWords[i] == newWords[j] {
                flush()
                i += 1
                j += 1
            } else if lcs[i + 1][j] >= lcs[i][j + 1] {
                pendingOld.append(oldWords[i])
                i += 1
            } else {
                pendingNew.append(newWords[j])
                j += 1
            }
        }
        pendingOld.append(contentsOf: oldWords[i...])
        pendingNew.append(contentsOf: newWords[j...])
        flush()

        // Insertions and deletions (one side empty) never became pairs above;
        // only substitutions teach us anything about mishearing.
        return result.filter { change in
            // A pair where either side is enormous is a rewrite, not a fix.
            change.heard.count <= 60 && change.corrected.count <= 60
        }
    }

    private static func words(_ text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }
            .filter { !$0.isEmpty }
    }
}
