import Foundation
import HarkCore

/// Reads 16-bit mono PCM WAV, skipping chunks such as FLLR. For tests and
/// measurements; the app itself never writes or reads audio files.
public func readWav(_ url: URL) throws -> Samples {
    let data = try Data(contentsOf: url)
    var offset = 12
    while offset + 8 <= data.count {
        let id = String(decoding: data[offset..<offset + 4], as: UTF8.self)
        let size = Int(data[offset + 4..<offset + 8].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
        if id == "data" {
            return data[offset + 8..<min(data.count, offset + 8 + size)].withUnsafeBytes { raw in
                raw.bindMemory(to: Int16.self).map { Float($0) / 32768 }
            }
        }
        offset += 8 + size + (size & 1)
    }
    return []
}
