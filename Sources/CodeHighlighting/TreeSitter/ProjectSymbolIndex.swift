import Foundation
import CodeLanguage

/// A definition found somewhere in the project.
public struct DefLocation {
    /// The file the definition lives in.
    public let url: URL
    /// The identifier as written at the definition site.
    public let name: String
    /// What kind of definition this is.
    public let kind: SymbolKind
    /// The name identifier's range within that file.
    public let range: NSRange
    /// 1-based line of the definition.
    public let line: Int
}

/// Parses every source file in the project and maps symbol names to their
/// definitions, for cross-file Go-to-Definition and hover-doc. Built on a
/// background queue; updated incrementally per-file as things change on disk.
public final class ProjectSymbolIndex {
    private var defs: [String: [DefLocation]] = [:]
    private var fileNames: [String: Set<String>] = [:]   // file path → the names it defines
    /// Every name in `defs`, lowercased and sorted, paired with its original
    /// spelling — the prefix query's binary-search cursor. nil = stale; rebuilt
    /// on demand by ``sortedNameCursor()``. See ``definitions(matchingPrefix:limit:)``
    /// for why the exact-match `defs` dictionary can't serve prefix lookups.
    private var sortedNames: [(lower: String, name: String)]?
    /// Whether the initial `build(root:)` has completed and installed its results.
    /// `updateFile(_:)` is a no-op until this is true.
    public private(set) var isBuilt = false
    /// Whether a `build(root:)` is in flight and not yet installed. While true,
    /// `updateFile(_:)` calls are recorded in ``pendingUpdates`` instead of
    /// dropped — the build's enumerator may already have read the file before
    /// the edit, so a discarded notification would leave stale symbols with
    /// nothing to ever correct them.
    private var isBuilding = false
    /// Files whose change notifications arrived mid-build, keyed by canonical
    /// path (one replay per file). Replayed through `updateFile(_:)` right
    /// after the build installs; cleared by `invalidate()`.
    private var pendingUpdates: [String: URL] = [:]
    private var generation = 0   // bumped by build()/invalidate() so a superseded build's results are discarded
    private let queue = DispatchQueue(label: "sidewatch.symbolindex", qos: .userInitiated)

    /// Creates an empty index; call `build(root:)` to populate it.
    public init() {}

    /// The built-in noise list never descended into during a build.
    public static let defaultSkipDirs: Set<String> = [
        ".git", ".svn", ".hg", "node_modules", ".build", ".swiftpm", "Pods",
        "DerivedData", "dist", "build", "__pycache__", ".next", ".cache", "vendor",
    ]

    /// Directory names never descended into during a build. Defaults to
    /// ``defaultSkipDirs``; assign to override (e.g. from a user preference — a
    /// project with real sources in `dist/` needs it off the list, or its symbols
    /// never enter the index).
    ///
    /// - Important: Global mutable state read by every ``build(root:completion:)``.
    ///   Set it during start-up; changing it later needs a rebuild to take effect.
    public static var skipDirs: Set<String> = defaultSkipDirs

    /// A path key that stays stable across the file's deletion. `standardizedFileURL`
    /// alone is existence-dependent on macOS (`/private/var/...` is only collapsed
    /// to `/var/...` while the path exists), so a just-deleted file's key would
    /// drift and `updateFile` would fail to drop its stale definitions. Resolving
    /// symlinks on the parent directory (which still exists after the delete)
    /// yields the same key before and after. Internal for tests.
    static func canonicalPath(for url: URL) -> String {
        let u = url.standardizedFileURL
        return u.deletingLastPathComponent().resolvingSymlinksInPath()
            .appendingPathComponent(u.lastPathComponent).path
    }

    /// (Re)builds the whole index from `root`. `completion` runs on the main queue.
    /// A later `build()` or `invalidate()` supersedes an in-flight build: the
    /// superseded build still calls its completion, but its results are discarded —
    /// so a project switch can never install the previous project's index.
    public func build(root: URL, completion: (() -> Void)? = nil) {
        generation += 1
        let gen = generation
        isBuilding = true
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
                    if !names.isEmpty { files[Self.canonicalPath(for: url)] = names }
                    count += 1
                    if count > 5000 { break }   // safety cap for very large trees
                }
            }
            DispatchQueue.main.async {
                if self.generation == gen {   // still the newest request → install
                    self.defs = map
                    self.fileNames = files
                    self.sortedNames = nil   // names replaced wholesale
                    self.isBuilt = true
                    self.isBuilding = false
                    // Replay edits the scan raced against: the enumerator may
                    // have read a file before its mid-build change, so the
                    // installed snapshot can be stale for exactly these files.
                    let pending = self.pendingUpdates
                    self.pendingUpdates = [:]
                    for url in pending.values { self.updateFile(url) }
                }
                completion?()
            }
        }
    }

    /// Incrementally re-indexes one file (edited/added), or drops it (deleted).
    /// Cheap enough to call on every disk change. No-op until the full build ran,
    /// except mid-build: those calls are queued and replayed once it installs.
    public func updateFile(_ url: URL) {
        guard isBuilt else {
            if isBuilding { pendingUpdates[Self.canonicalPath(for: url)] = url }
            return
        }
        let path = Self.canonicalPath(for: url)
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
                        self.defs[n]?.removeAll { Self.canonicalPath(for: $0.url) == path }
                        if self.defs[n]?.isEmpty == true { self.defs[n] = nil }
                    }
                }
                for d in newDefs { self.defs[d.name, default: []].append(d) }
                self.fileNames[path] = names.isEmpty ? nil : names
                self.sortedNames = nil   // this file's names entered/left `defs`
            }
        }
    }

    /// All known definitions of `name` across the project (empty before the
    /// build completes, or when the name is undefined).
    /// - Note: Read on the main queue — the index installs its updates there.
    public func definitions(of name: String) -> [DefLocation] { defs[name] ?? [] }

    /// One definition per known name starting with `prefix`, case-insensitively,
    /// alphabetical, at most `limit` of them — the completion popup's
    /// project-symbol tier. A name defined in several files yields its first
    /// definition only: the popup wants one row per name, not per site.
    /// Empty for an empty `prefix` (every symbol is not a suggestion) and
    /// before the build completes.
    ///
    /// Cost is a binary search plus a walk of the matches, NOT a scan of the
    /// project's symbols: `defs` is keyed for exact lookup, so the names are
    /// mirrored into ``sortedNames`` — lowercased and sorted once per index
    /// change, then reused across every keystroke of a typing burst. That
    /// mirror is what makes this callable on the typing path; the rebuild is
    /// lazy, so a burst of `updateFile(_:)` calls costs one rebuild total, at
    /// the next query rather than per file.
    ///
    /// - Note: Main queue only — the index installs its updates there, and the
    ///   cursor cache is not synchronized.
    public func definitions(matchingPrefix prefix: String, limit: Int = 50) -> [DefLocation] {
        guard !prefix.isEmpty, limit > 0 else { return [] }
        let needle = prefix.lowercased()
        let names = sortedNameCursor()
        var out: [DefLocation] = []
        var i = Self.lowerBound(of: needle, in: names)
        // Sorted by `lower`, so the prefix matches are one contiguous run:
        // stop at the first name that doesn't match rather than walking on.
        while i < names.count, names[i].lower.hasPrefix(needle) {
            if let def = defs[names[i].name]?.first {
                out.append(def)
                if out.count >= limit { break }
            }
            i += 1
        }
        return out
    }

    /// The lazily-rebuilt sorted name mirror behind ``definitions(matchingPrefix:limit:)``.
    /// Sorted by the lowercased name (the prefix match is case-insensitive),
    /// tie-broken by the original spelling so two names differing only in case
    /// hold a stable order.
    private func sortedNameCursor() -> [(lower: String, name: String)] {
        if let cached = sortedNames { return cached }
        var built: [(lower: String, name: String)] = []
        built.reserveCapacity(defs.count)
        for name in defs.keys { built.append((lower: name.lowercased(), name: name)) }
        built.sort { (a: (lower: String, name: String), b: (lower: String, name: String)) -> Bool in
            a.lower == b.lower ? a.name < b.name : a.lower < b.lower
        }
        sortedNames = built
        return built
    }

    /// Index of the first entry whose `lower` sorts at or after `needle` — the
    /// start of the prefix run, or `names.count` when nothing can match.
    private static func lowerBound(of needle: String, in names: [(lower: String, name: String)]) -> Int {
        var low = 0, high = names.count
        while low < high {
            let mid = (low + high) / 2
            if names[mid].lower < needle { low = mid + 1 } else { high = mid }
        }
        return low
    }

    /// Drop the index (e.g. on a project-folder switch) so it rebuilds fresh.
    /// Also supersedes any in-flight build so its stale results are discarded.
    public func invalidate() {
        generation += 1
        defs = [:]
        fileNames = [:]
        sortedNames = nil
        isBuilt = false
        isBuilding = false
        pendingUpdates = [:]
    }
}
