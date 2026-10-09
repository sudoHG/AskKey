import Foundation

/// Word-level difference between two texts, used to highlight edits to the
/// instructions for agents. Chinese and Japanese characters count as words.
struct ApprovalTextDiff: Equatable {
    enum Kind: Equatable { case same, removed, added }

    struct Run: Equatable {
        let text: String
        let kind: Kind
    }

    /// The old text: unchanged and removed runs.
    let before: [Run]
    /// The new text: unchanged and added runs.
    let after: [Run]
    /// Both texts in one: unchanged, removed and added runs in reading order.
    let merged: [Run]
    /// Each removed stretch of words without surrounding spaces and
    /// punctuation, for the "Removed:" line.
    let removedPhrases: [String]

    /// Beyond this many token pairs the changed middle counts as rewritten.
    private static let comparisonLimit = 250_000

    init(before: String, after: String) {
        let old = Self.tokens(before)
        let new = Self.tokens(after)
        var prefix = 0
        while prefix < min(old.count, new.count), old[prefix] == new[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < min(old.count, new.count) - prefix,
              old[old.count - 1 - suffix] == new[new.count - 1 - suffix] { suffix += 1 }
        let oldMiddle = Array(old[prefix..<(old.count - suffix)])
        let newMiddle = Array(new[prefix..<(new.count - suffix)])
        let (oldKept, newKept) = Self.commonTokens(oldMiddle, newMiddle)
        let head = Array(old[..<prefix]).map { ($0, Kind.same) }
        let oldTail = Array(old[(old.count - suffix)...]).map { ($0, Kind.same) }
        let newTail = Array(new[(new.count - suffix)...]).map { ($0, Kind.same) }
        let oldRuns = head + oldMiddle.indices.map { (oldMiddle[$0], oldKept.contains($0) ? Kind.same : .removed) } + oldTail
        let newRuns = head + newMiddle.indices.map { (newMiddle[$0], newKept.contains($0) ? Kind.same : .added) } + newTail
        // Kept tokens pair up in order, so walking both middles interleaves
        // each removal before the addition that replaces it.
        var middle: [(String, Kind)] = []
        var i = 0, j = 0
        while i < oldMiddle.count || j < newMiddle.count {
            if i < oldMiddle.count, !oldKept.contains(i) {
                middle.append((oldMiddle[i], .removed)); i += 1
            } else if j < newMiddle.count, !newKept.contains(j) {
                middle.append((newMiddle[j], .added)); j += 1
            } else if i < oldMiddle.count, j < newMiddle.count {
                middle.append((newMiddle[j], .same)); i += 1; j += 1
            } else {
                break
            }
        }
        self.before = Self.runs(oldRuns)
        self.after = Self.runs(newRuns)
        merged = Self.runs(head + middle + newTail)
        removedPhrases = self.before.filter { $0.kind == .removed }
            .map { $0.text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)) }
            .filter { phrase in phrase.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) } }
    }

    /// Words, single CJK characters, whitespace runs and single punctuation marks.
    static func tokens(_ text: String) -> [String] {
        var tokens: [String] = []
        var word = ""
        var space = ""
        func flush() {
            if !word.isEmpty { tokens.append(word); word = "" }
            if !space.isEmpty { tokens.append(space); space = "" }
        }
        for character in text {
            if character.isWhitespace {
                if !word.isEmpty { tokens.append(word); word = "" }
                space.append(character)
            } else if isIdeograph(character) || !(character.isLetter || character.isNumber || character == "_") {
                flush()
                tokens.append(String(character))
            } else {
                if !space.isEmpty { tokens.append(space); space = "" }
                word.append(character)
            }
        }
        flush()
        return tokens
    }

    private static func isIdeograph(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x2FA1F: return true
            default: return false
            }
        }
    }

    /// Indexes of the heaviest common token subsequence in each side. Words
    /// outweigh punctuation and spaces, so shared words line up first.
    private static func commonTokens(_ old: [String], _ new: [String]) -> (Set<Int>, Set<Int>) {
        guard !old.isEmpty, !new.isEmpty, old.count * new.count <= comparisonLimit else { return ([], []) }
        func weight(_ token: String) -> Int {
            if token.allSatisfy(\.isWhitespace) { return 1 }
            return token.contains { $0.isLetter || $0.isNumber } ? 3 : 2
        }
        var lengths = Array(repeating: Array(repeating: 0, count: new.count + 1), count: old.count + 1)
        for i in stride(from: old.count - 1, through: 0, by: -1) {
            for j in stride(from: new.count - 1, through: 0, by: -1) {
                lengths[i][j] = old[i] == new[j]
                    ? lengths[i + 1][j + 1] + weight(old[i]) : max(lengths[i + 1][j], lengths[i][j + 1])
            }
        }
        var oldKept = Set<Int>(), newKept = Set<Int>()
        var i = 0, j = 0
        while i < old.count, j < new.count {
            if old[i] == new[j] {
                oldKept.insert(i); newKept.insert(j); i += 1; j += 1
            } else if lengths[i + 1][j] >= lengths[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        return (oldKept, newKept)
    }

    /// Joins neighbouring tokens of one kind; a lone space between two
    /// changed words joins the change so phrases read as one.
    private static func runs(_ tokens: [(String, Kind)]) -> [Run] {
        var marked = tokens
        for index in marked.indices.dropFirst().dropLast()
        where marked[index].1 == .same && marked[index].0.allSatisfy(\.isWhitespace)
            && marked[index - 1].1 != .same && marked[index - 1].1 == marked[index + 1].1 {
            marked[index].1 = marked[index - 1].1
        }
        var runs: [Run] = []
        for (text, kind) in marked {
            if let last = runs.last, last.kind == kind {
                runs[runs.count - 1] = Run(text: last.text + text, kind: kind)
            } else {
                runs.append(Run(text: text, kind: kind))
            }
        }
        return runs
    }
}
