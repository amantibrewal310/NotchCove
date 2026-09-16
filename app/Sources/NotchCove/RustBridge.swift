import Foundation
import CCoveCore

public struct StagedItem: Identifiable, Codable, Equatable, Hashable {
    public let id: String
    public let originalPath: String
    public let filename: String
    public let `extension`: String
    public let sizeBytes: UInt64
    public let formattedSize: String
    public let isDirectory: Bool
    public let kind: String
    public let stagedAt: UInt64

    enum CodingKeys: String, CodingKey {
        case id
        case originalPath = "original_path"
        case filename
        case `extension`
        case sizeBytes = "size_bytes"
        case formattedSize = "formatted_size"
        case isDirectory = "is_directory"
        case kind
        case stagedAt = "staged_at"
    }
}

@MainActor
public final class CoveEngine: ObservableObject {
    public static let shared = CoveEngine()

    @Published public private(set) var items: [StagedItem] = []

    private init() {
        cove_init()
        refresh()
    }

    public func stage(url: URL) {
        let path = url.standardizedFileURL.path
        path.withCString { cStr in
            if let resultPtr = cove_stage_file(cStr) {
                cove_free_string(resultPtr)
            }
        }
        refresh()
    }

    public func stage(path: String) {
        path.withCString { cStr in
            if let resultPtr = cove_stage_file(cStr) {
                cove_free_string(resultPtr)
            }
        }
        refresh()
    }

    public func remove(id: String) {
        id.withCString { cStr in
            _ = cove_remove_item(cStr)
        }
        refresh()
    }

    public func clearAll() {
        cove_clear_all()
        refresh()
    }

    public func refresh() {
        guard let jsonPtr = cove_get_staged_files() else {
            self.items = []
            return
        }

        let jsonString = String(cString: jsonPtr)
        cove_free_string(jsonPtr)

        guard let data = jsonString.data(using: .utf8) else {
            return
        }

        do {
            let decoder = JSONDecoder()
            self.items = try decoder.decode([StagedItem].self, from: data)
        } catch {
            print("[NotchCove] Failed to decode staged items: \(error)")
        }
    }
}
