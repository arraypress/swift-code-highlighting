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
            .map { CompletionItem(text: $0, kind: .function, detail: nil) }
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
        default:                        return nil
        }
    }

    /// Reads a `Builtins/<name>.txt` resource into deduped identifier lines,
    /// dropping blanks and `#` comments.
    private static func load(_ name: String?) -> [String] {
        guard let name,
              let url = Bundle.module.url(forResource: name, withExtension: "txt", subdirectory: "Builtins"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var seen = Set<String>()
        var out: [String] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), seen.insert(line).inserted else { continue }
            out.append(line)
        }
        return out
    }
}
