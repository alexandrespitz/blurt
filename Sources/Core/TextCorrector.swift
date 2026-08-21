import Foundation

/// A correction Blurt has learned or been given.
struct CorrectionRule: Codable, Equatable, Identifiable {
    enum Source: String, Codable {
        case manual      // typed into the dashboard
        case learned     // derived from repeated history edits
    }

    var id: UUID
    var heard: String        // what the model keeps writing
    var replacement: String  // what you actually say
    var source: Source
    var hits: Int            // times it has fired
    var enabled: Bool
    var createdAt: Date

    init(heard: String, replacement: String, source: Source) {
        self.id = UUID()
        self.heard = heard
        self.replacement = replacement
        self.source = source
        self.hits = 0
        self.enabled = true
        self.createdAt = Date()
    }
}

/// A word or name the model should get right.
struct VocabTerm: Codable, Equatable, Identifiable {
    var id: UUID
    var text: String
    var addedAt: Date

    init(text: String) {
        self.id = UUID()
        self.text = text
        self.addedAt = Date()
    }
}

/// Fixes transcripts locally, after the model has spoken.
///
/// Two mechanisms, both conservative by design — a wrong "correction" is worse
/// than a missed one:
///
/// - **Rules** are exact phrase replacements ("github" → "GitHub"),
///   matched on word boundaries, case-insensitively.
/// - **Terms** are fuzzy: a transcript word close enough to a known term is
///   assumed to be that term misheard. Guarded by length, a shared first
///   letter, and a similarity floor, which is what keeps "or" from ever
///   becoming "VR".
enum TextCorrector {

    struct Outcome: Equatable {
        var text: String
        var appliedRules: [UUID]
        var appliedTerms: [String]
        var changed: Bool { !(appliedRules.isEmpty && appliedTerms.isEmpty) }
    }

    static let minFuzzyLength = 4
    static let minSimilarity = 0.78

    static func apply(_ text: String, rules: [CorrectionRule], terms: [VocabTerm]) -> Outcome {
        var outcome = Outcome(text: text, appliedRules: [], appliedTerms: [])
        guard !text.isEmpty else { return outcome }

        for rule in rules where rule.enabled {
            let replaced = replacePhrase(
                in: outcome.text, phrase: rule.heard, with: rule.replacement)
            if replaced != outcome.text {
                outcome.text = replaced
                outcome.appliedRules.append(rule.id)
            }
        }

        if !terms.isEmpty {
            let (fuzzed, applied) = applyTerms(to: outcome.text, terms: terms)
            outcome.text = fuzzed
            outcome.appliedTerms = applied
        }

        return outcome
    }

    // MARK: - Exact phrase rules

    /// Replaces a phrase wherever it appears between word boundaries,
    /// case-insensitively, keeping the replacement's own casing.
    static func replacePhrase(in text: String, phrase: String, with replacement: String) -> String {
        let trimmed = phrase.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return text }

        let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: trimmed)
            + "(?![\\p{L}\\p{N}])"
        guard let regex = try? NSRegularExpression(
            pattern: pattern, options: [.caseInsensitive]) else { return text }

        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(
            in: text, range: range,
            withTemplate: NSRegularExpression.escapedTemplate(for: replacement))
    }

    // MARK: - Fuzzy vocabulary terms

    private static func applyTerms(to text: String, terms: [VocabTerm]) -> (String, [String]) {
        var applied: [String] = []
        var tokens = tokenize(text)

        for index in tokens.indices where tokens[index].isWord {
            let word = tokens[index].text
            guard word.count >= minFuzzyLength else { continue }

            for term in terms {
                let canonical = term.text
                guard canonical.count >= minFuzzyLength else { continue }

                if word.caseInsensitiveCompare(canonical) == .orderedSame {
                    // Right word, maybe wrong casing — canonical wins.
                    if word != canonical {
                        tokens[index].text = canonical
                        applied.append(canonical)
                    }
                    break
                }

                guard isPlausibleMishearing(word, of: canonical) else { continue }
                tokens[index].text = canonical
                applied.append(canonical)
                break
            }
        }

        return (tokens.map(\.text).joined(), applied)
    }

    /// The guardrails: long enough to be distinctive, similar length, same
    /// first letter, high similarity. Words under six letters are never
    /// fuzzy-corrected — that is what keeps "form" from becoming "forum".
    static func isPlausibleMishearing(_ word: String, of canonical: String) -> Bool {
        let a = word.lowercased()
        let b = canonical.lowercased()
        guard a != b else { return false }
        guard max(a.count, b.count) >= 6 else { return false }
        guard let fa = a.first, let fb = b.first, fa == fb else { return false }

        let ratio = Double(a.count) / Double(b.count)
        guard ratio > 0.6 && ratio < 1.55 else { return false }

        let distance = levenshtein(a, b)
        let similarity = 1.0 - Double(distance) / Double(max(a.count, b.count))
        return similarity >= minSimilarity
    }

    static func levenshtein(_ a: String, _ b: String) -> Int {
        let aa = Array(a), bb = Array(b)
        if aa.isEmpty { return bb.count }
        if bb.isEmpty { return aa.count }
        var previous = Array(0...bb.count)
        var current = [Int](repeating: 0, count: bb.count + 1)
        for i in 1...aa.count {
            current[0] = i
            for j in 1...bb.count {
                let cost = aa[i - 1] == bb[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            swap(&previous, &current)
        }
        return previous[bb.count]
    }

    // MARK: - Tokenizing

    struct Token {
        var text: String
        var isWord: Bool
    }

    /// Splits text into word and non-word runs so it can be reassembled
    /// verbatim — punctuation and spacing survive untouched.
    static func tokenize(_ text: String) -> [Token] {
        var tokens: [Token] = []
        var current = ""
        var currentIsWord: Bool?

        for char in text {
            let isWord = char.isLetter || char.isNumber
            if currentIsWord == nil || currentIsWord == isWord {
                current.append(char)
                currentIsWord = isWord
            } else {
                tokens.append(Token(text: current, isWord: currentIsWord!))
                current = String(char)
                currentIsWord = isWord
            }
        }
        if let currentIsWord, !current.isEmpty {
            tokens.append(Token(text: current, isWord: currentIsWord))
        }
        return tokens
    }
}
