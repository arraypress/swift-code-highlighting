//
//  CustomLanguageDefinition.swift
//  SwiftCodeHighlighting
//
//  A user-authored, JSON-decodable description of a niche language, compiled
//  into the regex highlighter's rule tables — so an app can support languages
//  the package has never heard of (JSFX, some in-house DSL, …) from a single
//  hand-written JSON file.
//
//  Created by David Sherlock on 7/16/26.
//

import Foundation

/// A user-authored description of a language the package doesn't know about,
/// decodable from a hand-written JSON file and consumable by
/// ``SyntaxHighlighter/init(custom:colors:)``.
///
/// Structured fields (`keywords`, `stringDelimiters`, `lineComment`, …) are
/// compiled into the same battle-tested regex forms the built-in language
/// tables use; ``patterns`` is the raw-regex escape hatch for anything the
/// structured fields can't express. Only `name` and `extensions` are required.
///
/// Rule precedence mirrors the built-in tables: raw ``patterns`` are applied
/// first (in array order — a later pattern repaints an earlier one where they
/// overlap), then `keywords`/`types`/`constants`, then the number and
/// function-call rules. Comments and strings — whether from the structured
/// fields or from `comment`/`string`-kind patterns — always win over code
/// rules and are resolved together in one left-to-right scan, so a `//`
/// inside a string literal can't repaint the line and vice versa.
///
/// Decode with ``decode(from:)`` for readable error messages, or plain
/// `JSONDecoder` if you don't need them. A pattern whose regex fails to
/// compile is skipped at highlighter-build time, never fatal; a pattern with
/// an unknown `kind` is a **decode-time error** (the JSON is hand-authored, so
/// a typo like `"keyowrd"` should fail loudly, not silently drop the rule).
public struct CustomLanguageDefinition: Codable, Equatable, Sendable {

    /// Display name of the language (e.g. `"JSFX"`). Required, non-empty.
    public var name: String

    /// File extensions this language claims, without leading dots
    /// (e.g. `["jsfx"]`). Required, non-empty. Matching files to definitions
    /// is the host app's job; the package only carries the data.
    public var extensions: [String]

    /// Exact filenames (no path) this language also claims
    /// (e.g. `["Jenkinsfile"]`), for extension-less files.
    public var filenames: [String]?

    /// Line-comment marker (e.g. `"//"` or `"#"`): everything from the marker
    /// to the end of the line is a comment. Escaped literally — not a regex.
    public var lineComment: String?

    /// Block-comment opener (e.g. `"/*"`). Only used when
    /// ``blockCommentEnd`` is also set. Escaped literally — not a regex.
    public var blockCommentStart: String?

    /// Block-comment closer (e.g. `"*/"`). Only used when
    /// ``blockCommentStart`` is also set. Escaped literally — not a regex.
    public var blockCommentEnd: String?

    /// String-literal delimiters (e.g. `["\""]` or `["\"", "'"]`). Each
    /// builds the standard escaped-string regex — the span runs from one
    /// delimiter to the next, with backslash-escapes (`\"`, `\\`) skipped.
    public var stringDelimiters: [String]?

    /// Keyword words (`if`, `function`, …). Joined into one word-boundary
    /// alternation; each word is regex-escaped, so plain text is safe.
    public var keywords: [String]?

    /// Type-name words. Same alternation treatment as ``keywords``,
    /// painted with the `type` role.
    public var types: [String]?

    /// Built-in constant words (`true`, `srate`, …). Same alternation
    /// treatment; painted with the number-literal role, matching how the
    /// built-in tables color `true`/`false`/`nil`.
    public var constants: [String]?

    /// Highlight numeric literals (decimal and `0x…` hex) with the standard
    /// number regex. Defaults to `true` when omitted.
    public var numbers: Bool?

    /// Highlight identifiers directly before a `(` as function calls.
    /// Defaults to `true` when omitted.
    public var functionCalls: Bool?

    /// Raw-regex escape hatch, applied before the structured word lists.
    /// Later patterns repaint earlier ones where they overlap; patterns with
    /// `comment`/`string` kinds join the comment/string precedence scan.
    /// A pattern that fails to compile is skipped, never fatal.
    public var patterns: [CustomPattern]?

    /// When `true`, every built regex matches case-insensitively (word lists,
    /// comment/string markers, and raw patterns alike). Defaults to `false`.
    public var caseInsensitive: Bool?

    /// Memberwise initializer, mostly for building definitions in code
    /// (tests, programmatic registration). JSON authors never see this.
    public init(
        name: String,
        extensions: [String],
        filenames: [String]? = nil,
        lineComment: String? = nil,
        blockCommentStart: String? = nil,
        blockCommentEnd: String? = nil,
        stringDelimiters: [String]? = nil,
        keywords: [String]? = nil,
        types: [String]? = nil,
        constants: [String]? = nil,
        numbers: Bool? = nil,
        functionCalls: Bool? = nil,
        patterns: [CustomPattern]? = nil,
        caseInsensitive: Bool? = nil
    ) {
        self.name = name
        self.extensions = extensions
        self.filenames = filenames
        self.lineComment = lineComment
        self.blockCommentStart = blockCommentStart
        self.blockCommentEnd = blockCommentEnd
        self.stringDelimiters = stringDelimiters
        self.keywords = keywords
        self.types = types
        self.constants = constants
        self.numbers = numbers
        self.functionCalls = functionCalls
        self.patterns = patterns
        self.caseInsensitive = caseInsensitive
    }
}

/// One raw-regex rule inside a ``CustomLanguageDefinition`` — the escape hatch
/// for anything the structured fields can't express (section markers, header
/// directives, register names, exotic literals, …).
public struct CustomPattern: Codable, Equatable, Sendable {

    /// The ICU regular expression (as `NSRegularExpression` compiles it).
    /// `^`/`$` anchor per line. An invalid regex is skipped when the
    /// highlighter is built — it never fails the definition.
    public var pattern: String

    /// The token role the pattern paints, as a string:
    /// one of ``CustomPattern/validKinds``. An unknown kind fails
    /// ``CustomLanguageDefinition/decode(from:)`` with a clear error.
    public var kind: String

    /// Every accepted ``kind`` string, in documentation order.
    /// `"constant"` paints with the number-literal role, matching how the
    /// built-in tables color `true`/`false`/`nil`.
    public static let validKinds: [String] = [
        "comment", "string", "keyword", "type", "number",
        "function", "attribute", "property", "variable", "constant",
    ]

    /// Memberwise initializer for building patterns in code.
    public init(pattern: String, kind: String) {
        self.pattern = pattern
        self.kind = kind
    }

    /// The ``TokenKind`` this pattern's ``kind`` string names, or `nil` for an
    /// unknown string (which ``CustomLanguageDefinition/decode(from:)``
    /// rejects up front).
    var tokenKind: TokenKind? {
        switch kind {
        case "comment":   return .comment
        case "string":    return .string
        case "keyword":   return .keyword
        case "type":      return .type
        case "number":    return .number
        case "function":  return .function
        case "attribute": return .attribute
        case "property":  return .property
        case "variable":  return .variable
        case "constant":  return .number   // constants share the literal color, like the built-in tables
        default:          return nil
        }
    }
}

// MARK: - Decoding with readable errors

/// What went wrong decoding or validating a hand-authored
/// ``CustomLanguageDefinition``. Every case has a human-readable
/// `errorDescription` suitable for showing directly to the file's author.
public enum CustomLanguageDefinitionError: Error, Equatable, LocalizedError {

    /// The data isn't valid JSON at all (syntax error, wrong encoding, …).
    case invalidJSON(detail: String)

    /// A required field (`name` or `extensions`) is missing.
    case missingField(String)

    /// A field is present but has the wrong JSON type.
    case wrongType(field: String, expected: String)

    /// `name` is present but empty (or whitespace-only).
    case emptyName

    /// `extensions` is present but empty, or contains only empty strings.
    case emptyExtensions

    /// `patterns[index].kind` isn't one of ``CustomPattern/validKinds``.
    case unknownPatternKind(kind: String, index: Int)

    public var errorDescription: String? {
        switch self {
        case .invalidJSON(let detail):
            return "The file is not valid JSON: \(detail)"
        case .missingField(let field):
            return "Missing required field \"\(field)\"."
        case .wrongType(let field, let expected):
            return "Field \"\(field)\" has the wrong type — expected \(expected)."
        case .emptyName:
            return "\"name\" must not be empty."
        case .emptyExtensions:
            return "\"extensions\" must list at least one file extension (without the dot), e.g. [\"jsfx\"]."
        case .unknownPatternKind(let kind, let index):
            return "patterns[\(index)] has unknown kind \"\(kind)\". Valid kinds: "
                + CustomPattern.validKinds.joined(separator: ", ") + "."
        }
    }
}

public extension CustomLanguageDefinition {

    /// Decodes and validates a definition from raw JSON data, with error
    /// messages written for the human who authored the file (missing field
    /// names, the offending pattern index, the list of valid kinds) rather
    /// than `DecodingError`'s coding-path dumps.
    ///
    /// Validation enforced here, beyond what `Codable` checks:
    /// - `name` must be non-empty, `extensions` must list at least one entry;
    /// - every `patterns[i].kind` must be one of ``CustomPattern/validKinds``
    ///   (a typo fails the whole decode — this JSON is hand-written, so fail
    ///   loudly rather than silently dropping a rule).
    ///
    /// A pattern whose *regex* is invalid still decodes fine — it is skipped
    /// when the highlighter compiles its rules (never fatal), so one bad
    /// pattern can't take down the rest of the definition.
    static func decode(from data: Data) -> Result<CustomLanguageDefinition, Error> {
        let definition: CustomLanguageDefinition
        do {
            definition = try JSONDecoder().decode(CustomLanguageDefinition.self, from: data)
        } catch let error as DecodingError {
            return .failure(Self.friendlyError(from: error))
        } catch {
            return .failure(CustomLanguageDefinitionError.invalidJSON(detail: error.localizedDescription))
        }
        if let validationError = definition.validationError {
            return .failure(validationError)
        }
        return .success(definition)
    }

    /// The first validation problem in an already-decoded definition,
    /// or `nil` when it's fully valid. ``decode(from:)`` calls this;
    /// exposed so programmatically-built definitions can be checked too.
    var validationError: CustomLanguageDefinitionError? {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .emptyName
        }
        if extensions.allSatisfy({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            return .emptyExtensions
        }
        for (index, pattern) in (patterns ?? []).enumerated() where pattern.tokenKind == nil {
            return .unknownPatternKind(kind: pattern.kind, index: index)
        }
        return nil
    }

    /// Rewrites a `DecodingError` into a ``CustomLanguageDefinitionError``
    /// a JSON author can act on.
    private static func friendlyError(from error: DecodingError) -> CustomLanguageDefinitionError {
        switch error {
        case .keyNotFound(let key, _):
            return .missingField(key.stringValue)
        case .typeMismatch(let type, let context):
            return .wrongType(field: Self.fieldPath(context.codingPath), expected: Self.typeName(type))
        case .valueNotFound(let type, let context):
            return .wrongType(field: Self.fieldPath(context.codingPath), expected: Self.typeName(type))
        case .dataCorrupted(let context):
            let underlying = (context.underlyingError as NSError?)?.userInfo[NSDebugDescriptionErrorKey] as? String
            return .invalidJSON(detail: underlying ?? context.debugDescription)
        @unknown default:
            return .invalidJSON(detail: String(describing: error))
        }
    }

    /// Renders a coding path as a readable field path (`patterns[2].kind`).
    private static func fieldPath(_ path: [CodingKey]) -> String {
        var result = ""
        for key in path {
            if let index = key.intValue {
                result += "[\(index)]"
            } else {
                result += result.isEmpty ? key.stringValue : ".\(key.stringValue)"
            }
        }
        return result.isEmpty ? "(top level)" : result
    }

    /// A JSON-author-friendly name for a Swift type a decoder expected.
    private static func typeName(_ type: Any.Type) -> String {
        switch type {
        case is String.Type: return "a string"
        case is Bool.Type: return "true or false"
        case is [String].Type: return "an array of strings"
        case is [CustomPattern].Type, is CustomPattern.Type: return "an array of {pattern, kind} objects"
        case is Double.Type, is Int.Type: return "a number"
        default: return "\(type)"
        }
    }
}

// MARK: - Compiling the definition into highlighter rules

extension CustomLanguageDefinition {

    /// The `NSRegularExpression` options every built rule compiles with:
    /// per-line anchoring (like the built-in tables), plus case-insensitivity
    /// when ``caseInsensitive`` is `true`.
    var regexOptions: NSRegularExpression.Options {
        var options: NSRegularExpression.Options = [.anchorsMatchLines]
        if caseInsensitive == true { options.insert(.caseInsensitive) }
        return options
    }

    /// Compiles the definition into the same `(pattern, kind)` table shape
    /// `SyntaxHighlighter.buildDefs(for:)` produces for built-in languages,
    /// so the highlighter's existing group-routing and precedence merge apply
    /// unchanged. Order: comments/strings (group-routed, order-independent),
    /// raw patterns (most specific), keywords/types/constants, then the
    /// number and function-call rules.
    func ruleDefinitions() -> [(String, TokenKind)] {
        var defs: [(String, TokenKind)] = []

        // Comments and strings: routed into the comment/string groups by the
        // highlighter, where the left-to-right scan resolves their precedence.
        if let marker = lineComment, !marker.isEmpty {
            defs.append((NSRegularExpression.escapedPattern(for: marker) + ".*$", .comment))
        }
        if let start = blockCommentStart, let end = blockCommentEnd, !start.isEmpty, !end.isEmpty {
            defs.append((NSRegularExpression.escapedPattern(for: start)
                + "[\\s\\S]*?"
                + NSRegularExpression.escapedPattern(for: end), .comment))
        }
        for delimiter in stringDelimiters ?? [] where !delimiter.isEmpty {
            defs.append((Self.stringPattern(delimiter: delimiter), .string))
        }

        // Raw patterns first — the most specific rules. Later array entries
        // repaint earlier ones where they overlap (comment/string kinds are
        // group-routed instead, like the structured fields above).
        for custom in patterns ?? [] {
            if let kind = custom.tokenKind {
                defs.append((custom.pattern, kind))
            }
        }

        // Word lists.
        if let words = keywords, !words.isEmpty { defs.append((Self.wordAlternation(words), .keyword)) }
        if let words = types, !words.isEmpty { defs.append((Self.wordAlternation(words), .type)) }
        if let words = constants, !words.isEmpty { defs.append((Self.wordAlternation(words), .number)) }

        // Standard literals, on by default.
        if numbers ?? true {
            defs.append(("\\b0x[0-9a-fA-F]+\\b|\\b\\d+(?:\\.\\d+)?\\b", .number))
        }
        if functionCalls ?? true {
            defs.append(("\\b([A-Za-z_]\\w*)\\s*\\(", .function))
        }
        return defs
    }

    /// The standard escaped-string regex for one delimiter: for a single-char
    /// delimiter `"` this is the classic `"(?:[^"\\]|\\.)*"` (backslash
    /// escapes skipped, no spill past the closer); multi-char delimiters
    /// (`"""`, `<<<`) get a non-greedy span with the same escape handling.
    static func stringPattern(delimiter: String) -> String {
        let escaped = NSRegularExpression.escapedPattern(for: delimiter)
        guard delimiter.count == 1, let scalar = delimiter.unicodeScalars.first else {
            return escaped + "(?:\\\\.|[^\\\\])*?" + escaped
        }
        // Escape the delimiter for use inside a character class as well.
        let needsClassEscape = "\\]^-[&".unicodeScalars.contains(scalar)
        let classEscaped = needsClassEscape ? "\\\(delimiter)" : delimiter
        return escaped + "(?:[^" + classEscaped + "\\\\]|\\\\.)*" + escaped
    }

    /// Joins a word list into a single word-boundary alternation
    /// (`\b(?:for|while|loop)\b`), regex-escaping every word.
    static func wordAlternation(_ words: [String]) -> String {
        "\\b(?:" + words.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|") + ")\\b"
    }
}

// MARK: - SyntaxHighlighter entry point

public extension SyntaxHighlighter {

    /// Builds a regex highlighter from a user-authored custom language
    /// definition — the same rule-table machinery the built-in languages use,
    /// fed from JSON instead of code.
    ///
    /// Comments and strings (from the structured fields *and* from
    /// `comment`/`string`-kind patterns) join the existing precedence merge,
    /// so a comment marker inside a string literal can't repaint the line and
    /// vice versa. Patterns whose regexes fail to compile are skipped, never
    /// fatal. When ``CustomLanguageDefinition/caseInsensitive`` is `true`,
    /// every rule matches case-insensitively.
    ///
    /// ```swift
    /// let definition = try CustomLanguageDefinition.decode(from: jsonData).get()
    /// let highlighter = SyntaxHighlighter(custom: definition, colors: myColors)
    /// highlighter.highlight(storage, in: fullRange)
    /// ```
    convenience init(custom: CustomLanguageDefinition, colors: TokenColorProviding) {
        self.init(defs: custom.ruleDefinitions(), regexOptions: custom.regexOptions, colors: colors)
    }
}
