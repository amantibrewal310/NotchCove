import AppKit

/// What happens to a new screenshot.
public enum ScreenshotMode: String, CaseIterable {
    case off
    /// Screenshot stays where macOS saved it; the shelf just points to it.
    case keepFile
    /// Screenshot moves into the Cove Inbox, keeping the Desktop clean. It's
    /// removed with the shelf item (or by auto-clear) unless you drag it out.
    case moveToShelf

    static let defaultsKey = "ScreenshotMode"

    public static var current: ScreenshotMode {
        get { ScreenshotMode(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .off }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey) }
    }

    public var title: String {
        switch self {
        case .off: "Don't Add to Shelf"
        case .keepFile: "Add to Shelf, Keep Saved File"
        case .moveToShelf: "Move to Shelf Only"
        }
    }
}

/// Adds new screenshots to the shelf. Watches only the folder macOS saves
/// screenshots to, with a kernel event source (no polling), and recognises
/// screenshots by the metadata attribute screencapture writes, so it works
/// in every language and ignores other files landing on the Desktop.
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

        let fresh = files.filter { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  let created = values.creationDate, created >= startedAt,
                  !seen.contains(url.path) else { return false }
            return Self.isScreenshot(url)
        }
        .sorted { ($0.creationDateValue ?? .distantPast) < ($1.creationDateValue ?? .distantPast) }
        guard !fresh.isEmpty else { return }

        for url in fresh {
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

    /// screencapture tags its files with kMDItemIsScreenCapture.
    private static func isScreenshot(_ url: URL) -> Bool {
        getxattr(url.path, "com.apple.metadata:kMDItemIsScreenCapture", nil, 0, 0, 0) >= 0
    }

    /// Where macOS saves screenshots (⌘⇧5 › Options › Save to); Desktop by default.
    static var screenshotFolder: URL {
        let desktop = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
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

private extension URL {
    var creationDateValue: Date? { try? resourceValues(forKeys: [.creationDateKey]).creationDate }
}
