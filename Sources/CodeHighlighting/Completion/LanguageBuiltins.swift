import Foundation
import CodeLanguage

/// A language's built-in identifiers (standard functions, methods, globals) as
/// completion candidates — the tier that lets `array_`→`array_map` work in PHP,
/// `map`/`filter`/`then` across JS objects, `len`/`enumerate` in Python, etc.,
/// without a language server.
///
/// Lean by construction: the lists are plain newline-delimited **names only** (no
/// signatures or docs), shipped as small text resources (~20 KB/language), and
/// loaded + cached lazily — only the languages actually edited ever touch disk or
/// hold memory. Names starting with `#` are comments.
public enum LanguageBuiltins {

    /// Cached, ranked completion items per language (empty for unsupported ones).
    private static var cache: [Language: [CompletionItem]] = [:]
    private static let lock = NSLock()

    /// Built-in completion candidates for `language`, sorted + de-duplicated. Empty
    /// for languages without a bundled list. Thread-safe; loads at most once per
    /// language.
    public static func completions(for language: Language) -> [CompletionItem] {
        lock.lock(); defer { lock.unlock() }
        if let cached = cache[language] { return cached }
        let items = load(resourceName(for: language))
        let sorted = items.sorted { $0.text.caseInsensitiveCompare($1.text) == .orderedAscending }
        cache[language] = sorted
        return sorted
    }

    /// The resource file (in `Builtins/`) backing a language, or nil when there's no
    /// list. TypeScript reuses the JavaScript set.
    private static func resourceName(for language: Language) -> String? {
        switch language {
        case .php:                      return "php"
        case .javascript, .typescript:  return "javascript"
        case .python:                   return "python"
        case .swift:                    return "swift"
        default:                        return nil
        }
    }

    /// Reads a `Builtins/<name>.txt` resource into completion items, dropping blanks
    /// and `#` comments. Each line is either a bare `identifier` or
    /// `identifier⇥signature` (tab-separated) — the signature is shown in the popup
    /// (PhpStorm-style), while only the identifier is inserted.
    private static func load(_ name: String?) -> [CompletionItem] {
        guard let name,
              let url = Bundle.module.url(forResource: name, withExtension: "txt", subdirectory: "Builtins"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var seen = Set<String>()
        var out: [CompletionItem] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(raw)
            guard !line.hasPrefix("#") else { continue }
            let parts = line.split(separator: "\t", maxSplits: 1)
            guard let first = parts.first else { continue }
            let identifier = first.trimmingCharacters(in: .whitespaces)
            guard !identifier.isEmpty, seen.insert(identifier).inserted else { continue }
            let signature = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : nil
            out.append(CompletionItem(text: identifier, kind: .function,
                                      detail: (signature?.isEmpty == false) ? signature : nil))
        }
        return out
    }
}
