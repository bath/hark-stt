import Carbon.HIToolbox

/// Global hotkeys through Carbon's RegisterEventHotKey. They need no
/// permission, and macOS does not pass the key on to the focused app.
@MainActor
final class Hotkeys {
    struct Key {
        let name: String
        let code: UInt32
        let modifiers: UInt32
    }

    /// F18 is what the dictation key (F5) is mapped to. ⌥Space works on every keyboard.
    static let dictation = [
        Key(name: "F5 (as F18)", code: UInt32(kVK_F18), modifiers: 0),
        Key(name: "⌥Space", code: UInt32(kVK_Space), modifiers: UInt32(optionKey)),
    ]

    private let action: () -> Void
    private var refs: [EventHotKeyRef] = []
    private var ids: Set<UInt32> = []
    private var handler: EventHandlerRef?
    /// Hotkey IDs are unique across instances, because every handler sees every hotkey.
    private static var nextID: UInt32 = 1

    init(action: @escaping () -> Void) {
        self.action = action
    }

    /// Registers the keys and returns the names of the ones another app already has.
    func register(_ keys: [Key] = dictation) -> [String] {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let callback: EventHandlerUPP = { _, event, userData in
            guard let userData, let event else { return OSStatus(eventNotHandledErr) }
            var pressed = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &pressed)
            let hotkeys = Unmanaged<Hotkeys>.fromOpaque(userData).takeUnretainedValue()
            return MainActor.assumeIsolated {
                guard hotkeys.ids.contains(pressed.id) else { return OSStatus(eventNotHandledErr) }
                hotkeys.action()
                return noErr
            }
        }
        InstallEventHandler(GetApplicationEventTarget(), callback, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)

        var failed: [String] = []
        for key in keys {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: OSType(0x4841_524B), id: Self.nextID) // "HARK"
            Self.nextID += 1
            if RegisterEventHotKey(key.code, key.modifiers, id, GetApplicationEventTarget(), 0, &ref) == noErr, let ref {
                refs.append(ref)
                ids.insert(id.id)
            } else {
                failed.append(key.name)
            }
        }
        return failed
    }

    func unregister() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs = []
        ids = []
        if let handler { RemoveEventHandler(handler) }
        handler = nil
    }
}
