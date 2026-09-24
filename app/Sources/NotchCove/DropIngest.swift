import AppKit
import UniformTypeIdentifiers

/// Turns whatever is on a drag (or general) pasteboard into files on the shelf.
///
/// Priority mirrors what the user most likely meant:
/// real files → promised files (Mail, Photos, Safari) → image data → web link → text.
@MainActor
enum DropIngest {
    static let draggedTypes: [NSPasteboard.PasteboardType] = {
        var types: [NSPasteboard.PasteboardType] = [
            .fileURL, .URL, .string, .tiff, .png, .rtf,
            NSPasteboard.PasteboardType("NSFilenamesPboardType"),
        ]
        types += NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
        return types
    }()

    private static let urlNameType = NSPasteboard.PasteboardType("public.url-name")

    static func canAccept(_ pasteboard: NSPasteboard) -> Bool {
        guard let types = pasteboard.types, !types.isEmpty else { return false }
        return pasteboard.canReadObject(
            forClasses: [NSURL.self, NSFilePromiseReceiver.self, NSImage.self, NSString.self],
            options: nil
        )
    }

    /// Reads the pasteboard and stages its contents as one stack.
    /// `completion` receives the number of items staged.
    static func ingest(_ pasteboard: NSPasteboard, completion: @escaping @MainActor (Int) -> Void) {
        let engine = CoveEngine.shared

        // 1. Real files and folders.
        let fileURLs = (pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL]) ?? []
        if !fileURLs.isEmpty {
            engine.stage(urls: fileURLs)
            completion(fileURLs.count)
            return
        }

        // 2. File promises: files that don't exist on disk yet.
        if let receivers = pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver],
           !receivers.isEmpty {
            receivePromises(receivers, completion: completion)
            return
        }

        // 3. Raw image data (e.g. images dragged from Chrome).
        if let image = NSImage(pasteboard: pasteboard), pasteboard.availableType(from: [.tiff, .png]) != nil,
           let url = save(image: image, suggestedName: pasteboard.string(forType: urlNameType)) {
            engine.stage(url: url)
            completion(1)
            return
        }

        // 4. A web link → .webloc. Plain text that is just a URL counts too.
        if let url = webLink(in: pasteboard),
           let file = saveWebloc(url, title: pasteboard.string(forType: urlNameType)) {
            engine.stage(url: file)
            completion(1)
            return
        }

        // 5. Text that is just file paths (e.g. Zed / VS Code "Copy Path",
        //    terminal output) → the files themselves, not a snippet.
        if let text = pasteboard.string(forType: .string), let urls = filePaths(in: text) {
            engine.stage(urls: urls)
            completion(urls.count)
            return
        }

        // 6. Plain text → .txt snippet.
        if let text = pasteboard.string(forType: .string),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let file = saveText(text) {
            engine.stage(url: file)
            completion(1)
            return
        }

        completion(0)
    }

    /// Every non-empty line is an absolute (or ~) path to something that exists.
    private static func filePaths(in text: String) -> [URL]? {
        let lines = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty, lines.count <= 500 else { return nil }
        var urls: [URL] = []
        for line in lines {
            let path = (line.hasPrefix("file://") ? URL(string: line)?.path : (line as NSString).expandingTildeInPath) ?? line
            guard path.hasPrefix("/"), FileManager.default.fileExists(atPath: path) else { return nil }
            urls.append(URL(fileURLWithPath: path))
        }
        return urls
    }

    private static func webLink(in pasteboard: NSPasteboard) -> URL? {
        let candidates = (pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] ?? [])
            + [pasteboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines)]
                .compactMap { $0 }
                .filter { !$0.contains(where: \.isWhitespace) }
                .compactMap(URL.init(string:))
        return candidates.first { ["http", "https"].contains($0.scheme?.lowercased() ?? "") && $0.host != nil }
    }

    // MARK: - Promises

    private static func receivePromises(
        _ receivers: [NSFilePromiseReceiver],
        completion: @escaping @MainActor (Int) -> Void
    ) {
        let destination = CoveEngine.shared.makeDropFolder()
        let queue = OperationQueue()
        queue.qualityOfService = .userInitiated
        let group = DispatchGroup()
        let lock = NSLock()
        var received: [URL] = []
        var finished = false

        for receiver in receivers {
            let expected = max(receiver.fileNames.count, 1)
            for _ in 0..<expected { group.enter() }
            var remaining = expected
            receiver.receivePromisedFiles(atDestination: destination, options: [:], operationQueue: queue) { url, error in
                lock.lock()
                if error == nil { received.append(url) }
                else { clog("[Drop] Promise failed: \(error!.localizedDescription)") }
                let shouldLeave = remaining > 0
                remaining -= 1
                lock.unlock()
                if shouldLeave { group.leave() }
            }
        }

        let finish: @Sendable () -> Void = {
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    lock.lock()
                    guard !finished else { lock.unlock(); return }
                    finished = true
                    let urls = received
                    lock.unlock()
                    if urls.isEmpty {
                        try? FileManager.default.removeItem(at: destination)
                    } else {
                        CoveEngine.shared.stage(urls: urls)
                    }
                    completion(urls.count)
                }
            }
        }
        group.notify(queue: .global(), execute: finish)
        // Some sources report the wrong file count; never wait forever.
        DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: finish)
    }

    // MARK: - Writers

    private static func save(image: NSImage, suggestedName: String?) -> URL? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        let base = sanitize(suggestedName.map { ($0 as NSString).deletingPathExtension } ?? "") ?? "Image"
        let url = CoveEngine.shared.makeDropFolder().appendingPathComponent("\(base).png")
        return (try? png.write(to: url)) != nil ? url : nil
    }

    private static func saveWebloc(_ link: URL, title: String?) -> URL? {
        let base = sanitize(title ?? "") ?? sanitize(link.host ?? "") ?? "Link"
        let url = CoveEngine.shared.makeDropFolder().appendingPathComponent("\(base).webloc")
        guard let data = try? PropertyListSerialization.data(
            fromPropertyList: ["URL": link.absoluteString], format: .xml, options: 0
        ) else { return nil }
        return (try? data.write(to: url)) != nil ? url : nil
    }

    private static func saveText(_ text: String) -> URL? {
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let base = sanitize(String(firstLine.prefix(40))) ?? "Text Snippet"
        let url = CoveEngine.shared.makeDropFolder().appendingPathComponent("\(base).txt")
        return (try? text.write(to: url, atomically: true, encoding: .utf8)) != nil ? url : nil
    }

    /// Makes a string safe for use as a file name; nil when nothing usable is left.
    private static func sanitize(_ name: String) -> String? {
        let cleaned = name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        return cleaned.isEmpty ? nil : String(cleaned.prefix(80))
    }
}
