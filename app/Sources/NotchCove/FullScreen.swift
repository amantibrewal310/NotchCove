import AppKit

/// Asks the window server about a display's Spaces. The private calls are
/// looked up at runtime, so if they're missing this reports "not full screen"
/// and leaves windows where AppKit put them instead of crashing.
enum Spaces {
    private typealias ConnectionFn = @convention(c) () -> Int32
    private typealias SpacesFn = @convention(c) (Int32) -> Unmanaged<CFArray>?
    private typealias MembershipFn = @convention(c) (Int32, CFArray, CFArray) -> Void

    private static let handle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY)

    private static func function<T>(_ name: String, as type: T.Type) -> T? {
        dlsym(handle, name).map { unsafeBitCast($0, to: type) }
    }

    private static let connection = function("CGSMainConnectionID", as: ConnectionFn.self)
    private static let copySpaces = function("CGSCopyManagedDisplaySpaces", as: SpacesFn.self)
    private static let addToSpaces = function("CGSAddWindowsToSpaces", as: MembershipFn.self)
    private static let removeFromSpaces = function("CGSRemoveWindowsFromSpaces", as: MembershipFn.self)

    /// Space types the window server uses for desktops and full-screen apps.
    private static let desktopType = 0, fullScreenType = 4

    /// Whether a full-screen app is showing on the display. Window sizes can't
    /// tell: on notched Macs full-screen windows stop below the notch.
    static func isFullScreen(on screen: NSScreen) -> Bool {
        let current = display(of: screen)?["Current Space"] as? [String: Any]
        return current?["type"] as? Int == fullScreenType
    }

    /// Puts the window on the display's desktop Spaces and takes it off its
    /// full-screen ones. Unlike a window on all Spaces, which rides out with
    /// the Space being left and snaps into the new one when the switch ends,
    /// it then slides in and out with the desktop. Returns false if the calls
    /// are unavailable.
    @discardableResult
    static func pin(_ window: NSWindow, toDesktopsOn screen: NSScreen) -> Bool {
        guard let connection, let addToSpaces, let removeFromSpaces,
              let spaces = display(of: screen)?["Spaces"] as? [[String: Any]] else { return false }
        func ids(ofType type: Int) -> CFArray {
            spaces.filter { $0["type"] as? Int == type }.compactMap { $0["ManagedSpaceID"] as? Int } as CFArray
        }
        let windows = [window.windowNumber] as CFArray
        window.collectionBehavior.remove(.canJoinAllSpaces)
        addToSpaces(connection(), windows, ids(ofType: desktopType))
        removeFromSpaces(connection(), windows, ids(ofType: fullScreenType))
        return true
    }

    private static func display(of screen: NSScreen) -> [String: Any]? {
        guard let connection, let copySpaces,
              let displays = copySpaces(connection())?.takeRetainedValue() as? [[String: Any]] else { return nil }
        // With "Displays have separate Spaces" off there's one entry, named "Main".
        return displays.count == 1 ? displays.first : displays.first { $0["Display Identifier"] as? String == uuid(of: screen) }
    }

    private static func uuid(of screen: NSScreen) -> String? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }
}
