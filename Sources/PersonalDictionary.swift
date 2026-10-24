import Foundation
import NaturalLanguage

/// One entry of the personal dictionary: the spellings an engine writes for a
/// term and how the user wants it written ("клод код, клауд код" → "Claude Code").
struct DictionaryEntry: Codable, Equatable, Identifiable, Sendable {
    /// A replacement fires inside a phrase; a snippet (dictation only) fires
    /// only when the whole dictation equals one of its phrases.
    enum Kind: String, Codable, Equatable, Sendable {
        case replacement
        case snippet
    }

    var id = UUID()
    var kind: Kind = .replacement
    /// Kept as a list; the sheet shows it comma-separated.
    var heard: [String]
    var written: String
    var isEnabled = true

    init(id: UUID = UUID(), kind: Kind = .replacement, heard: [String], written: String, isEnabled: Bool = true) {
        self.id = id
        self.kind = kind
        self.heard = heard
        self.written = written
        self.isEnabled = isEnabled
    }

    private enum CodingKeys: String, CodingKey {
        case id, heard, written, kind
        case isEnabled = "enabled"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        heard = try container.decode([String].self, forKey: .heard)
        written = try container.decode(String.self, forKey: .written)
        isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
        kind = try container.decodeIfPresent(Kind.self, forKey: .kind) ?? .replacement
    }

    /// `kind` is written only for a snippet, so a document without one stays
    /// byte for byte what it was before this field existed.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(heard, forKey: .heard)
        try container.encode(written, forKey: .written)
        try container.encode(isEnabled, forKey: .isEnabled)
        if kind != .replacement {
            try container.encode(kind, forKey: .kind)
        }
    }
}

// MARK: - What the sheet accepts

extension DictionaryEntry {
    /// Why the sheet refuses an entry.
    enum Problem: Error, Equatable, Sendable {
        case noHeard
        /// A comma with nothing after it, or two in a row.
        case emptyVariant
        /// Removing words is not offered: a meeting line left empty would
        /// drop out of the transcript.
        case noWritten
        /// One letter ("и", "в") would replace a word in every sentence.
        case tooShort(String)
        /// Only letters, digits, spaces and hyphens: "т.е." never reaches the
        /// text as one word.
        case punctuation(String)
        /// Words on two lines are never replaced as one phrase.
        case lineBreak
        /// The same spelling twice in one entry's list.
        case repeated(String)
        /// The same spelling in two enabled entries: which one wins would be
        /// a matter of their order.
        case duplicate(String)

        var message: String {
            switch self {
            case .noHeard:
                return String(localized: "Fill in how it is heard.")
            case .emptyVariant:
                return String(localized: "Remove the empty spelling between the commas.")
            case .noWritten:
                return String(localized: "Fill in how to write it. Words can’t be removed.")
            case .tooShort(let variant):
                return String(localized: "“\(variant)” is too short: a single letter would change ordinary words.")
            case .punctuation(let variant):
                return String(localized: "“\(variant)” may hold only letters, digits, spaces and hyphens.")
            case .lineBreak:
                return String(localized: "Keep the words on one line.")
            case .repeated(let variant):
                return String(localized: "“\(variant)” is in the list twice.")
            case .duplicate(let variant):
                return String(localized: "“\(variant)” is already in another entry.")
            }
        }
    }

    /// The comma-separated field as typed. Empty pieces stay, so a stray
    /// comma is reported instead of silently dropped.
    static func variants(fromList list: String) -> [String] {
        list.split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// The first reason to refuse this entry next to `others`, the rest of the
    /// dictionary; nil when it can be saved. An entry it replaces is passed
    /// in `others` with its own id.
    func problem(among others: [DictionaryEntry]) -> Problem? {
        problem(besides: Self.spellings(of: others.filter { $0.id != id }))
    }

    /// The same check against `taken`, the `spellings(of:)` the rest of the
    /// dictionary, so a whole file is checked in one pass. The entry's own
    /// list is checked even while it is switched off: a spelling it repeats
    /// would keep it from being switched on, and its exported file from being
    /// imported. Switched off, it conflicts with no other entry.
    func problem(besides taken: Set<String>) -> Problem? {
        if heard.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) { return .noHeard }
        if heard.contains(where: { $0.trimmingCharacters(in: .whitespaces).isEmpty }) { return .emptyVariant }
        if written.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .noWritten }
        for variant in heard {
            if let problem = Self.problem(ofVariant: variant) { return problem }
        }
        let keys = heard.map(Self.key)
        if let repeated = keys.indices.first(where: { keys[..<$0].contains(keys[$0]) }) {
            return .repeated(heard[repeated])
        }
        guard isEnabled else { return nil }
        return keys.firstIndex(where: taken.contains).map { .duplicate(heard[$0]) }
    }

    /// The spellings of the enabled entries, as the check compares them.
    static func spellings(of entries: [DictionaryEntry]) -> Set<String> {
        Set(entries.filter(\.isEnabled).flatMap { $0.heard.map(key) })
    }

    /// One spelling's own rule, the same for the typed list and a selection.
    private static func problem(ofVariant variant: String) -> Problem? {
        if variant.contains(where: \.isNewline) { return .lineBreak }
        if variant.contains(where: { !($0.isLetter || $0.isNumber || $0.isWhitespace || $0 == "-") }) {
            return .punctuation(variant)
        }
        if variant.filter({ $0.isLetter || $0.isNumber }).count < 2 { return .tooShort(variant) }
        return nil
    }

    /// Text selected in a dictation, taken as one spelling with its edges
    /// trimmed. A comma would split it into several in the list, and the
    /// replacement never crosses other punctuation or a line break, so such
    /// a selection is refused, not cut down or split.
    static func variant(fromSelection selection: Substring) -> Result<String, Problem> {
        let variant = selection.trimmingCharacters(in: .whitespacesAndNewlines)
        if let problem = problem(ofVariant: variant) { return .failure(problem) }
        return .success(variant)
    }

    /// "Клод-Код" and "клод  код" are one spelling.
    private static func key(_ variant: String) -> String {
        let tokenizer = NLTokenizer(unit: .word)
        return DictionaryReplacer.words(in: variant, tokenizer: tokenizer)
            .map { DictionaryReplacer.folded(variant[$0]) }
            .joined(separator: " ")
    }
}

// MARK: - One job's dictionary

/// The dictionary as one dictation, meeting or file sees it, taken when the
/// job starts: an edit made meanwhile applies to the next job.
struct DictionarySnapshot: Sendable, Equatable {
    enum Use: Sendable, Hashable { case dictation, meetings, files }

    var entries: [DictionaryEntry] = []
    var uses: Set<Use> = [.dictation, .meetings, .files]
    /// Russian word forms may match (see `matchesWordForms(engine:language:)`).
    var matchesWordForms = true

    /// Derived the way the engine request is (`SettingsSnapshot.decodeRequest`):
    /// Auto, an empty code and one the engine does not know all leave the
    /// language to the engine, and with Russian they let word forms match.
    /// Another chosen language turns them off: a Russian tagger would bend
    /// its words. The text's own language is never guessed: on a short
    /// dictation the recognizer answers Kazakh or Bulgarian.
    static func matchesWordForms(engine: DictationEngine, language: String) -> Bool {
        let asked = engine.language(for: language)
        return asked == nil || asked == "ru"
    }

    func applies(to use: Use) -> Bool {
        uses.contains(use) && entries.contains(where: \.isEnabled)
    }

    /// nil when there is nothing to replace in this job. Prepares the
    /// variants' word forms, so it is called off the main actor.
    func replacer(for use: Use) -> DictionaryReplacer? {
        guard applies(to: use) else { return nil }
        let replacer = DictionaryReplacer(
            entries: entries,
            matchesWordForms: matchesWordForms,
            includeSnippets: use == .dictation
        )
        return replacer.isEmpty ? nil : replacer
    }
}

// MARK: - Replacement

/// The dictionary prepared for one job. The variants' word forms are worked
/// out once, here, and every text of the job reuses them; both the
/// preparation and the replacement call macOS's tagger, so neither belongs
/// on the main actor.
///
/// One pass, left to right, over the words of the finished text. The result
/// is the text's own slices with the written forms inserted literally, so
/// nothing between the replaced words changes.
struct DictionaryReplacer: Sendable {
    /// Makes a lookup for one batch of texts: a lower-case word → its
    /// dictionary form, or "" for a word macOS does not know. A factory,
    /// because the tagger behind it is worth reusing within a batch but is
    /// not Sendable.
    typealias WordForms = @Sendable () -> (String) -> String

    /// macOS's lemma for one word, tagged on its own and in lower case: a
    /// whole sentence tagged at once gives a capitalised word another form
    /// ("Кода" → "Кода"), and a lower-cased sentence loses the words after a
    /// full stop. The language is set, not detected: detection calls a short
    /// dictation Kazakh, and without it these words get no form at all.
    static let macOSWordForms: WordForms = {
        let tagger = NLTagger(tagSchemes: [.lemma])
        return { word in
            tagger.string = word
            tagger.setLanguage(.russian, range: word.startIndex..<word.endIndex)
            return tagger.tag(at: word.startIndex, unit: .word, scheme: .lemma).0?.rawValue ?? ""
        }
    }

    private struct Rule: Sendable {
        let written: String
        /// Folded spellings of the variant's words.
        let words: [String]
        /// Their folded dictionary forms; nil when only exact spellings count.
        let forms: [String]?
        let letters: Int
    }

    /// A snippet's trigger phrase, folded word by word, and its text as
    /// written (untrimmed: the coordinator trims the delivered text).
    private struct Snippet: Sendable {
        let words: [String]
        let written: String
    }

    /// Longest first (by words, then letters), then in dictionary order.
    private let rules: [Rule]
    private let byWord: [String: [Int]]
    private let byForm: [String: [Int]]
    private let snippets: [Snippet]
    private let makeForms: WordForms

    var isEmpty: Bool { rules.isEmpty && snippets.isEmpty }

    /// `matchesWordForms`: the job's language lets Russian word forms match
    /// (Auto, Russian, or a code the engine does not know). Even then only a
    /// variant written wholly in Cyrillic, with a written form without any,
    /// matches by form: a written form in the same alphabet (a surname) or a
    /// variant that mixes in Latin or digits has no ending to drop.
    /// `includeSnippets` is true only for dictation: a snippet fires only
    /// when the whole text equals one of its phrases, never by word form.
    init(
        entries: [DictionaryEntry],
        matchesWordForms: Bool,
        includeSnippets: Bool = false,
        wordForms: @escaping WordForms = DictionaryReplacer.macOSWordForms
    ) {
        makeForms = wordForms
        let tokenizer = NLTokenizer(unit: .word)
        var lookup: ((String) -> String)?
        var prepared: [(rule: Rule, order: Int)] = []
        var snippets: [Snippet] = []
        for entry in entries where entry.isEnabled {
            switch entry.kind {
            case .snippet:
                guard includeSnippets else { continue }
                // The sheet refuses an empty text; one from elsewhere (an
                // edited export, a future version) would otherwise erase a
                // dictation that matched the trigger.
                guard !entry.written.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                for variant in entry.heard {
                    let ranges = Self.words(in: variant, tokenizer: tokenizer)
                    guard !ranges.isEmpty else { continue }
                    let words = ranges.map { Self.folded(variant[$0]) }
                    snippets.append(Snippet(words: words, written: entry.written))
                }
            case .replacement:
                let written = entry.written.trimmingCharacters(in: .whitespacesAndNewlines)
                // The sheet refuses an empty written form; one from elsewhere
                // would delete words.
                guard !written.isEmpty else { continue }
                let inflects = matchesWordForms && !written.contains(where: Self.isCyrillic)
                for variant in entry.heard {
                    let ranges = Self.words(in: variant, tokenizer: tokenizer)
                    guard !ranges.isEmpty else { continue }
                    let words = ranges.map { Self.folded(variant[$0]) }
                    var forms: [String]?
                    if inflects, variant.contains(where: \.isLetter),
                       variant.allSatisfy({ $0.isWhitespace || $0 == "-" || ($0.isLetter && Self.isCyrillic($0)) }) {
                        let tagged = lookup ?? wordForms()
                        lookup = tagged
                        forms = ranges.map { Self.folded(tagged(variant[$0].lowercased())) }
                    }
                    let rule = Rule(written: written, words: words, forms: forms, letters: words.joined().count)
                    prepared.append((rule, prepared.count))
                }
            }
        }
        self.snippets = snippets
        rules = prepared.sorted {
            ($1.rule.words.count, $1.rule.letters, $0.order) < ($0.rule.words.count, $0.rule.letters, $1.order)
        }.map(\.rule)
        var byWord: [String: [Int]] = [:]
        var byForm: [String: [Int]] = [:]
        for (index, rule) in rules.enumerated() {
            byWord[rule.words[0], default: []].append(index)
            if let first = rule.forms?.first, !first.isEmpty { byForm[first, default: []].append(index) }
        }
        self.byWord = byWord
        self.byForm = byForm
    }

    /// A snippet's match against the whole text, ignoring the punctuation
    /// between its words and at its edges; nil when none of the dictation's
    /// own words, folded, equal a phrase whole.
    private func matchedSnippet(in text: String) -> String? {
        guard !snippets.isEmpty else { return nil }
        let tokenizer = NLTokenizer(unit: .word)
        let words = Self.words(in: text, tokenizer: tokenizer).map { Self.folded(text[$0]) }
        guard !words.isEmpty else { return nil }
        return snippets.first { $0.words == words }?.written
    }

    func replacing(in text: String) -> (text: String, count: Int) {
        if let snippet = matchedSnippet(in: text) { return (snippet, 1) }
        let result = replacing(in: [text])
        return (result.texts[0], result.count)
    }

    /// One tagger for the whole batch: a meeting's lines are one job.
    func replacing(in texts: [String]) -> (texts: [String], count: Int) {
        guard !rules.isEmpty else { return (texts, 0) }
        let tokenizer = NLTokenizer(unit: .word)
        var lookup: ((String) -> String)?
        let form: (String) -> String = { word in
            let tagged = lookup ?? makeForms()
            lookup = tagged
            return Self.folded(tagged(word.lowercased()))
        }
        var count = 0
        let replaced = texts.map { text in
            let result = replace(text, tokenizer: tokenizer, form: form)
            count += result.count
            return result.text
        }
        return (replaced, count)
    }

    private func replace(
        _ text: String,
        tokenizer: NLTokenizer,
        form: (String) -> String
    ) -> (text: String, count: Int) {
        let words = Self.words(in: text, tokenizer: tokenizer)
        let spellings = words.map { Self.folded(text[$0]) }
        var forms = [String?](repeating: nil, count: words.count)
        func formOfWord(_ index: Int) -> String {
            if let known = forms[index] { return known }
            let found = form(String(text[words[index]]))
            forms[index] = found
            return found
        }
        func match(_ rule: Rule, at start: Int) -> (end: Int, exact: Bool)? {
            guard start + rule.words.count <= words.count else { return nil }
            var exact = true
            for offset in rule.words.indices {
                let index = start + offset
                if offset > 0, !Self.joins(text[words[index - 1].upperBound..<words[index].lowerBound]) {
                    return nil
                }
                if spellings[index] == rule.words[offset] { continue }
                guard let ruleForms = rule.forms, !ruleForms[offset].isEmpty,
                      formOfWord(index) == ruleForms[offset] else { return nil }
                exact = false
            }
            return (start + rule.words.count, exact)
        }
        // Where each rule's written form already stands in the text.
        var written: [String: [Range<String.Index>]] = [:]
        func standsWritten(_ rule: Rule, over span: Range<String.Index>) -> Bool {
            let found = written[rule.written] ?? Self.occurrences(of: rule.written, in: text)
            written[rule.written] = found
            return found.contains { $0.lowerBound <= span.lowerBound && span.upperBound <= $0.upperBound }
        }

        var result = ""
        var cursor = text.startIndex
        var count = 0
        var index = 0
        while index < words.count {
            var candidates = byWord[spellings[index]] ?? []
            if !byForm.isEmpty {
                let found = formOfWord(index)
                if !found.isEmpty { candidates += byForm[found] ?? [] }
            }
            // Longest first; at equal length an exact spelling wins over a
            // word form, then the dictionary's order.
            let matches = Set(candidates).compactMap { rule in
                match(rules[rule], at: index).map { (rule: rule, end: $0.end, exact: $0.exact) }
            }.sorted { a, b in
                let (first, second) = (rules[a.rule], rules[b.rule])
                return (second.words.count, second.letters, a.exact ? 0 : 1, a.rule)
                    < (first.words.count, first.letters, b.exact ? 0 : 1, b.rule)
            }
            // "Claude Code" is left alone by a rule that would turn its
            // "Claude" into "Claude Code" again; other rules still apply there.
            let chosen = matches.first {
                !standsWritten(rules[$0.rule], over: words[index].lowerBound..<words[$0.end - 1].upperBound)
            }
            guard let chosen else {
                index += 1
                continue
            }
            result += text[cursor..<words[index].lowerBound]
            result += rules[chosen.rule].written
            cursor = words[chosen.end - 1].upperBound
            index = chosen.end
            count += 1
        }
        guard count > 0 else { return (text, 0) }
        result += text[cursor...]
        return (result, count)
    }

    /// Word ranges as `NLTokenizer` finds them, split again at hyphens: a
    /// hyphen joins the words of a variant ("клод-код") whatever the
    /// tokenizer makes of it.
    static func words(in text: String, tokenizer: NLTokenizer) -> [Range<String.Index>] {
        tokenizer.string = text
        return tokenizer.tokens(for: text.startIndex..<text.endIndex).flatMap { token in
            text[token].split(separator: "-").map { $0.startIndex..<$0.endIndex }
        }
    }

    /// Case and the Russian yo/ye spelling never tell two words apart; й and и do.
    static func folded<S: StringProtocol>(_ word: S) -> String {
        word.lowercased().replacingOccurrences(of: "ё", with: "е")
    }

    /// Words of a variant stand apart in the text by spaces or one hyphen
    /// only: a full stop, a comma or a new line ends the phrase.
    private static func joins(_ gap: Substring) -> Bool {
        gap == "-" || (!gap.isEmpty && gap.allSatisfy { $0.isWhitespace && !$0.isNewline })
    }

    private static func isCyrillic(_ character: Character) -> Bool {
        character.unicodeScalars.first.map { (0x0400...0x052F).contains($0.value) } ?? false
    }

    /// The written form, case and all, standing as a whole word or words.
    private static func occurrences(of written: String, in text: String) -> [Range<String.Index>] {
        var found: [Range<String.Index>] = []
        var start = text.startIndex
        while let range = text.range(of: written, options: .literal, range: start..<text.endIndex) {
            let before = range.lowerBound > text.startIndex ? text[text.index(before: range.lowerBound)] : nil
            let after = range.upperBound < text.endIndex ? text[range.upperBound] : nil
            if !(before.map { $0.isLetter || $0.isNumber } ?? false),
               !(after.map { $0.isLetter || $0.isNumber } ?? false) {
                found.append(range)
            }
            start = text.index(after: range.lowerBound)
        }
        return found
    }
}
