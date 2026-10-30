import CryptoKit
import Foundation
import Testing
@testable import HarkMac

/// A fake server for one file. It honours Range requests and can drop the
/// connection after a number of bytes.
final class FakeServer: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var body = Data()
    nonisolated(unsafe) static var failAfter: Int?
    nonisolated(unsafe) static var ignoreRange = false
    nonisolated(unsafe) static var ranges: [String?] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let range = request.value(forHTTPHeaderField: "Range")
        Self.ranges.append(range)
        var start = 0
        if let range, !Self.ignoreRange, let from = Int(range.dropFirst(6).dropLast()) { start = from }
        let part = Self.body[start...]
        let status = start > 0 ? 206 : 200
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: [
            "Content-Length": "\(part.count)",
        ])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if let failAfter = Self.failAfter {
            client?.urlProtocol(self, didLoad: part.prefix(failAfter))
            // A real connection drops some time after the last bytes arrive.
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
                self.client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            }
            return
        }
        client?.urlProtocol(self, didLoad: Data(part))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite(.serialized) struct ModelDownloaderTests {
    let body = Data((0..<200_000).map { UInt8($0 % 251) })
    var sha: String { SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined() }

    func downloader(to destination: URL, sha256: String? = nil) -> ModelDownloader {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FakeServer.self]
        return ModelDownloader(url: URL(string: "https://example.com/model.bin")!, size: Int64(body.count),
                               sha256: sha256 ?? sha, destination: destination, configuration: configuration)
    }

    func reset() -> URL {
        FakeServer.body = body
        FakeServer.failAfter = nil
        FakeServer.ignoreRange = false
        FakeServer.ranges = []
        return FileManager.default.temporaryDirectory.appending(path: "hark-dl-\(UUID().uuidString)/model.bin")
    }

    @Test func downloadsAndChecksTheFile() async throws {
        let destination = reset()
        let reports = Reports()
        try await downloader(to: destination).download { reports.add($0) }
        #expect(try Data(contentsOf: destination) == body)
        #expect(reports.last?.received == Int64(body.count))
        #expect(!FileManager.default.fileExists(atPath: destination.appendingPathExtension("part").path))
    }

    @Test func aFailedDownloadResumesWhereItStopped() async throws {
        let destination = reset()
        FakeServer.failAfter = 80_000
        await #expect(throws: (any Error).self) { try await downloader(to: destination).download { _ in } }
        let partial = destination.appendingPathExtension("part")
        #expect(try Data(contentsOf: partial).count == 80_000)

        FakeServer.failAfter = nil
        try await downloader(to: destination).download { _ in }
        #expect(FakeServer.ranges.last == "bytes=80000-")
        #expect(try Data(contentsOf: destination) == body)
    }

    @Test func aServerThatIgnoresTheRangeStartsOver() async throws {
        let destination = reset()
        FakeServer.failAfter = 50_000
        await #expect(throws: (any Error).self) { try await downloader(to: destination).download { _ in } }
        FakeServer.failAfter = nil
        FakeServer.ignoreRange = true
        try await downloader(to: destination).download { _ in }
        #expect(try Data(contentsOf: destination) == body)
    }

    @Test func aDamagedFileIsDeleted() async throws {
        let destination = reset()
        await #expect(throws: DownloadError.self) {
            try await downloader(to: destination, sha256: String(repeating: "0", count: 64)).download { _ in }
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(!FileManager.default.fileExists(atPath: destination.appendingPathExtension("part").path))
    }
}

final class Reports: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [ModelDownloader.Progress] = []
    func add(_ progress: ModelDownloader.Progress) { lock.withLock { all.append(progress) } }
    var last: ModelDownloader.Progress? { lock.withLock { all.last } }
}

/// The real 574 MB download from Hugging Face: stop it, resume it, check it.
/// Opt in with HARK_SLOW_TESTS=1.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["HARK_SLOW_TESTS"] == "1"))
struct RealModelDownloadTests {
    @Test(.timeLimit(.minutes(20))) func stopsResumesAndChecksTheRealModel() async throws {
        let model = ModelDownloader.whisperModel
        let destination = FileManager.default.temporaryDirectory.appending(path: "hark-real-\(UUID().uuidString)/model.bin")
        defer { try? FileManager.default.removeItem(at: destination.deletingLastPathComponent()) }
        @Sendable func make() -> ModelDownloader {
            ModelDownloader(url: model.url, size: model.size, sha256: model.sha256, destination: destination)
        }

        let first = Task { try await make().download { _ in } }
        while (try? FileManager.default.attributesOfItem(atPath: destination.appendingPathExtension("part").path)[.size] as? Int) ?? 0 < 30_000_000 {
            try await Task.sleep(for: .milliseconds(100))
        }
        first.cancel()
        _ = await first.result
        let kept = try FileManager.default.attributesOfItem(atPath: destination.appendingPathExtension("part").path)[.size] as! Int
        #expect(kept >= 30_000_000 && kept < model.size)

        let reports = Reports()
        try await make().download { reports.add($0) }
        let size = try FileManager.default.attributesOfItem(atPath: destination.path)[.size] as! Int64
        #expect(size == model.size)
        print("resumed from \(kept) bytes; last speed \(Int((reports.last?.bytesPerSecond ?? 0) / 1_000_000)) MB/s")
    }
}
