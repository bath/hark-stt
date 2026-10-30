import Foundation

/// "Check for Updates…": the only time Hark talks to anything past this Mac.
/// It asks GitHub for the latest release.
public enum Updates {
    public static let latestRelease = URL(string: "https://api.github.com/repos/bath/hark-stt/releases/latest")!

    public struct Release: Sendable, Equatable {
        public let version: String
        /// The release page.
        public let page: URL
        /// The Hark.app disk image, when the release has one.
        public let diskImage: URL?
    }

    public enum Answer: Sendable, Equatable {
        case upToDate
        case available(Release)
    }

    /// Reads GitHub's `releases/latest` JSON.
    public static func parse(_ data: Data) throws -> Release {
        struct Payload: Decodable {
            struct Asset: Decodable {
                let name: String
                let browser_download_url: URL
            }
            let tag_name: String
            let html_url: URL
            let assets: [Asset]
        }
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        let version = payload.tag_name.hasPrefix("v") ? String(payload.tag_name.dropFirst()) : payload.tag_name
        let image = payload.assets.first { $0.name.hasPrefix("Hark") && $0.name.hasSuffix(".dmg") }
        return Release(version: version, page: payload.html_url, diskImage: image?.browser_download_url)
    }

    public static func answer(_ release: Release, current: String) -> Answer {
        isNewer(release.version, than: current) ? .available(release) : .upToDate
    }

    /// Compares dotted versions number by number: 1.10.0 is newer than 1.9.2.
    public static func isNewer(_ latest: String, than current: String) -> Bool {
        let numbers = { (version: String) in
            version.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        }
        let a = numbers(latest), b = numbers(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// Asks GitHub. Throws when GitHub does not answer with a release.
    public static func check(current: String, session: URLSession = .shared) async throws -> Answer {
        var request = URLRequest(url: latestRelease, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Hark/\(current)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return answer(try parse(data), current: current)
    }
}
