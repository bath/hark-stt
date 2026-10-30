import Foundation
import HarkCore
import IOKit
import IOKit.hid

extension KeyMapper {
    /// The real /usr/bin/hidutil.
    public static let system = KeyMapper { arguments in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hidutil")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CocoaError(.executableLoad) }
        return String(decoding: output, as: UTF8.self)
    }
}

/// Calls back when a keyboard is connected. It watches IOKit service
/// matching, which needs no permission (opening the keyboard would need
/// Input Monitoring).
public final class KeyboardWatcher {
    private let port: IONotificationPortRef
    private var iterator: io_iterator_t = 0
    private let onConnect: () -> Void

    public init(onConnect: @escaping () -> Void) {
        self.onConnect = onConnect
        port = IONotificationPortCreate(kIOMainPortDefault)
        CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(port).takeUnretainedValue(), .defaultMode)
        let matching = IOServiceMatching(kIOHIDDeviceKey) as NSMutableDictionary
        matching[kIOHIDDeviceUsagePageKey] = kHIDPage_GenericDesktop
        matching[kIOHIDDeviceUsageKey] = kHIDUsage_GD_Keyboard
        let callback: IOServiceMatchingCallback = { refcon, iterator in
            KeyboardWatcher.drain(iterator)
            guard let refcon else { return }
            Unmanaged<KeyboardWatcher>.fromOpaque(refcon).takeUnretainedValue().onConnect()
        }
        IOServiceAddMatchingNotification(port, kIOFirstMatchNotification, matching, callback,
                                         Unmanaged.passUnretained(self).toOpaque(), &iterator)
        // The iterator must be drained once to arm the notification; these are the keyboards already here.
        Self.drain(iterator)
    }

    deinit {
        IOObjectRelease(iterator)
        IONotificationPortDestroy(port)
    }

    private static func drain(_ iterator: io_iterator_t) {
        while case let service = IOIteratorNext(iterator), service != 0 { IOObjectRelease(service) }
    }
}
