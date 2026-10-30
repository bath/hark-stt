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
    private var handler: EventHandlerRef?

    init(action: @escaping () -> Void) {
        self.action = action
    }

    /// Registers the keys and returns the names of the ones another app already has.
    func register(_ keys: [Key] = dictation) -> [String] {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let callback: EventHandlerUPP = { _, _, userData in
            guard let userData else { return noErr }
            let hotkeys = Unmanaged<Hotkeys>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated { hotkeys.action() }
            return noErr
        }
        InstallEventHandler(GetApplicationEventTarget(), callback, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)

        var failed: [String] = []
        for (index, key) in keys.enumerated() {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: OSType(0x4841_524B), id: UInt32(index)) // "HARK"
            if RegisterEventHotKey(key.code, key.modifiers, id, GetApplicationEventTarget(), 0, &ref) == noErr, let ref {
                refs.append(ref)
            } else {
                failed.append(key.name)
            }
        }
        return failed
    }

    func unregister() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs = []
        if let handler { RemoveEventHandler(handler) }
        handler = nil
    }
}
