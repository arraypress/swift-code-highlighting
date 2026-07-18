import Foundation

/// A node in the outline tree: a symbol plus its nested children.
public final class OutlineNode {
    public let symbol: Symbol
    public var children: [OutlineNode] = []
    public init(_ symbol: Symbol) { self.symbol = symbol }
}

/// Folds a flat, document-ordered `Symbol` list into a tree by *containment*: a symbol
/// whose name range falls inside another's `scopeRange` becomes its child — methods
/// under their type, subheadings under their heading. Symbols with no scope are leaves.
public enum OutlineTree {
    public static func build(from symbols: [Symbol]) -> [OutlineNode] {
        var roots: [OutlineNode] = []
        var stack: [OutlineNode] = []   // currently-open scopes, innermost last
        for sym in symbols {
            let node = OutlineNode(sym)
            while let top = stack.last, !contains(top.symbol.scopeRange, sym.range) {
                stack.removeLast()
            }
            if let parent = stack.last { parent.children.append(node) } else { roots.append(node) }
            if sym.scopeRange != nil { stack.append(node) }   // can hold children
        }
        return roots
    }

    /// Total nodes in the forest (the header's symbol count).
    public static func count(_ nodes: [OutlineNode]) -> Int {
        nodes.reduce(0) { $0 + 1 + count($1.children) }
    }

    private static func contains(_ scope: NSRange?, _ r: NSRange) -> Bool {
        guard let scope else { return false }
        return r.location >= scope.location && NSMaxRange(r) <= NSMaxRange(scope)
    }
}
