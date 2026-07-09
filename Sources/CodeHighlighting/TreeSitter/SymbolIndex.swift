import Foundation
import CodeLanguage

/// A definition found in a source file (function, class, method, …).
public struct Symbol {
    public let name: String
    public let kind: SymbolKind
    public let range: NSRange   // the name identifier's range (for jump + scroll)
    public let line: Int        // 1-based line of the definition
}

public enum SymbolKind: String {
    case function, method, type, structure, enumeration, interface, module, property, constant, variable

    /// Maps a tree-sitter capture name (from the symbol queries below) to a kind.
    public init?(capture: String) {
        switch capture {
        case "function":  self = .function
        case "method":    self = .method
        case "class":     self = .type
        case "struct":    self = .structure
        case "enum":      self = .enumeration
        case "interface": self = .interface
        case "module":    self = .module
        case "property":  self = .property
        case "constant":  self = .constant
        case "type":      self = .type
        case "variable":  self = .variable
        default:          return nil
        }
    }

    /// SF Symbol shown beside the entry in the outline / picker.
    public var iconName: String {
        switch self {
        case .function, .method:   return "function"
        case .type:                return "cube"
        case .structure:           return "cube.fill"
        case .enumeration:         return "list.number"
        case .interface:           return "square.on.square"
        case .module:              return "shippingbox"
        case .property, .variable: return "diamond"
        case .constant:            return "c.circle"
        }
    }

    /// Short label shown after the symbol name.
    public var label: String {
        switch self {
        case .type:        return "class"
        case .structure:   return "struct"
        case .enumeration: return "enum"
        default:           return rawValue
        }
    }
}

/// Hand-written definition queries per language (tree-sitter grammars we vendor
/// don't ship `tags.scm`). A query that fails to compile for a grammar just
/// yields no symbols for that language — graceful. Capture names map to
/// `SymbolKind` via `SymbolKind(capture:)`.
public enum SymbolQueries {
    public static let sources: [Language: String] = [
        .javascript: js,
        .typescript: ts,
        .python: py,
        .php: php,
        .go: go,
        .rust: rust,
        .java: java,
        .ruby: ruby,
        .c: c,
        .cpp: cpp,
        .csharp: csharp,
        .lua: lua,
    ]

    private static let js = """
    (function_declaration name: (identifier) @function)
    (generator_function_declaration name: (identifier) @function)
    (class_declaration name: (identifier) @class)
    (method_definition name: (property_identifier) @method)
    (variable_declarator name: (identifier) @function value: (arrow_function))
    (variable_declarator name: (identifier) @function value: (function_expression))
    """

    private static let ts = """
    (function_declaration name: (identifier) @function)
    (class_declaration name: (type_identifier) @class)
    (method_definition name: (property_identifier) @method)
    (interface_declaration name: (type_identifier) @interface)
    (type_alias_declaration name: (type_identifier) @type)
    (enum_declaration name: (identifier) @enum)
    (variable_declarator name: (identifier) @function value: (arrow_function))
    (abstract_method_signature name: (property_identifier) @method)
    (public_field_definition name: (property_identifier) @property)
    """

    private static let py = """
    (function_definition name: (identifier) @function)
    (class_definition name: (identifier) @class)
    """

    private static let php = """
    (function_definition name: (name) @function)
    (method_declaration name: (name) @method)
    (class_declaration name: (name) @class)
    (interface_declaration name: (name) @interface)
    (trait_declaration name: (name) @class)
    (enum_declaration name: (name) @enum)
    """

    private static let go = """
    (function_declaration name: (identifier) @function)
    (method_declaration name: (field_identifier) @method)
    (type_declaration (type_spec name: (type_identifier) @type))
    """

    private static let rust = """
    (function_item name: (identifier) @function)
    (struct_item name: (type_identifier) @struct)
    (enum_item name: (type_identifier) @enum)
    (trait_item name: (type_identifier) @interface)
    (mod_item name: (identifier) @module)
    (const_item name: (identifier) @constant)
    (impl_item type: (type_identifier) @class)
    """

    private static let java = """
    (class_declaration name: (identifier) @class)
    (interface_declaration name: (identifier) @interface)
    (method_declaration name: (identifier) @method)
    (constructor_declaration name: (identifier) @method)
    (enum_declaration name: (identifier) @enum)
    """

    private static let ruby = """
    (method name: (identifier) @method)
    (singleton_method name: (identifier) @method)
    (class name: (constant) @class)
    (module name: (constant) @module)
    """

    private static let c = """
    (function_definition declarator: (function_declarator declarator: (identifier) @function))
    (struct_specifier name: (type_identifier) @struct)
    (enum_specifier name: (type_identifier) @enum)
    """

    private static let cpp = """
    (function_definition declarator: (function_declarator declarator: (identifier) @function))
    (function_definition declarator: (function_declarator declarator: (field_identifier) @method))
    (class_specifier name: (type_identifier) @class)
    (struct_specifier name: (type_identifier) @struct)
    (enum_specifier name: (type_identifier) @enum)
    (namespace_definition name: (namespace_identifier) @module)
    """

    private static let csharp = """
    (class_declaration name: (identifier) @class)
    (interface_declaration name: (identifier) @interface)
    (struct_declaration name: (identifier) @struct)
    (method_declaration name: (identifier) @method)
    (constructor_declaration name: (identifier) @method)
    (enum_declaration name: (identifier) @enum)
    (property_declaration name: (identifier) @property)
    """

    private static let lua = """
    (function_declaration name: (identifier) @function)
    """
}
