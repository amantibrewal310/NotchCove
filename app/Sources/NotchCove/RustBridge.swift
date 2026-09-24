import Foundation
import CCoveCore

struct StagedItem: Identifiable, Decodable, Equatable, Hashable {
    let id: String
    let groupId: String
    let originalPath: String
    let filename: String
    let sizeBytes: UInt64
    let owned: Bool

    var url: URL { URL(fileURLWithPath: originalPath) }
}

/// A shelf entry: one file, or a stack of files that were dropped together.
struct ShelfStack: Identifiable, Equatable {
    let id: String
    let items: [StagedItem]
    let title: String
    let subtitle: String
    /// Hover tooltip: the path, or the first few names in a stack.
    let tooltip: String

    init(id: String, items: [StagedItem]) {
        self.id = id
        self.items = items
        let total = items.reduce(0) { $0 + $1.sizeBytes }
        subtitle = ByteCountFormatter.string(fromByteCount: Int64(total), countStyle: .file)
        if items.count > 1 {
            title = "\(items.count) Items"
            let names = items.prefix(10).map(\.filename).joined(separator: "\n")
            tooltip = items.count > 10 ? names + "\n…and \(items.count - 10) more" : names
        } else {
            title = items.first?.filename ?? ""
            tooltip = items.first?.originalPath ?? ""
        }
    }

    var isStack: Bool { items.count > 1 }
    var urls: [URL] { items.map(\.url) }
}

@MainActor
final class CoveEngine: ObservableObject {
    static let shared = CoveEngine()

    @Published private(set) var items: [StagedItem] = [] {
        didSet {
            stacks = Self.group(items)
            revision &+= 1
        }
    }

    /// Items grouped into stacks, newest first. Computed once per change, not per render.
    private(set) var stacks: [ShelfStack] = []
    /// Bumps on every change; a cheap value for views to diff against.
    private(set) var revision = 0

    let storageDirectory: URL
    /// Folder for files NotchCove creates itself (text snippets, web images, archives).
    let inboxDirectory: URL

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    private static let dropFolderFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        storageDirectory = support.appendingPathComponent("NotchCove", isDirectory: true)
        storageDirectory.path.withCString { cove_init($0) }
        inboxDirectory = Self.takeString(cove_inbox_dir()).map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? storageDirectory.appendingPathComponent("Inbox", isDirectory: true)
        refresh()
    }

    private static func group(_ items: [StagedItem]) -> [ShelfStack] {
        var order: [String] = []
        var groups: [String: [StagedItem]] = [:]
        for item in items {
            if groups[item.groupId] == nil { order.append(item.groupId) }
            groups[item.groupId, default: []].append(item)
        }
        return order.map { ShelfStack(id: $0, items: groups[$0]!) }
    }

    /// Copies a string returned by the core and frees the original.
    private nonisolated static func takeString(_ ptr: UnsafeMutablePointer<CChar>?) -> String? {
        guard let ptr else { return nil }
        defer { cove_free_string(ptr) }
        return String(cString: ptr)
    }

    private nonisolated static func json(_ strings: [String]) -> String? {
        (try? JSONEncoder().encode(strings)).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// Creates a fresh per-drop folder inside the inbox.
    func makeDropFolder() -> URL {
        let name = "\(Self.dropFolderFormatter.string(from: Date()))-\(UUID().uuidString.prefix(6))"
        let dir = inboxDirectory.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Stages URLs as a single stack.
    func stage(urls: [URL]) {
        let paths = urls.filter(\.isFileURL).map { $0.standardizedFileURL.path }
        guard !paths.isEmpty, let json = Self.json(paths) else { return }
        _ = Self.takeString(json.withCString { cove_stage_files($0) })
        refresh()
    }

    func stage(url: URL) { stage(urls: [url]) }

    /// `deleteOwned: false` keeps inbox files that were moved out by a drag.
    func remove(ids: [String], deleteOwned: Bool = true) {
        guard let json = Self.json(ids) else { return }
        if json.withCString({ cove_remove_items($0, deleteOwned) }) > 0 { refresh() }
    }

    func ungroup(stackId: String) {
        _ = stackId.withCString { cove_ungroup($0) }
        refresh()
    }

    func clearAll() {
        cove_clear_all()
        refresh()
    }

    /// Drops entries whose files were deleted or moved away.
    func pruneMissing() {
        if cove_prune_missing() > 0 { refresh() }
    }

    /// Returns how many items were older than `maxAge` seconds and removed.
    func expire(olderThan maxAge: Int) -> Int {
        let removed = Int(cove_expire_older_than(UInt64(maxAge)))
        if removed > 0 { refresh() }
        return removed
    }

    /// When the next item expires under `maxAge`, or nil for an empty shelf.
    func nextExpiry(maxAge: Int) -> Date? {
        let next = cove_next_expiry(UInt64(maxAge))
        return next > 0 ? Date(timeIntervalSince1970: TimeInterval(next)) : nil
    }

    /// Zips the given files in the background and stages the archive.
    func compress(urls: [URL], completion: (@MainActor (URL?) -> Void)? = nil) {
        let paths = urls.map(\.path)
        let outDir = makeDropFolder().path
        DispatchQueue.global(qos: .userInitiated).async {
            let archive = Self.json(paths).flatMap { json in
                json.withCString { jsonPtr in
                    outDir.withCString { Self.takeString(cove_zip(jsonPtr, $0)) }
                }
            }.map { URL(fileURLWithPath: $0) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if let archive { self.stage(url: archive) }
                    else { try? FileManager.default.removeItem(atPath: outDir) }
                    completion?(archive)
                }
            }
        }
    }

    func refresh() {
        guard let json = Self.takeString(cove_get_staged_files()) else {
            items = []
            return
        }
        do {
            let decoded = try Self.decoder.decode([StagedItem].self, from: Data(json.utf8))
            if decoded != items { items = decoded }
        } catch {
            clog("[Engine] Failed to decode staged items: \(error)")
        }
    }
}
