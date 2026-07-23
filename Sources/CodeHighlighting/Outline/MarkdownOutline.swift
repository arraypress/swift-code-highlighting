import Foundation

/// Extracts a Markdown document's ATX headings (`#`…`######`) as outline `Symbol`s —
/// Markdown has no tree-sitter symbol query, so the structure outline falls back to
/// this. Headings inside fenced code blocks (``` / ~~~) are skipped so a `#` comment
/// in a code sample isn't mistaken for a heading, and CommonMark's 3-space cap on
/// ATX indentation is enforced so a `#` line in an indented (4-space) code block
/// isn't either.
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

        // One contiguous UTF-16 walk: this runs on every debounced outline
        // refresh, and `components(separatedBy:)` materialized every line of
        // the document as a String (~50k allocations plus a full copy at the
        // 2 MB cap) just to find the handful of heading lines. Offsets fall
        // out of the walk natively — they're the same UTF-16 units
        // `Symbol.range` wants.
        let ns = text as NSString
        let docEnd = ns.length
        var buf = [unichar](repeating: 0, count: docEnd)
        if docEnd > 0 { ns.getCharacters(&buf, range: NSRange(location: 0, length: docEnd)) }

        /// `CharacterSet.whitespaces` membership with an ASCII fast path
        /// (space/tab dominate; the set is only consulted for non-ASCII).
        func isWS(_ c: unichar) -> Bool {
            if c == 0x20 || c == 0x09 { return true }
            if c < 0x80 { return false }
            guard let s = Unicode.Scalar(c) else { return false }
            return CharacterSet.whitespaces.contains(s)
        }

        var lineStart = 0
        while lineStart <= docEnd {
            var lineEnd = lineStart
            while lineEnd < docEnd, buf[lineEnd] != 0x0A { lineEnd += 1 }
            lineNo += 1
            let lineLen = lineEnd - lineStart
            defer { lineStart = lineEnd + 1 }

            // The line's content excludes a CRLF file's trailing \r — it's not
            // in `.whitespaces`, so trimming alone would leave it on every name.
            var contentEnd = lineEnd
            if contentEnd > lineStart, buf[contentEnd - 1] == 0x0D { contentEnd -= 1 }

            var i = lineStart
            var indent = 0          // leading whitespace characters
            var indentSpacesOnly = true
            while i < contentEnd, isWS(buf[i]) {
                if buf[i] != 0x20 { indentSpacesOnly = false }
                indent += 1
                i += 1
            }
            if contentEnd - i >= 3, buf[i] == buf[i + 1], buf[i] == buf[i + 2],
               buf[i] == 0x60 /* ` */ || buf[i] == 0x7E /* ~ */ {
                inFence.toggle(); continue
            }
            guard !inFence, i < contentEnd, buf[i] == 0x23 /* # */ else { continue }
            // CommonMark caps ATX indentation at 3 spaces — 4+ (or a tab) is an
            // indented code block, whose `#` comments are not headings.
            guard indent <= 3, indentSpacesOnly else { continue }

            var hashes = 0
            while i < contentEnd, buf[i] == 0x23 { hashes += 1; i += 1 }
            guard hashes <= 6 else { continue }
            guard i == contentEnd || buf[i] == 0x20 else { continue }   // ATX requires a space after the #s

            let title = ns.substring(with: NSRange(location: i, length: contentEnd - i))
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "# "))
            guard !title.isEmpty else { continue }
            raw.append(H(level: hashes, name: title, location: lineStart, length: lineLen, line: lineNo))
        }

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
