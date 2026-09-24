import Carbon.HIToolbox

/// System-wide keyboard shortcut via Carbon's RegisterEventHotKey, which
/// (unlike key event monitors) needs no Accessibility permission.
@MainActor
final class HotKey {
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var nextId: UInt32 = 1
    private static var eventHandlerInstalled = false

    private var ref: EventHotKeyRef?

    /// `keyCode` is a virtual key (e.g. `kVK_ANSI_C`); `modifiers` are Carbon flags (`controlKey | optionKey`).
    init?(keyCode: Int, modifiers: Int, handler: @escaping () -> Void) {
        Self.installEventHandlerIfNeeded()
        let id = Self.nextId
        Self.nextId += 1

        let hotKeyID = EventHotKeyID(signature: OSType(0x4E43_6F76), id: id) // 'NCov'
        let status = RegisterEventHotKey(
            UInt32(keyCode), UInt32(modifiers), hotKeyID,
            GetApplicationEventTarget(), 0, &ref
        )
        guard status == noErr else { return nil }
        Self.handlers[id] = handler
    }

    private static func installEventHandlerIfNeeded() {
        guard !eventHandlerInstalled else { return }
        eventHandlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID
            )
            guard status == noErr else { return status }
            let id = hotKeyID.id
            DispatchQueue.main.async {
                MainActor.assumeIsolated { HotKey.handlers[id]?() }
            }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
