import Foundation

/// Where the Whisper model lives.
public enum ModelLocation {
    public static let fileName = "ggml-large-v3-turbo-q5_0.bin"

    /// The Hammerspoon version's download, reused when it is there.
    public static var legacy: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".cache/whisper/\(fileName)")
    }

    /// The first model file that exists, or nil.
    public static func existing(in candidates: [URL] = [legacy]) -> URL? {
        candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }
}
