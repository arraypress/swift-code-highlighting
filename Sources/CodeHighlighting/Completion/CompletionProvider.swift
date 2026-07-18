import Foundation
import CodeLanguage

/// One row of the completion popup: what gets inserted, plus the little that
/// makes the row readable at a glance. Presentation (icon, layout) is the
/// popup's job — this only says which tier the row came from.
public struct CompletionItem: Equatable {
    /// The identifier inserted when the row is accepted.
    public let text: String
    /// Definition kind, drawn as the row's icon. Nil for a buffer word — that
    /// tier is "a string that appears in this file", not a definition.
    public let kind: SymbolKind?
    /// The defining file, drawn as the row's trailing label. Set only for the
    /// project tier: a current-file symbol's file is the one already on screen,
    /// and a buffer word has no definition site.
    public let detail: String?

    public init(text: String, kind: SymbolKind?, detail: String?) {
        self.text = text
        self.kind = kind
        self.detail = detail
    }
}

/// Candidate source for the editor's completion popup — both the as-you-type
/// one (debounced) and the manual `complete(_:)` (Esc / F5). No model, no
/// language server: three prefix-matched tiers over what the editor already
/// knows. Pure logic (no AppKit) so the ranking is independently testable.
///
/// Candidates, in rank order (case-insensitive prefix match, deduped
/// preserving rank, capped at `maxCandidates`):
///   1. Current-file symbols — functions/types/methods from the tree-sitter
///      symbol queries (empty for languages without one).
///   2. Project symbols — `ProjectSymbolIndex.definitions(matchingPrefix:limit:)`,
///      a binary search over the index's sorted name mirror. Carries the
///      defining file so the popup can show it.
///   3. Unique identifier-shaped words from the open buffer (>= 3 chars,
///      same charset as the editor's `identifierRange`: alphanumerics + `_`
///      + `$`, not starting with a digit).
///
/// Performance: tiers 1 and 3 are cached and an edit only *marks* them stale
/// (`noteEdit()` — two nil stores); tier 2 is not cached because it is already
/// O(log n) per query and its results are prefix-specific. Nothing here runs
/// per keystroke: the popup debounces, so a rebuild costs once per typing
/// pause, and `autoPopupThreshold` keeps the automatic path off files where
/// that rebuild (a whole-document symbol query + a whole-buffer word scan)
/// would be felt. Above `wordScanThreshold` the buffer-word scan is skipped
/// outright even on the manual path — it would beachball a multi-MB buffer.
public final class CompletionProvider {

    public init() {}

    /// Most candidates ever returned for one trigger.
    public static let maxCandidates = 50
    /// Buffer words shorter than this never become candidates.
    public static let minWordLength = 3
    /// Mirror of `EditorViewController.highlightDisabledThreshold` (UTF-16
    /// units): the ceiling for the buffer-word scan, and for the symbol tier
    /// ONLY on the static fallback (no `symbolsProvider`), whose full parse per
    /// rebuild would beachball a multi-MB buffer. The editor always wires the
    /// provider, so in the app this cap governs the word tier.
    public static let wordScanThreshold = 3_000_000
    /// Mirror of `EditorViewController.fullHighlightThreshold` (UTF-16 units):
    /// the editor's existing "this file is big" line, and the ceiling for the
    /// AUTOMATIC popup only. Above it, every tier-1/tier-3 rebuild is a
    /// whole-document symbol query plus a whole-buffer word scan, and an edit
    /// invalidates both — so the automatic path would pay that per typing
    /// pause. At the cap that rebuild measures ~8 ms (release, a 100 KB Swift
    /// file, via `--dump-completions`) and grows with file size. Esc/F5 still
    /// completes at any size (a deliberate act, not a per-pause one); this cap
    /// only governs the popup that fires by itself.
    public static let autoPopupThreshold = 100_000
    /// Hard cap on the cached word set, so a pathological file (huge minified
    /// blob under the size threshold) can't balloon memory.
    private static let maxUniqueWords = 50_000
    /// Identifier-shaped words longer than this (base64-ish blobs) are skipped.
    private static let maxWordLength = 64

    /// Sorted unique current-file symbols; nil = stale, rebuilt on demand.
    private var cachedFileSymbols: [CompletionItem]?
    /// Sorted unique buffer words; nil = stale, rebuilt on demand. Held as
    /// strings, not items: this tier can hold `maxUniqueWords` entries and only
    /// the handful that match a prefix ever need wrapping.
    private var cachedBufferWords: [String]?

    /// Optional override for the symbol-tier rebuild. When set (the editor
    /// wires it to its highlight session's CACHED syntax tree — query-only,
    /// no parse), it replaces the static `TreeSitterHighlighter.symbols`
    /// path, whose fresh full parse per rebuild beachballs on huge files.
    public var symbolsProvider: (() -> [Symbol])?

    /// The project-symbol tier's prefix query (the editor wires it to
    /// `ProjectSymbolIndex`). Takes the partial identifier, returns at most one
    /// definition per matching name. Nil (or an unbuilt index) just yields an
    /// empty tier — the other two still rank.
    public var projectSymbolsProvider: ((String) -> [DefLocation])?

    /// Marks both cached candidate tiers stale. Cheap enough for every
    /// keystroke; must also be called on document swap/reload, language change,
    /// and any buffer mutation that bypasses `textDidChange` (multi-edit batch
    /// replace, Replace All).
    public func noteEdit() {
        cachedFileSymbols = nil
        cachedBufferWords = nil
    }

    /// Ranked completion candidates for `partial` (the text the editor will
    /// replace). Rebuilds whichever caches are stale from `text`, queries the
    /// project tier, then ranks. Empty `partial` yields no candidates (no
    /// popup). Main thread only — the caches install and invalidate there.
    public func completions(for partial: String, text: String,
                            language: CodeLanguage.Language) -> [CompletionItem] {
        guard !partial.isEmpty else { return [] }
        if cachedFileSymbols == nil {
            if let provider = symbolsProvider {
                // Session-backed: reads the cached syntax tree, no parse.
                cachedFileSymbols = Self.sortedUniqueItems(provider().map {
                    CompletionItem(text: $0.name, kind: $0.kind, detail: nil)
                })
            } else {
                // Same cap as the word scan: symbols() runs a full synchronous
                // tree-sitter parse — a main-thread hang on huge files (whose
                // highlighting the editor already disables at this threshold).
                cachedFileSymbols = text.utf16.count <= Self.wordScanThreshold
                    ? Self.sortedUniqueItems(
                        TreeSitterHighlighter.symbols(in: text, language: language).map {
                            CompletionItem(text: $0.name, kind: $0.kind, detail: nil)
                        })
                    : []
            }
        }
        if cachedBufferWords == nil {
            cachedBufferWords = Self.bufferWords(in: text)
        }
        let project = (projectSymbolsProvider?(partial) ?? []).map {
            CompletionItem(text: $0.name, kind: $0.kind, detail: $0.url.lastPathComponent)
        }
        return Self.rank(partial: partial,
                         fileSymbols: cachedFileSymbols ?? [],
                         projectSymbols: project,
                         bufferWords: cachedBufferWords ?? [])
    }

    // MARK: - Pure ranking / scanning (testable)

    /// Case-insensitive prefix matches of `partial`, walking the tiers in rank
    /// order (file symbols, project symbols, buffer words). Dedupes on the
    /// inserted text preserving first (highest) rank, drops the candidate
    /// identical to `partial` (completing to itself is noise), caps at `cap`.
    /// Tiers are expected pre-sorted, so results are alphabetical within each
    /// tier.
    public static func rank(partial: String, fileSymbols: [CompletionItem],
                            projectSymbols: [CompletionItem], bufferWords: [String],
                            cap: Int = maxCandidates) -> [CompletionItem] {
        guard !partial.isEmpty, cap > 0 else { return [] }
        let needle = partial.lowercased()
        var seen = Set<String>()
        var out: [CompletionItem] = []

        /// Takes `item` unless it duplicates a higher tier, fails the prefix, or
        /// completes to `partial` itself. False once `cap` is reached — stop.
        func take(_ item: CompletionItem) -> Bool {
            guard out.count < cap else { return false }
            guard item.text != partial,
                  item.text.lowercased().hasPrefix(needle),
                  seen.insert(item.text).inserted else { return true }
            out.append(item)
            return out.count < cap
        }

        for tier in [fileSymbols, projectSymbols] {
            for item in tier {
                if !take(item) { return out }
            }
        }
        // Wrapped only once matched — this tier can hold `maxUniqueWords`
        // strings, and mapping it wholesale would allocate an item per word.
        for word in bufferWords {
            if !take(CompletionItem(text: word, kind: nil, detail: nil)) { return out }
        }
        return out
    }

    /// Unique identifier-shaped words in `text`, sorted: runs of identifier
    /// characters (alphanumerics + `_` + `$` — the editor's `identifierRange`
    /// charset) that don't start with a digit, `minWordLength...maxWordLength`
    /// long. Empty above `wordScanThreshold` and after `maxUniqueWords` hits.
    public static func bufferWords(in text: String) -> [String] {
        guard text.utf16.count <= wordScanThreshold else { return [] }
        var words = Set<String>()
        let scalars = text.unicodeScalars
        var i = scalars.startIndex
        let end = scalars.endIndex
        while i < end {
            // Skip non-identifier scalars to the next word start.
            while i < end, !isIdentifierScalar(scalars[i]) { i = scalars.index(after: i) }
            guard i < end else { break }
            let wordStart = i
            let startsWithDigit = (0x30...0x39).contains(scalars[i].value)
            var length = 0
            while i < end, isIdentifierScalar(scalars[i]) {
                i = scalars.index(after: i)
                length += 1
            }
            if !startsWithDigit, length >= minWordLength, length <= maxWordLength {
                words.insert(String(scalars[wordStart..<i]))
                if words.count >= maxUniqueWords { break }
            }
        }
        return sortedUnique(Array(words))
    }

    /// Identifier charset test with an ASCII fast path (the scan visits every
    /// scalar of the buffer; `CharacterSet.contains` is only paid for non-ASCII).
    private static func isIdentifierScalar(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, 0x5F /* _ */, 0x24 /* $ */:
            return true
        case ..<0x80:
            return false
        default:
            return CharacterSet.alphanumerics.contains(s)
        }
    }

    /// Dedupe (exact) then sort case-insensitively, case-sensitive tiebreak —
    /// a stable, predictable popup order within each tier.
    private static func sortedUnique(_ names: [String]) -> [String] {
        var seen = Set<String>()
        let unique = names.filter { seen.insert($0).inserted }
        return unique.sorted {
            let c = $0.caseInsensitiveCompare($1)
            return c == .orderedSame ? $0 < $1 : c == .orderedAscending
        }
    }

    /// `sortedUnique` for items — deduped on the inserted text, keeping the
    /// first item for a name (its kind/detail), in the same order.
    private static func sortedUniqueItems(_ items: [CompletionItem]) -> [CompletionItem] {
        var seen = Set<String>()
        let unique = items.filter { seen.insert($0.text).inserted }
        return unique.sorted {
            let c = $0.text.caseInsensitiveCompare($1.text)
            return c == .orderedSame ? $0.text < $1.text : c == .orderedAscending
        }
    }
}
