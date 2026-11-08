import Foundation

/// Where the Whisper model lives.
public enum ModelLocation {
    public static let fileName = "ggml-large-v3-turbo-q5_0.bin"

    /// Where the app keeps its download.
    public static var appSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Hark/\(fileName)")
    }

    /// The model file, or nil when it is not downloaded yet.
    public static func existing() -> URL? {
        FileManager.default.fileExists(atPath: appSupport.path) ? appSupport : nil
    }
}
