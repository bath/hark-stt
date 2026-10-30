import CryptoKit
import Foundation

public enum DownloadError: Error, CustomStringConvertible {
    case http(Int)
    case checksumMismatch

    public var description: String {
        switch self {
        case let .http(code): "the server answered HTTP \(code)"
        case .checksumMismatch: "the download was damaged (wrong checksum), so it was deleted"
        }
    }
}

/// Downloads a large file into `destination`. It writes to `<destination>.part`
/// and asks for the rest with a Range request, so a failed download resumes
/// where it stopped, even after a restart. The file is only moved into place
/// when its SHA-256 matches.
public final class ModelDownloader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    public struct Progress: Sendable, Equatable {
        public var received: Int64
        public var total: Int64
        public var bytesPerSecond: Double

        public var fraction: Double { total > 0 ? Double(received) / Double(total) : 0 }
        public var secondsLeft: Double? {
            bytesPerSecond > 0 ? Double(total - received) / bytesPerSecond : nil
        }
    }

    /// The model the installer and the Hammerspoon version use.
    public static let whisperModel = (
        url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin")!,
        size: Int64(574_041_195),
        sha256: "394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2"
    )

    private let url: URL
    private let size: Int64
    private let sha256: String
    private let destination: URL
    private let configuration: URLSessionConfiguration
    private let lock = NSLock()
    // Guarded by `lock`, written by the session's delegate queue.
    private var file: FileHandle?
    private var received: Int64 = 0
    private var startedAt = Date()
    private var startedFrom: Int64 = 0
    private var lastReport = Date.distantPast
    private var onProgress: (@Sendable (Progress) -> Void)?
    private var finish: CheckedContinuation<Void, any Error>?
    private var responseError: (any Error)?

    public init(url: URL, size: Int64, sha256: String, destination: URL,
                configuration: URLSessionConfiguration = .default) {
        self.url = url
        self.size = size
        self.sha256 = sha256
        self.destination = destination
        self.configuration = configuration
    }

    public var partial: URL { destination.appendingPathExtension("part") }

    /// Downloads, resuming a partial file, and checks the result.
    public func download(progress: @escaping @Sendable (Progress) -> Void) async throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fileManager.fileExists(atPath: partial.path) { fileManager.createFile(atPath: partial.path, contents: nil) }
        let handle = try FileHandle(forWritingTo: partial)
        let offset = try handle.seekToEnd()
        lock.withLock {
            file = handle
            received = Int64(offset)
            startedFrom = Int64(offset)
            startedAt = Date()
            onProgress = progress
            responseError = nil
        }

        if Int64(offset) < size {
            var request = URLRequest(url: url)
            if offset > 0 { request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
            defer { session.finishTasksAndInvalidate() }
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    lock.withLock { finish = continuation }
                    session.dataTask(with: request).resume()
                }
            } onCancel: {
                session.invalidateAndCancel()
            }
        }
        try handle.close()
        lock.withLock { file = nil }

        guard try Self.sha256(of: partial) == sha256 else {
            try? fileManager.removeItem(at: partial)
            throw DownloadError.checksumMismatch
        }
        if fileManager.fileExists(atPath: destination.path) { try fileManager.removeItem(at: destination) }
        try fileManager.moveItem(at: partial, to: destination)
    }

    public static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - URLSessionDataDelegate

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                           completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let allowed = lock.withLock { () -> Bool in
            switch status {
            case 206:
                return true
            case 200:
                // The server sent the whole file, not the rest: start over.
                try? file?.truncate(atOffset: 0)
                received = 0
                startedFrom = 0
                return true
            default:
                responseError = DownloadError.http(status)
                return false
            }
        }
        completionHandler(allowed ? .allow : .cancel)
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let report = lock.withLock { () -> (Progress, (@Sendable (Progress) -> Void)?)? in
            do {
                try file?.write(contentsOf: data)
            } catch {
                responseError = error
                dataTask.cancel()
                return nil
            }
            received += Int64(data.count)
            let now = Date()
            guard now.timeIntervalSince(lastReport) > 0.2 || received == size else { return nil }
            lastReport = now
            let elapsed = now.timeIntervalSince(startedAt)
            let speed = elapsed > 0.5 ? Double(received - startedFrom) / elapsed : 0
            return (Progress(received: received, total: size, bytesPerSecond: speed), onProgress)
        }
        if let (progress, callback) = report { callback?(progress) }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let (continuation, failure) = lock.withLock { () -> (CheckedContinuation<Void, any Error>?, (any Error)?) in
            defer { finish = nil }
            return (finish, responseError ?? error)
        }
        if let failure { continuation?.resume(throwing: failure) } else { continuation?.resume() }
    }
}
