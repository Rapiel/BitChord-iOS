import BitChordCore
import Foundation

// Android data/sources/StreamLengthProbe.kt (94250cce).

/// How big a stream's file is, without reading it: for catching an addon that answers a
/// full-length row with its 30-second preview. Only the start of a substitute asks; an upgrade is
/// auditioned against the decoded runtime instead.
enum StreamLengthProbe {
    /// Below what any 16-bit stereo FLAC of music runs at.
    static let losslessFloorKbps = 200
    /// Below every lossy tier an addon offers for music.
    static let lossyFloorKbps = 64

    /// The file's total size in bytes, or nil when the server won't say (or isn't a file at all).
    /// One ranged request for a single byte; its body is never read.
    static func bytesOf(_ stream: ResolvedStream, session: URLSession, timeout: TimeInterval) async -> Int64? {
        guard let scheme = stream.url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        let ext = stream.url.pathExtension.lowercased()
        if ext == "m3u8" || ext == "mpd" { return nil }
        var request = URLRequest(url: stream.url)
        for (name, value) in stream.headers { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        let size = try? await withDeadline(timeout) { @Sendable () async throws -> Int64? in
            let (_, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { return nil }
            switch http.statusCode {
            case 206:
                return (http.value(forHTTPHeaderField: "Content-Range")?.split(separator: "/").last)
                    .flatMap { Int64($0.trimmingCharacters(in: .whitespaces)) }
            case 200:
                return http.expectedContentLength > 0 ? http.expectedContentLength : nil
            default:
                return nil
            }
        }
        return (size ?? nil).flatMap { $0 > 0 ? $0 : nil }
    }

    /// Whether `bytes` of `format` can't hold `expectedSec` of audio, give or take `slackSec`.
    /// Measured at the lowest bitrate such a stream plausibly runs at, so a real copy is never
    /// refused for an optimistic bitrate claim.
    static func tooShort(bytes: Int64, format: StreamFormat, expectedSec: Int, slackSec: Int) -> Bool {
        guard bytes > 0, expectedSec > 0 else { return false }
        let floorKbps = format.isLossless == true
            ? losslessFloorKbps
            : min(format.kbps.flatMap { $0 > 0 ? $0 : nil } ?? lossyFloorKbps, lossyFloorKbps)
        let mostSec = Double(bytes) * 8 / (Double(floorKbps) * 1_000)
        return mostSec < Double(expectedSec - slackSec)
    }
}
