import AppKit

/// What happens to a new screenshot.
enum ScreenshotMode: String, Setting {
    case off
    case keepFile
    /// Moves into the Cove Inbox; deleted with the shelf item unless dragged out.
    case moveToShelf

    static let defaultsKey = "ScreenshotMode"
    static let defaultValue = ScreenshotMode.off

    var title: String {
        switch self {
        case .off: "Don't Add to Shelf"
        case .keepFile: "Add to Shelf, Keep Saved File"
        case .moveToShelf: "Move to Shelf Only"
        }
    }
}

/// Adds new screenshots to the shelf. Watches the screenshot folder with a
/// kernel event source and matches files by screencapture's metadata
/// attribute, so it works in every language.
@MainActor
final class ScreenshotWatcher {
    static let shared = ScreenshotWatcher()

    private var source: DispatchSourceFileSystemObject?
    private var watchedFolder: URL?
    private var startedAt = Date()
    private var seen = Set<String>()
    private var scanWork: DispatchWorkItem?

    func start() {
        apply()
        // The save location can change in the ⌘⇧5 options.
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.screencapture.prefsChanged"), object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { ScreenshotWatcher.shared.apply() }
        }
    }

    func setMode(_ mode: ScreenshotMode) {
        ScreenshotMode.current = mode
        apply()
    }

    /// Starts, stops, or retargets the watcher to match the current settings.
    func apply() {
        guard ScreenshotMode.current != .off else {
            stop()
            return
        }
        let folder = Self.screenshotFolder
        guard folder != watchedFolder || source == nil else { return }
        stop()

        let fd = open(folder.path, O_EVTONLY)
        guard fd >= 0 else {
            clog("[Screenshots] can't watch \(folder.path)")
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.scheduleScan() }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
        watchedFolder = folder
        // Only screenshots taken from now on; never sweep up older ones.
        startedAt = Date()
        seen = []
    }

    private func stop() {
        source?.cancel()
        source = nil
        watchedFolder = nil
        scanWork?.cancel()
    }

    /// Folder changes arrive in bursts (temp file, rename); scan once they settle.
    private func scheduleScan() {
        scanWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.scan() }
        scanWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func scan() {
        guard let folder = watchedFolder else { return }
        let keys: [URLResourceKey] = [.creationDateKey, .isRegularFileKey]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else { return }

        let fresh = files.compactMap { url -> (url: URL, created: Date)? in
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  let created = values.creationDate, created >= startedAt,
                  !seen.contains(url.path), Self.isScreenshot(url) else { return nil }
            return (url, created)
        }
        .sorted { $0.created < $1.created }
        guard !fresh.isEmpty else { return }

        for (url, _) in fresh {
            seen.insert(url.path)
            var staged = url
            if ScreenshotMode.current == .moveToShelf {
                let destination = CoveEngine.shared.makeDropFolder().appendingPathComponent(url.lastPathComponent)
                if (try? FileManager.default.moveItem(at: url, to: destination)) != nil { staged = destination }
            }
            // One card per screenshot, not a stack.
            CoveEngine.shared.stage(url: staged)
        }
        NotchWindowManager.shared.peek()
    }

    private static func isScreenshot(_ url: URL) -> Bool {
        getxattr(url.path, "com.apple.metadata:kMDItemIsScreenCapture", nil, 0, 0, 0) >= 0
    }

    /// Where macOS saves screenshots (⌘⇧5 › Options › Save to); Desktop by default.
    static var screenshotFolder: URL {
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
        let domain = "com.apple.screencapture" as CFString
        CFPreferencesAppSynchronize(domain)  // pick up changes made since launch
        guard let location = CFPreferencesCopyAppValue("location" as CFString, domain) as? String else {
            return desktop
        }
        var isDirectory: ObjCBool = false
        let path = (location as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return desktop
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }
}
