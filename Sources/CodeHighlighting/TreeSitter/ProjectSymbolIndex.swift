import Foundation
import CodeLanguage

/// A definition found somewhere in the project.
public struct DefLocation {
    public let url: URL
    public let name: String
    public let kind: SymbolKind
    public let range: NSRange   // name range within that file
    public let line: Int
}

/// Parses every source file in the project and maps symbol names to their
/// definitions, for cross-file Go-to-Definition and hover-doc. Built on a
/// background queue; updated incrementally per-file as things change on disk.
public final class ProjectSymbolIndex {
    private var defs: [String: [DefLocation]] = [:]
    private var fileNames: [String: Set<String>] = [:]   // file path → the names it defines
    public private(set) var isBuilt = false
    private var building = false
    private let queue = DispatchQueue(label: "sidewatch.symbolindex", qos: .userInitiated)

    public init() {}

    private static let skipDirs: Set<String> = [
        ".git", ".svn", ".hg", "node_modules", ".build", ".swiftpm", "Pods",
        "DerivedData", "dist", "build", "__pycache__", ".next", ".cache", "vendor",
    ]

    /// (Re)builds the whole index from `root`. `completion` runs on the main queue.
    public func build(root: URL, completion: (() -> Void)? = nil) {
        guard !building else { return }
        building = true
        queue.async { [weak self] in
            guard let self else { return }
            var map: [String: [DefLocation]] = [:]
            var files: [String: Set<String>] = [:]
            var count = 0
            let fm = FileManager.default
            let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
            if let en = fm.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) {
                for case let url as URL in en {
                    if Self.skipDirs.contains(url.lastPathComponent) { en.skipDescendants(); continue }
                    let lang = CodeLanguage.Language.detect(for: url)
                    guard SymbolQueries.sources[lang] != nil else { continue }
                    let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                    guard size > 0, size < 500_000 else { continue }
                    guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                    var names = Set<String>()
                    for s in TreeSitterHighlighter.symbols(in: text, language: lang) {
                        map[s.name, default: []].append(
                            DefLocation(url: url, name: s.name, kind: s.kind, range: s.range, line: s.line))
                        names.insert(s.name)
                    }
                    if !names.isEmpty { files[url.standardizedFileURL.path] = names }
                    count += 1
                    if count > 5000 { break }   // safety cap for very large trees
                }
            }
            DispatchQueue.main.async {
                self.defs = map
                self.fileNames = files
                self.isBuilt = true
                self.building = false
                completion?()
            }
        }
    }

    /// Incrementally re-indexes one file (edited/added), or drops it (deleted).
    /// Cheap enough to call on every disk change. No-op until the full build ran.
    public func updateFile(_ url: URL) {
        guard isBuilt else { return }
        let path = url.standardizedFileURL.path
        queue.async { [weak self] in
            var newDefs: [DefLocation] = []
            var names = Set<String>()
            if FileManager.default.fileExists(atPath: path) {
                let lang = CodeLanguage.Language.detect(for: url)
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                if SymbolQueries.sources[lang] != nil, size > 0, size < 500_000,
                   let text = try? String(contentsOf: url, encoding: .utf8) {
                    for s in TreeSitterHighlighter.symbols(in: text, language: lang) {
                        newDefs.append(DefLocation(url: url, name: s.name, kind: s.kind, range: s.range, line: s.line))
                        names.insert(s.name)
                    }
                }
            }
            DispatchQueue.main.async {
                guard let self, self.isBuilt else { return }
                if let old = self.fileNames[path] {
                    for n in old {
                        self.defs[n]?.removeAll { $0.url.standardizedFileURL.path == path }
                        if self.defs[n]?.isEmpty == true { self.defs[n] = nil }
                    }
                }
                for d in newDefs { self.defs[d.name, default: []].append(d) }
                self.fileNames[path] = names.isEmpty ? nil : names
            }
        }
    }

    public func definitions(of name: String) -> [DefLocation] { defs[name] ?? [] }

    /// Drop the index (e.g. on a project-folder switch) so it rebuilds fresh.
    public func invalidate() { defs = [:]; fileNames = [:]; isBuilt = false }
}
