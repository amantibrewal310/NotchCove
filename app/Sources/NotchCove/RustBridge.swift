import Foundation
import CCoveCore

public struct StagedItem: Identifiable, Codable, Equatable, Hashable {
    public let id: String
    public let groupId: String
    public let originalPath: String
    public let filename: String
    public let `extension`: String
    public let sizeBytes: UInt64
    public let formattedSize: String
    public let isDirectory: Bool
    public let kind: String
    public let stagedAt: UInt64
    public let owned: Bool

    public var url: URL { URL(fileURLWithPath: originalPath) }

    enum CodingKeys: String, CodingKey {
        case id
        case groupId = "group_id"
        case originalPath = "original_path"
        case filename
        case `extension`
        case sizeBytes = "size_bytes"
        case formattedSize = "formatted_size"
        case isDirectory = "is_directory"
        case kind
        case stagedAt = "staged_at"
        case owned
    }
}

/// A shelf entry: one file, or a stack of files that were dropped together.
public struct ShelfStack: Identifiable, Equatable {
    public let id: String
    public let items: [StagedItem]

    public var isStack: Bool { items.count > 1 }
    public var urls: [URL] { items.map(\.url) }

    public var title: String {
        isStack ? "\(items.count) Items" : (items.first?.filename ?? "")
    }

    /// Hover tooltip: the path, or the first few names in a stack.
    public var tooltip: String {
        guard isStack else { return items.first?.originalPath ?? "" }
        let names = items.prefix(10).map(\.filename).joined(separator: "\n")
        return items.count > 10 ? names + "\n…and \(items.count - 10) more" : names
    }

    public var subtitle: String {
        let total = items.reduce(0) { $0 + $1.sizeBytes }
        return ByteCountFormatter.string(fromByteCount: Int64(total), countStyle: .file)
    }
}

@MainActor
public final class CoveEngine: ObservableObject {
    public static let shared = CoveEngine()

    @Published public private(set) var items: [StagedItem] = [] {
        didSet {
            stacks = Self.group(items)
            revision &+= 1
        }
    }

    /// Items grouped into stacks, newest first. Computed once per change, not per render.
    public private(set) var stacks: [ShelfStack] = []
    /// Bumps on every change; a cheap value for views to diff against.
    public private(set) var revision = 0

    private static func group(_ items: [StagedItem]) -> [ShelfStack] {
        var order: [String] = []
        var groups: [String: [StagedItem]] = [:]
        for item in items {
            if groups[item.groupId] == nil { order.append(item.groupId) }
            groups[item.groupId, default: []].append(item)
        }
        return order.map { ShelfStack(id: $0, items: groups[$0]!) }
    }

    public let storageDirectory: URL

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        storageDirectory = support.appendingPathComponent("NotchCove", isDirectory: true)
        storageDirectory.path.withCString { cove_init($0) }
        refresh()
    }

    /// Folder for files NotchCove creates itself (text snippets, web images, archives).
    public var inboxDirectory: URL {
        guard let ptr = cove_inbox_dir() else {
            return storageDirectory.appendingPathComponent("Inbox", isDirectory: true)
        }
        defer { cove_free_string(ptr) }
        return URL(fileURLWithPath: String(cString: ptr), isDirectory: true)
    }

    /// Creates a fresh per-drop folder inside the inbox.
    public func makeDropFolder() -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let name = "\(formatter.string(from: Date()))-\(UUID().uuidString.prefix(6))"
        let dir = inboxDirectory.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Stages URLs as a single stack.
    @discardableResult
    public func stage(urls: [URL]) -> Bool {
        let paths = urls.filter(\.isFileURL).map { $0.standardizedFileURL.path }
        guard !paths.isEmpty,
              let data = try? JSONEncoder().encode(paths),
              let json = String(data: data, encoding: .utf8) else { return false }
        let ok = json.withCString { ptr -> Bool in
            guard let result = cove_stage_files(ptr) else { return false }
            cove_free_string(result)
            return true
        }
        refresh()
        return ok
    }

    public func stage(url: URL) { stage(urls: [url]) }

    /// Removes items. `deleteOwned: false` keeps inbox files that were moved out by a drag.
    public func remove(ids: [String], deleteOwned: Bool = true) {
        for id in ids {
            _ = id.withCString { cove_remove_item($0, deleteOwned) }
        }
        refresh()
    }

    public func remove(id: String) { remove(ids: [id]) }

    public func removeStack(id: String) {
        _ = id.withCString { cove_remove_group($0) }
        refresh()
    }

    public func ungroup(stackId: String) {
        _ = stackId.withCString { cove_ungroup($0) }
        refresh()
    }

    public func clearAll() {
        cove_clear_all()
        refresh()
    }

    /// Drops entries whose files were deleted or moved away.
    public func pruneMissing() {
        if cove_prune_missing() > 0 { refresh() }
    }

    /// Zips the given files in the background and stages the archive.
    public func compress(urls: [URL], completion: (@MainActor (URL?) -> Void)? = nil) {
        let paths = urls.map(\.path)
        let outDir = makeDropFolder().path
        DispatchQueue.global(qos: .userInitiated).async {
            var archive: URL?
            if let data = try? JSONEncoder().encode(paths), let json = String(data: data, encoding: .utf8) {
                json.withCString { jsonPtr in
                    outDir.withCString { dirPtr in
                        if let result = cove_zip(jsonPtr, dirPtr) {
                            archive = URL(fileURLWithPath: String(cString: result))
                            cove_free_string(result)
                        }
                    }
                }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if let archive { self.stage(url: archive) }
                    else { try? FileManager.default.removeItem(atPath: outDir) }
                    completion?(archive)
                }
            }
        }
    }

    public func refresh() {
        guard let jsonPtr = cove_get_staged_files() else {
            items = []
            return
        }
        let json = String(cString: jsonPtr)
        cove_free_string(jsonPtr)
        do {
            let decoded = try JSONDecoder().decode([StagedItem].self, from: Data(json.utf8))
            if decoded != items { items = decoded }
        } catch {
            clog("[Engine] Failed to decode staged items: \(error)")
        }
    }
}
