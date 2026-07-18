import Foundation

/// Extracts a Markdown document's ATX headings (`#`…`######`) as outline `Symbol`s —
/// Markdown has no tree-sitter symbol query, so the structure outline falls back to
/// this. Headings inside fenced code blocks (``` / ~~~) are skipped so a `#` comment
/// in a code sample isn't mistaken for a heading.
///
/// Each heading gets a `scopeRange` spanning from its own line to the next heading of
/// the *same or higher* level, so the shared containment tree-builder nests a document
/// by heading level (H2 under H1, H3 under H2) exactly like it nests code by braces.
public enum MarkdownOutline {

    public static func headings(in text: String) -> [Symbol] {
        struct H { let level: Int; let name: String; let location: Int; let length: Int; let line: Int }
        var raw: [H] = []
        var inFence = false
        var lineNo = 0
        var charOffset = 0   // UTF-16 offset of the current line's start

        for rawLine in text.components(separatedBy: "\n") {
            lineNo += 1
            let lineLen = (rawLine as NSString).length
            defer { charOffset += lineLen + 1 }   // +1 for the separating newline

            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { inFence.toggle(); continue }
            guard !inFence, trimmed.hasPrefix("#") else { continue }

            let hashes = trimmed.prefix(while: { $0 == "#" }).count
            guard hashes <= 6 else { continue }
            let after = trimmed.dropFirst(hashes)
            guard after.isEmpty || after.first == " " else { continue }   // ATX requires a space after the #s

            let title = after.trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "# "))
            guard !title.isEmpty else { continue }
            raw.append(H(level: hashes, name: title, location: charOffset, length: lineLen, line: lineNo))
        }

        let docEnd = (text as NSString).length
        return raw.enumerated().map { i, h in
            // Scope runs to the next same-or-higher heading (or the document's end).
            let end = raw[(i + 1)...].first(where: { $0.level <= h.level })?.location ?? docEnd
            let scope = NSRange(location: h.location, length: max(h.length, end - h.location))
            return Symbol(name: h.name, kind: .heading,
                          range: NSRange(location: h.location, length: h.length),
                          line: h.line, scopeRange: scope)
        }
    }
}
