import AppKit

/// Spots a full-screen Space on a display. Asked only when the Space or the
/// frontmost app changes, never on a timer.
///
/// Window sizes can't tell: on notched Macs full-screen windows stop below the
/// notch, exactly like a maximised window. So this asks the window server for
/// the current Space's type, as tools like yabai and Hammerspoon do. It's a
/// private call, looked up at runtime so a future macOS without it just
/// reports "not full screen" instead of crashing.
enum FullScreenDetector {
    private typealias ConnectionFn = @convention(c) () -> Int32
    private typealias SpacesFn = @convention(c) (Int32) -> Unmanaged<CFArray>?

    private static let functions: (ConnectionFn, SpacesFn)? = {
        guard let handle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY),
              let connection = dlsym(handle, "CGSMainConnectionID"),
              let spaces = dlsym(handle, "CGSCopyManagedDisplaySpaces") else { return nil }
        return (unsafeBitCast(connection, to: ConnectionFn.self), unsafeBitCast(spaces, to: SpacesFn.self))
    }()

    /// Space type the window server uses for full-screen apps.
    private static let fullScreenSpaceType = 4

    static func isActive(on screen: NSScreen) -> Bool {
        guard let (connection, copySpaces) = functions,
              let displays = copySpaces(connection())?.takeRetainedValue() as? [[String: Any]] else { return false }
        // With "Displays have separate Spaces" off there's one entry, named "Main".
        let display = displays.count == 1 ? displays.first : displays.first { $0["Display Identifier"] as? String == uuid(of: screen) }
        let current = display?["Current Space"] as? [String: Any]
        return current?["type"] as? Int == fullScreenSpaceType
    }

    private static func uuid(of screen: NSScreen) -> String? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }
}
