import XCTest

/// The learning loop: corrections applied safely, and rules earned from edits.
final class LearningTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("parakeet-learning-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        AppPaths.rootOverride = directory
    }

    override func tearDownWithError() throws {
        AppPaths.rootOverride = nil
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - TextCorrector

    func testRuleReplacesOnWordBoundariesOnly() {
        let rule = CorrectionRule(heard: "git hub", replacement: "GitHub", source: .manual)
        let outcome = TextCorrector.apply(
            "I spoke to git hub about the Git Hub offer, not githublike things.",
            rules: [rule], terms: [])
        XCTAssertEqual(
            outcome.text,
            "I spoke to GitHub about the GitHub offer, not githublike things.")
        XCTAssertEqual(outcome.appliedRules, [rule.id])
    }

    func testDisabledRuleDoesNothing() {
        var rule = CorrectionRule(heard: "supa base", replacement: "Supabase", source: .manual)
        rule.enabled = false
        let outcome = TextCorrector.apply("we use supa base", rules: [rule], terms: [])
        XCTAssertEqual(outcome.text, "we use supa base")
    }

    func testFuzzyTermCorrectsCloseMisses() {
        let terms = [VocabTerm(text: "Supabase")]
        let outcome = TextCorrector.apply(
            "The data lives in Supabass right now.", rules: [], terms: terms)
        XCTAssertEqual(outcome.text, "The data lives in Supabase right now.")
        XCTAssertEqual(outcome.appliedTerms, ["Supabase"])
    }

    func testFuzzyTermFixesCasingOfExactMatches() {
        let terms = [VocabTerm(text: "GitHub")]
        let outcome = TextCorrector.apply("github called back", rules: [], terms: terms)
        XCTAssertEqual(outcome.text, "GitHub called back")
    }

    func testFuzzyGuardrailsRefuseWildMatches() {
        // Different first letter: never corrected.
        XCTAssertFalse(TextCorrector.isPlausibleMishearing("parakeet", of: "karaoke"))
        // Too far apart: never corrected.
        XCTAssertFalse(TextCorrector.isPlausibleMishearing("grid", of: "gradient"))
        // Short words never fuzzy-match at all (guarded by caller's length check),
        // and similar-but-real words stay untouched.
        XCTAssertFalse(TextCorrector.isPlausibleMishearing("form", of: "forum"))

        let terms = [VocabTerm(text: "Linear")]
        let outcome = TextCorrector.apply(
            "a linear function is not the app", rules: [], terms: terms)
        XCTAssertEqual(
            outcome.text, "a Linear function is not the app",
            "an exact word only gets its casing fixed — that is the accepted trade-off")
    }

    func testPunctuationAndSpacingSurviveCorrection() {
        let terms = [VocabTerm(text: "Supabase")]
        let outcome = TextCorrector.apply(
            "Deploy (supabass), then celebrate!", rules: [], terms: terms)
        XCTAssertEqual(outcome.text, "Deploy (Supabase), then celebrate!")
    }

    // MARK: - WordDiff

    func testDiffFindsTheSubstitution() {
        let changes = WordDiff.changes(
            from: "talk to git hub tomorrow",
            to: "talk to GitHub tomorrow")
        XCTAssertEqual(changes, [WordDiff.Change(heard: "git hub", corrected: "GitHub")])
    }

    func testPureInsertionsAndDeletionsTeachNothing() {
        XCTAssertEqual(WordDiff.changes(from: "send the note", to: "send the note today"), [])
        XCTAssertEqual(WordDiff.changes(from: "send the note today", to: "send the note"), [])
    }

    func testMultipleFixesInOneEdit() {
        let changes = WordDiff.changes(
            from: "the super base migration and the lineal ticket",
            to: "the Supabase migration and the Linear ticket")
        XCTAssertEqual(changes.count, 2)
        XCTAssertEqual(changes[0], WordDiff.Change(heard: "super base", corrected: "Supabase"))
        XCTAssertEqual(changes[1], WordDiff.Change(heard: "lineal", corrected: "Linear"))
    }

    // MARK: - VocabularyStore learning

    func testSameFixTwiceBecomesARule() throws {
        let store = VocabularyStore(url: directory.appendingPathComponent("vocab.json"))

        var promoted = store.learn(from: "email git hub now", to: "email GitHub now")
        XCTAssertTrue(promoted.isEmpty, "one observation is a coincidence")
        XCTAssertTrue(store.rules.isEmpty)

        promoted = store.learn(from: "the git hub demo", to: "the GitHub demo")
        XCTAssertEqual(promoted.count, 1, "the second observation is a pattern")
        XCTAssertEqual(store.rules.count, 1)
        XCTAssertEqual(store.rules[0].heard, "git hub")
        XCTAssertEqual(store.rules[0].replacement, "GitHub")
        XCTAssertEqual(store.rules[0].source, .learned)

        // And the rule now actually fires.
        let outcome = TextCorrector.apply(
            "ping git hub about it", rules: store.enabledRules, terms: [])
        XCTAssertEqual(outcome.text, "ping GitHub about it")
    }

    func testContradictoryFixesResetTheCount() {
        let store = VocabularyStore(url: directory.appendingPathComponent("vocab2.json"))
        store.learn(from: "call anna", to: "call Ana")
        store.learn(from: "call anna", to: "call Hannah")  // changed their mind
        store.learn(from: "call anna", to: "call Hannah")
        XCTAssertEqual(store.rules.count, 1, "only the consistent correction graduates")
        XCTAssertEqual(store.rules[0].replacement, "Hannah")
    }

    func testLearningSurvivesAReload() {
        let url = directory.appendingPathComponent("vocab3.json")
        let store = VocabularyStore(url: url)
        store.addTerm("Supabase")
        store.learn(from: "at super base", to: "at Supabase")

        let reloaded = VocabularyStore(url: url)
        XCTAssertEqual(reloaded.terms.map(\.text), ["Supabase"])
        // The pending half-observation must survive too: one more edit graduates it.
        let promoted = reloaded.learn(from: "the super base keys", to: "the Supabase keys")
        XCTAssertEqual(promoted.count, 1)
    }

    func testExistingRuleIsNotRelearned() {
        let store = VocabularyStore(url: directory.appendingPathComponent("vocab4.json"))
        store.addRule(heard: "git hub", replacement: "GitHub", source: .manual)
        let promoted = store.learn(from: "git hub call", to: "GitHub call")
        XCTAssertTrue(promoted.isEmpty)
        XCTAssertEqual(store.rules.count, 1)
    }

    // MARK: - Old history files still load

    func testHistoryEntryWithoutRawTextDecodes() throws {
        let json = """
            [{"id":"\(UUID().uuidString)","date":"2026-08-11T18:00:00Z",
            "text":"hello","duration":2,"recovered":false}]
            """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let entries = try decoder.decode([HistoryEntry].self, from: Data(json.utf8))
        XCTAssertEqual(entries.count, 1)
        XCTAssertNil(entries[0].rawText)
    }

    // MARK: - Tidy sanity gate (pure logic; the model itself is not under test)

    func testTidySanityGate() {
        XCTAssertTrue(TidyGate.sane(
            original: "um so the thing is we should ship it",
            cleaned: "We should ship it."))
        XCTAssertFalse(TidyGate.sane(original: "ship it now please", cleaned: ""))
        XCTAssertFalse(
            TidyGate.sane(
                original: "short note",
                cleaned: "A very long essay that has clearly invented a great deal of new content from nowhere"),
            "growth means the model added things — keep the original")
    }
}
