import Foundation

/// What the running app writes about itself every few seconds, so
/// `Hark doctor` can report on it from another process. Permissions belong to
/// the app, so only the app can read them.
public struct AppStatus: Codable, Sendable, Equatable {
    public var version: String
    public var pid: Int32
    public var phase: String
    /// missing, downloading, loading, loaded or failed.
    public var model: String
    /// 0…1 while the model downloads.
    public var modelProgress: Double?
    public var accessibility: Bool
    public var microphone: String
    public var hotkeysTaken: [String]
    public var keyMapping: Bool?
    public var loginItem: String?
    public var updated: Date

    public init(version: String, pid: Int32, phase: String, model: String, modelProgress: Double? = nil,
                accessibility: Bool, microphone: String, hotkeysTaken: [String], keyMapping: Bool? = nil,
                loginItem: String? = nil, updated: Date) {
        self.modelProgress = modelProgress
        self.version = version
        self.pid = pid
        self.phase = phase
        self.model = model
        self.accessibility = accessibility
        self.microphone = microphone
        self.hotkeysTaken = hotkeysTaken
        self.keyMapping = keyMapping
        self.loginItem = loginItem
        self.updated = updated
    }

    public static var file: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Hark/status.json")
    }

    public func write(to url: URL = AppStatus.file) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    /// The status of a running app: a fresh file whose process is alive.
    public static func live(from url: URL = AppStatus.file, now: Date = Date()) -> AppStatus? {
        guard let status = read(from: url), now.timeIntervalSince(status.updated) < 15, kill(status.pid, 0) == 0
        else { return nil }
        return status
    }

    public static func read(from url: URL = AppStatus.file) -> AppStatus? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? Data(contentsOf: url)).flatMap { try? decoder.decode(AppStatus.self, from: $0) }
    }
}

extension DictationPhase {
    public var name: String {
        switch self {
        case .idle: "idle"
        case .recording: "recording"
        case .transcribing: "transcribing"
        case .done: "done"
        case .error: "error"
        }
    }
}
