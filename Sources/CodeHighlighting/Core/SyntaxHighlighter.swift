//
//  SyntaxHighlighter.swift
//  SwiftCodeHighlighting
//
//  Dependency-light regex syntax highlighter with per-language rules and a
//  family-based fallback, covering every language CodeLanguage recognizes.
//
//  Created by David Sherlock on 7/9/26.
//

import AppKit
import CodeLanguage

public final class SyntaxHighlighter: CodeHighlighter {
    private typealias Rule = (regex: NSRegularExpression, kind: TokenKind)

    // Rules are grouped so precedence is correct regardless of authoring order:
    // code first, then strings, then comments — so comments win over everything
    // and strings win over code (a keyword inside a string/comment stays quiet).
    private let codeRules: [Rule]
    private let stringRules: [Rule]
    private let commentRules: [Rule]
    private let colors: TokenColorProviding

    public init(language: Language, colors: TokenColorProviding) {
        self.colors = colors
        var code: [Rule] = []
        var strings: [Rule] = []
        var comments: [Rule] = []
        for (pattern, kind) in Self.buildDefs(for: language) {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .anchorsMatchLines) else { continue }
            switch kind {
            case .comment: comments.append((regex, kind))
            case .string:  strings.append((regex, kind))
            default:       code.append((regex, kind))
            }
        }
        codeRules = code
        stringRules = strings
        commentRules = comments
    }

    public func highlight(_ storage: NSTextStorage, in editedRange: NSRange) {
        let string = storage.string as NSString
        guard string.length > 0 else { return }

        let start = string.lineRange(for: NSRange(location: editedRange.location, length: 0)).location
        let end: Int = {
            let e = NSMaxRange(editedRange)
            let clamped = min(e, string.length)
            return NSMaxRange(string.lineRange(for: NSRange(location: max(clamped - 1, 0), length: 0)))
        }()
        let range = NSRange(location: start, length: end - start)
        guard range.length > 0 else { return }

        // Only reset the color — NOT the font. Changing .font invalidates the
        // layout manager's glyphs on every keystroke/scroll, which races with the
        // gutter's glyph queries and can crash. The font is already set once when
        // the storage is built (and rebuilt on font-size change), so leave it alone.
        storage.addAttribute(.foregroundColor, value: colors.foreground, range: range)

        let text = storage.string
        apply(codeRules, to: storage, in: text, range: range)
        apply(stringRules, to: storage, in: text, range: range)
        apply(commentRules, to: storage, in: text, range: range)
    }

    private func apply(_ rules: [Rule], to storage: NSTextStorage, in text: String, range: NSRange) {
        for rule in rules {
            let color = colors.color(for: rule.kind)
            rule.regex.enumerateMatches(in: text, options: [], range: range) { match, _, _ in
                guard let r = match?.range else { return }
                storage.addAttribute(.foregroundColor, value: color, range: r)
            }
        }
    }

    // MARK: - Rule tables

    private static func buildDefs(for lang: Language) -> [(String, TokenKind)] {
        switch lang {
        case .swift:
            return [
                ("//.*$", .comment),
                ("/\\*[\\s\\S]*?\\*/", .comment),
                ("\"(?:[^\"\\\\]|\\\\.)*\"", .string),
                ("\\b(import|class|struct|enum|protocol|extension|func|var|let|if|else|guard|switch|case|default|for|while|repeat|return|break|continue|throw|throws|try|catch|do|in|as|is|self|Self|super|init|deinit|static|override|private|public|internal|fileprivate|open|final|lazy|weak|unowned|mutating|async|await|actor|some|any|where|typealias|defer|indirect)\\b", .keyword),
                ("\\b(String|Int|Double|Float|Bool|Array|Dictionary|Set|Optional|Result|Error|Void|Any|AnyObject|Never|Data|Date|URL|UUID)\\b", .type),
                ("\\b(true|false|nil)\\b", .number),
                ("\\b\\d+(\\.\\d+)?\\b|\\b0x[0-9a-fA-F]+\\b", .number),
                ("\\b([a-zA-Z_]\\w*)\\s*\\(", .function),
                ("@\\w+", .attribute),
            ]
        case .python:
            return [
                ("\"\"\"[\\s\\S]*?\"\"\"", .string),
                ("'''[\\s\\S]*?'''", .string),
                ("#.*$", .comment),
                ("\"(?:[^\"\\\\]|\\\\.)*\"", .string),
                ("'(?:[^'\\\\]|\\\\.)*'", .string),
                ("\\b(import|from|class|def|return|if|elif|else|for|while|break|continue|pass|raise|try|except|finally|with|as|yield|lambda|global|nonlocal|assert|del|in|not|and|or|is|async|await|match|case)\\b", .keyword),
                ("\\b(True|False|None)\\b", .number),
                ("\\b(int|float|str|bool|list|dict|set|tuple|range|print|len|super|type|object)\\b", .type),
                ("\\b\\d+(\\.\\d+)?\\b", .number),
                ("\\b([a-zA-Z_]\\w*)\\s*\\(", .function),
                ("@\\w[\\w.]*", .attribute),
            ]
        case .javascript, .typescript:
            return [
                ("//.*$", .comment),
                ("/\\*[\\s\\S]*?\\*/", .comment),
                ("`(?:[^`\\\\]|\\\\.)*`", .string),
                ("\"(?:[^\"\\\\]|\\\\.)*\"", .string),
                ("'(?:[^'\\\\]|\\\\.)*'", .string),
                ("\\b(import|export|from|default|const|let|var|function|return|if|else|for|while|do|break|continue|switch|case|throw|try|catch|finally|new|delete|typeof|instanceof|in|of|class|extends|super|this|yield|async|await|static|get|set|interface|type|enum|implements|readonly|public|private|protected|namespace|declare|as|satisfies|keyof)\\b", .keyword),
                ("\\b(true|false|null|undefined|NaN|Infinity)\\b", .number),
                ("\\b(Array|Object|String|Number|Boolean|Function|Promise|Map|Set|RegExp|Date|Error|JSON|Math|console)\\b", .type),
                ("\\b\\d+(\\.\\d+)?\\b|\\b0x[0-9a-fA-F]+\\b", .number),
                ("\\b([a-zA-Z_$][\\w$]*)\\s*\\(", .function),
                ("=>", .keyword),
            ]
        case .astro:
            return [
                ("<!--[\\s\\S]*?-->", .comment),
                ("//.*$", .comment),
                ("/\\*[\\s\\S]*?\\*/", .comment),
                ("`(?:[^`\\\\]|\\\\.)*`", .string),
                ("\"(?:[^\"\\\\]|\\\\.)*\"", .string),
                ("'(?:[^'\\\\]|\\\\.)*'", .string),
                ("^---\\s*$", .keyword),
                ("</?[A-Z][\\w.]*", .type),
                ("</?[a-z][\\w-]*", .keyword),
                ("/>|>", .keyword),
                ("\\b(import|export|from|const|let|var|function|return|if|else|for|while|await|async|new|class|interface|type|typeof|extends|of|in)\\b", .keyword),
                ("\\b\\d+(\\.\\d+)?\\b", .number),
                ("\\b[a-zA-Z_:][\\w:-]*=", .function),
            ]
        case .html:
            return [
                ("<!--[\\s\\S]*?-->", .comment),
                ("\"[^\"]*\"", .string),
                ("'[^']*'", .string),
                ("</?[a-zA-Z][\\w-]*", .keyword),
                ("/>|>", .keyword),
                ("\\b[a-zA-Z-]+=", .function),
            ]
        case .css:
            return [
                ("/\\*[\\s\\S]*?\\*/", .comment),
                ("\"(?:[^\"\\\\]|\\\\.)*\"", .string),
                ("'(?:[^'\\\\]|\\\\.)*'", .string),
                ("#[0-9a-fA-F]{3,8}\\b", .number),
                ("\\b\\d+(\\.\\d+)?(px|em|rem|%|vh|vw|s|ms|fr|deg)?\\b", .number),
                ("[.#][a-zA-Z_-][\\w-]*", .function),
                ("@(media|import|keyframes|font-face|supports|include|mixin|use|forward)\\b", .keyword),
                ("[a-z-]+(?=\\s*:)", .type),
            ]
        case .json:
            return [
                ("\"(?:[^\"\\\\]|\\\\.)*\"\\s*:", .function),
                ("\"(?:[^\"\\\\]|\\\\.)*\"", .string),
                ("\\b(true|false|null)\\b", .keyword),
                ("\\b-?\\d+(\\.\\d+)?([eE][+-]?\\d+)?\\b", .number),
            ]
        case .rust:
            return [
                ("//.*$", .comment),
                ("/\\*[\\s\\S]*?\\*/", .comment),
                ("\"(?:[^\"\\\\]|\\\\.)*\"", .string),
                ("\\b(fn|let|mut|const|static|struct|enum|impl|trait|type|use|mod|pub|crate|super|self|Self|where|as|in|for|while|loop|if|else|match|return|break|continue|move|ref|async|await|dyn|unsafe|extern)\\b", .keyword),
                ("\\b(true|false)\\b", .number),
                ("\\b(i8|i16|i32|i64|i128|isize|u8|u16|u32|u64|u128|usize|f32|f64|bool|char|str|String|Vec|Option|Result|Box|Rc|Arc|HashMap)\\b", .type),
                ("\\b\\d+(\\.\\d+)?\\b|\\b0x[0-9a-fA-F]+\\b", .number),
                ("\\b([a-zA-Z_]\\w*)\\s*[!(]", .function),
                ("#\\[[^\\]]*\\]", .attribute),
                ("'[a-z_]\\w*\\b", .attribute),
            ]
        case .go:
            return [
                ("//.*$", .comment),
                ("/\\*[\\s\\S]*?\\*/", .comment),
                ("`[^`]*`", .string),
                ("\"(?:[^\"\\\\]|\\\\.)*\"", .string),
                ("\\b(package|import|func|return|var|const|type|struct|interface|map|chan|go|defer|if|else|for|range|switch|case|default|break|continue|fallthrough|select|nil)\\b", .keyword),
                ("\\b(true|false|iota)\\b", .number),
                ("\\b(int|int8|int16|int32|int64|uint|uint8|uint16|uint32|uint64|float32|float64|byte|rune|string|bool|error|any)\\b", .type),
                ("\\b\\d+(\\.\\d+)?\\b", .number),
                ("\\b([a-zA-Z_]\\w*)\\s*\\(", .function),
            ]
        case .kotlin:
            return [
                ("//.*$", .comment),
                ("/\\*[\\s\\S]*?\\*/", .comment),
                ("\"\"\"[\\s\\S]*?\"\"\"", .string),
                ("\"(?:[^\"\\\\]|\\\\.)*\"", .string),
                ("'(?:[^'\\\\]|\\\\.)*'", .string),
                ("\\b(fun|val|var|class|object|interface|data|sealed|enum|import|package|return|if|else|when|for|while|do|in|is|as|null|this|super|override|open|abstract|private|public|internal|protected|companion|init|constructor|by|lateinit|suspend|typealias|vararg|inline|reified|operator|infix|out)\\b", .keyword),
                ("\\b(true|false|null)\\b", .number),
                ("\\b(Int|Long|Double|Float|Boolean|String|Char|Byte|Short|Unit|Any|Nothing|List|Map|Set|Array|MutableList|MutableMap|Pair)\\b", .type),
                ("\\b\\d+(\\.\\d+)?[fFlLdD]?\\b", .number),
                ("\\b([a-zA-Z_]\\w*)\\s*\\(", .function),
                ("@\\w+", .attribute),
            ]
        case .php:
            return [
                ("//.*$", .comment),
                ("#.*$", .comment),
                ("/\\*[\\s\\S]*?\\*/", .comment),
                ("\"(?:[^\"\\\\]|\\\\.)*\"", .string),
                ("'(?:[^'\\\\]|\\\\.)*'", .string),
                ("<\\?php|\\?>", .keyword),
                ("\\b(function|class|interface|trait|extends|implements|public|private|protected|static|const|return|if|else|elseif|foreach|for|while|do|switch|case|break|continue|echo|print|new|use|namespace|require|require_once|include|include_once|try|catch|finally|throw|as|instanceof|abstract|final|global|isset|unset|empty|array|fn|match|yield)\\b", .keyword),
                ("\\b(true|false|null)\\b", .number),
                ("\\$[a-zA-Z_]\\w*", .type),
                ("\\b\\d+(\\.\\d+)?\\b", .number),
                ("\\b([a-zA-Z_]\\w*)\\s*\\(", .function),
            ]
        case .csharp:
            return [
                ("//.*$", .comment),
                ("/\\*[\\s\\S]*?\\*/", .comment),
                ("@?\"(?:[^\"\\\\]|\\\\.)*\"", .string),
                ("'(?:[^'\\\\]|\\\\.)*'", .string),
                ("\\b(using|namespace|class|struct|interface|enum|public|private|protected|internal|static|readonly|const|void|new|return|if|else|for|foreach|while|do|switch|case|default|break|continue|throw|try|catch|finally|async|await|get|set|this|base|override|virtual|abstract|sealed|partial|in|out|ref|params|is|as|typeof|nameof|record|when|where|yield|lock|using)\\b", .keyword),
                ("\\b(int|long|short|byte|bool|char|string|double|float|decimal|object|dynamic|var|List|Dictionary|IEnumerable|Task|Nullable)\\b", .type),
                ("\\b(true|false|null)\\b", .number),
                ("\\b\\d+(\\.\\d+)?[fFdDmMlL]?\\b", .number),
                ("\\b([a-zA-Z_]\\w*)\\s*\\(", .function),
                ("\\[[A-Za-z]\\w*(\\([^)]*\\))?\\]", .attribute),
            ]
        case .dart:
            return [
                ("///.*$", .comment),
                ("//.*$", .comment),
                ("/\\*[\\s\\S]*?\\*/", .comment),
                ("\"(?:[^\"\\\\]|\\\\.)*\"", .string),
                ("'(?:[^'\\\\]|\\\\.)*'", .string),
                ("\\b(abstract|class|const|final|var|void|dynamic|import|export|library|part|return|if|else|for|while|do|switch|case|default|break|continue|new|this|super|async|await|yield|try|catch|finally|throw|extends|implements|with|mixin|enum|typedef|get|set|factory|static|late|required|is|as|in|rethrow|on|show|hide)\\b", .keyword),
                ("\\b(int|double|num|bool|String|List|Map|Set|Future|Stream|Object|void|var|Widget|BuildContext)\\b", .type),
                ("\\b(true|false|null)\\b", .number),
                ("\\b\\d+(\\.\\d+)?\\b", .number),
                ("\\b([a-zA-Z_]\\w*)\\s*\\(", .function),
                ("@\\w+", .attribute),
            ]
        case .markdown:
            return [
                ("^>+\\s?.*$", .comment),
                ("^\\s*(\\*{3,}|-{3,}|_{3,})\\s*$", .comment),
                ("^\\s*[\\-\\*+]\\s", .keyword),
                ("^\\s*\\d+\\.\\s", .keyword),
                ("!?\\[([^\\]]+)\\]\\(([^)]+)\\)", .type),
                ("(?<!\\*)\\*(?![\\s*])[^*\\n]+?(?<![\\s*])\\*(?!\\*)", .type),
                ("(?<!\\w)_(?![\\s_])[^_\\n]+?(?<![\\s_])_(?!\\w)", .type),
                ("\\*\\*(?:[^*\\n]|\\*(?!\\*))+?\\*\\*", .function),
                ("__(?:[^_\\n]|_(?!_))+?__", .function),
                ("^#{1,6}\\s+.*$", .keyword),
                ("`[^`\\n]+`", .string),
                ("```[\\s\\S]*?```", .string),
            ]
        case .bash:
            return [
                ("#.*$", .comment),
                ("\"(?:[^\"\\\\]|\\\\.)*\"", .string),
                ("'[^']*'", .string),
                ("\\b(if|then|else|elif|fi|for|while|do|done|case|esac|in|function|return|exit|local|export|source|alias|read|set|unset|shift|trap)\\b", .keyword),
                ("\\$\\{?[a-zA-Z_]\\w*\\}?", .type),
                ("\\b\\d+(\\.\\d+)?\\b", .number),
                ("\\b(echo|cd|ls|pwd|mkdir|rm|cp|mv|cat|grep|sed|awk|find|sort|chmod|curl|wget|git)\\b", .function),
            ]
        case .dockerfile:
            return [
                ("#.*$", .comment),
                ("\"(?:[^\"\\\\]|\\\\.)*\"", .string),
                ("'[^']*'", .string),
                ("(?i)^\\s*(FROM|RUN|CMD|LABEL|EXPOSE|ENV|ADD|COPY|ENTRYPOINT|VOLUME|USER|WORKDIR|ARG|ONBUILD|STOPSIGNAL|HEALTHCHECK|SHELL|MAINTAINER)\\b", .keyword),
                ("\\$\\{?[a-zA-Z_]\\w*\\}?", .type),
                ("\\b\\d+\\b", .number),
            ]
        case .yaml:
            return [
                ("#.*$", .comment),
                ("\"(?:[^\"\\\\]|\\\\.)*\"", .string),
                ("'[^']*'", .string),
                ("^[a-zA-Z_][\\w.-]*:", .function),
                ("\\b(true|false|yes|no|null|~)\\b", .keyword),
                ("\\b\\d+(\\.\\d+)?\\b", .number),
            ]
        case .xml:
            return [
                ("<!--[\\s\\S]*?-->", .comment),
                ("\"[^\"]*\"", .string),
                ("'[^']*'", .string),
                ("</?[a-zA-Z][\\w:._-]*", .keyword),
                ("/>|>", .keyword),
            ]
        case .sql:
            return [
                ("--.*$", .comment),
                ("/\\*[\\s\\S]*?\\*/", .comment),
                ("'(?:[^']|'')*'", .string),   // SQLite: '' escapes a quote; backslash is literal
                ("\\b([a-zA-Z_]\\w*)\\(", .function),
                ("\\b\\d+(\\.\\d+)?\\b", .number),
                ("(?i)\\b(SELECT|FROM|WHERE|INSERT|INTO|VALUES|UPDATE|SET|DELETE|CREATE|TABLE|VIEW|INDEX|TRIGGER|DROP|ALTER|ADD|COLUMN|RENAME|PRIMARY|KEY|FOREIGN|REFERENCES|CONSTRAINT|UNIQUE|CHECK|DEFAULT|NOT|NULL|AUTOINCREMENT|WITHOUT|ROWID|ON|CASCADE|RESTRICT|NO|ACTION|AND|OR|IN|IS|AS|BETWEEN|LIKE|GLOB|MATCH|REGEXP|EXISTS|CASE|WHEN|THEN|ELSE|END|JOIN|LEFT|RIGHT|INNER|OUTER|CROSS|FULL|NATURAL|USING|GROUP|BY|ORDER|ASC|DESC|HAVING|LIMIT|OFFSET|DISTINCT|ALL|UNION|INTERSECT|EXCEPT|WITH|RECURSIVE|COLLATE|PRAGMA|BEGIN|COMMIT|ROLLBACK|TRANSACTION|SAVEPOINT|RELEASE|ATTACH|DETACH|EXPLAIN|ANALYZE|VACUUM|REINDEX|REPLACE|CONFLICT|ABORT|FAIL|IGNORE|TEMP|TEMPORARY|IF)\\b", .keyword),
                ("(?i)\\b(INTEGER|INT|INT2|INT8|SMALLINT|MEDIUMINT|BIGINT|TINYINT|UNSIGNED|TEXT|CLOB|VARCHAR|VARYING|CHARACTER|CHAR|NCHAR|NVARCHAR|BLOB|REAL|DOUBLE|PRECISION|FLOAT|NUMERIC|DECIMAL|BOOLEAN|BOOL|DATE|DATETIME|TIMESTAMP|TIME|SERIAL)\\b", .type),
                ("(?i)\\b(TRUE|FALSE|CURRENT_TIMESTAMP|CURRENT_DATE|CURRENT_TIME)\\b", .number),
            ]
        case .c, .cpp:
            return [
                ("//.*$", .comment),
                ("/\\*[\\s\\S]*?\\*/", .comment),
                ("\"(?:[^\"\\\\]|\\\\.)*\"", .string),
                ("'(?:[^'\\\\]|\\\\.)*'", .string),
                ("#\\s*(include|define|ifdef|ifndef|endif|if|else|elif|pragma)\\b.*$", .attribute),
                ("\\b(auto|break|case|char|const|continue|default|do|double|else|enum|extern|float|for|goto|if|int|long|register|return|short|signed|sizeof|static|struct|switch|typedef|union|unsigned|void|volatile|while|inline|class|namespace|template|typename|virtual|public|private|protected|override|new|delete|this|try|catch|throw|using|nullptr|constexpr|noexcept)\\b", .keyword),
                ("\\b(true|false|NULL|nullptr)\\b", .number),
                ("\\b(size_t|int8_t|int16_t|int32_t|int64_t|uint8_t|uint16_t|uint32_t|uint64_t|bool|string|vector|map|set)\\b", .type),
                ("\\b\\d+(\\.\\d+)?\\b|\\b0x[0-9a-fA-F]+\\b", .number),
                ("\\b([a-zA-Z_]\\w*)\\s*\\(", .function),
            ]
        case .java:
            return [
                ("//.*$", .comment),
                ("/\\*[\\s\\S]*?\\*/", .comment),
                ("\"(?:[^\"\\\\]|\\\\.)*\"", .string),
                ("\\b(abstract|break|case|catch|class|continue|default|do|else|enum|extends|final|finally|for|if|implements|import|instanceof|interface|new|package|private|protected|public|return|static|super|switch|this|throw|throws|try|volatile|while|var|yield)\\b", .keyword),
                ("\\b(true|false|null)\\b", .number),
                ("\\b(boolean|byte|char|double|float|int|long|short|void|String|Integer|Long|Double|Object|List|Map|Set|Optional)\\b", .type),
                ("\\b\\d+(\\.\\d+)?\\b", .number),
                ("\\b([a-zA-Z_]\\w*)\\s*\\(", .function),
                ("@[a-zA-Z_]\\w*", .attribute),
            ]
        case .ruby:
            return [
                ("#.*$", .comment),
                ("\"(?:[^\"\\\\]|\\\\.)*\"", .string),
                ("'(?:[^'\\\\]|\\\\.)*'", .string),
                ("\\b(alias|and|begin|break|case|class|def|do|else|elsif|end|ensure|false|for|if|in|module|next|nil|not|or|redo|rescue|retry|return|self|super|then|true|undef|unless|until|when|while|yield|require|include)\\b", .keyword),
                (":[a-zA-Z_]\\w*", .string),
                ("\\b\\d+(\\.\\d+)?\\b", .number),
                ("@{1,2}[a-zA-Z_]\\w*", .type),
            ]
        case .toml:
            return [
                ("#.*$", .comment),
                ("\"\"\"[\\s\\S]*?\"\"\"", .string),
                ("\"(?:[^\"\\\\]|\\\\.)*\"", .string),
                ("'[^']*'", .string),
                ("^\\s*\\[{1,2}[^\\]]*\\]{1,2}", .keyword),
                ("^\\s*[a-zA-Z_][\\w.-]*\\s*=", .function),
                ("\\b(true|false)\\b", .number),
                ("\\b\\d+(\\.\\d+)?\\b", .number),
            ]
        default:
            return familyDefs(for: lang.family)
        }
    }

    // MARK: - Family fallbacks

    /// Fallback highlighting for any language without a dedicated rule set above,
    /// chosen by its `CodeLanguage` family. Broad but serviceable — so that no
    /// recognized language ever renders as flat, uncolored text.
    private static func familyDefs(for family: HighlightFamily) -> [(String, TokenKind)] {
        switch family {
        case .cLike:
            return [
                ("//.*$", .comment),
                ("/\\*[\\s\\S]*?\\*/", .comment),
                ("\"(?:[^\"\\\\]|\\\\.)*\"", .string),
                ("'(?:[^'\\\\]|\\\\.)*'", .string),
                ("\\b(if|else|for|while|do|switch|case|default|break|continue|return|struct|enum|union|class|interface|trait|impl|public|private|protected|internal|static|final|const|let|var|val|func|fn|def|void|new|delete|try|catch|finally|throw|throws|import|export|package|namespace|using|module|use|extends|implements|override|virtual|abstract|async|await|yield|match|when|where|type|typedef|template|typename|operator|this|self|super)\\b", .keyword),
                ("\\b(true|false|null|nil|none|undefined)\\b", .number),
                ("\\b\\d+(\\.\\d+)?\\b|\\b0x[0-9a-fA-F]+\\b", .number),
                ("\\b([A-Za-z_]\\w*)\\s*\\(", .function),
            ]
        case .rubyLike:
            return [
                ("#.*$", .comment),
                ("\"(?:[^\"\\\\]|\\\\.)*\"", .string),
                ("'(?:[^'\\\\]|\\\\.)*'", .string),
                ("\\b(def|end|do|class|module|defmodule|if|elsif|else|unless|case|when|cond|then|while|until|for|begin|rescue|ensure|raise|return|yield|require|import|include|use|self|nil|true|false|and|or|not|fn|defn|let|match)\\b", .keyword),
                (":[A-Za-z_]\\w*", .string),
                ("@{1,2}[A-Za-z_]\\w*", .type),
                ("\\b\\d+(\\.\\d+)?\\b", .number),
            ]
        case .lispLike:
            return [
                (";.*$", .comment),
                ("\"(?:[^\"\\\\]|\\\\.)*\"", .string),
                ("\\b(def\\w*|let\\*?|lambda|fn|defn|defmacro|defmethod|if|cond|when|unless|case|do|loop|recur|quote|require|import|ns)\\b", .keyword),
                ("#?:[A-Za-z_][\\w-]*", .type),
                ("\\b\\d+(\\.\\d+)?\\b", .number),
            ]
        case .mlLike:
            return [
                ("--.*$", .comment),
                ("\\(\\*[\\s\\S]*?\\*\\)", .comment),
                ("\\{-[\\s\\S]*?-\\}", .comment),
                ("\"(?:[^\"\\\\]|\\\\.)*\"", .string),
                ("\\b(let|in|module|import|open|type|data|newtype|class|instance|where|match|with|case|of|if|then|else|do|fun|function|val|rec|and|begin|end|deriving|struct|functor|signature)\\b", .keyword),
                ("\\b[A-Z]\\w*\\b", .type),
                ("\\b\\d+(\\.\\d+)?\\b", .number),
            ]
        case .shellLike:
            return [
                ("#.*$", .comment),
                ("\"(?:[^\"\\\\]|\\\\.)*\"", .string),
                ("'[^']*'", .string),
                ("\\b(if|then|else|elif|fi|for|while|do|done|case|esac|in|function|return|exit|local|export|set|unset|source|alias|echo)\\b", .keyword),
                ("\\$\\{?[A-Za-z_]\\w*\\}?", .type),
                ("\\b\\d+\\b", .number),
            ]
        case .markup:
            return [
                ("<!--[\\s\\S]*?-->", .comment),
                ("\"[^\"]*\"", .string),
                ("'[^']*'", .string),
                ("</?[A-Za-z][\\w:-]*", .keyword),
                ("/>|>", .keyword),
                ("\\b[A-Za-z-]+=", .function),
            ]
        case .config:
            return [
                ("</?[A-Za-z][\\w-]*", .keyword),
                ("^\\s*\\[[^\\]]*\\]", .keyword),
                ("^\\s*[A-Za-z_][\\w.-]*", .function),
                ("\\$\\{?\\w+\\}?", .type),
                ("%\\{[^}]*\\}", .type),
                ("(?i)\\b(on|off|true|false|yes|no|none|null|enabled|disabled)\\b", .number),
                ("\\b\\d+(\\.\\d+)?\\b", .number),
                ("\"(?:[^\"\\\\]|\\\\.)*\"", .string),
                ("'[^']*'", .string),
                ("#.*$", .comment),
                ("(?:^|\\s);.*$", .comment),
            ]
        case .sql:
            return [
                ("--.*$", .comment),
                ("/\\*[\\s\\S]*?\\*/", .comment),
                ("'(?:[^']|'')*'", .string),
                ("(?i)\\b(select|from|where|insert|into|values|update|set|delete|create|table|view|index|drop|alter|add|join|left|right|inner|outer|full|cross|on|using|group|by|order|asc|desc|having|limit|offset|distinct|union|all|as|and|or|not|null|is|in|between|like|primary|key|foreign|references|default|unique|check|case|when|then|else|end|begin|commit|rollback)\\b", .keyword),
                ("\\b\\d+(\\.\\d+)?\\b", .number),
                ("\\b([A-Za-z_]\\w*)\\s*\\(", .function),
            ]
        case .tex:
            return [
                ("%.*$", .comment),
                ("\\\\[A-Za-z@]+", .keyword),
                ("\\{[^{}]*\\}", .type),
                ("\\$[^$]*\\$", .string),
            ]
        case .data:
            return [
                ("\"(?:[^\"\\\\]|\\\\.)*\"\\s*:", .function),
                ("\"(?:[^\"\\\\]|\\\\.)*\"", .string),
                ("\\b(true|false|null)\\b", .keyword),
                ("\\b-?\\d+(\\.\\d+)?([eE][+-]?\\d+)?\\b", .number),
            ]
        case .plain:
            return []
        }
    }
}
