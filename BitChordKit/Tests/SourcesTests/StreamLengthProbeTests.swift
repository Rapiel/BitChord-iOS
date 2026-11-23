import XCTest
import BitChordCore
@testable import Sources

/// Android StreamLengthProbeTest (94250cce): a file too small to hold the row's runtime is a preview.
final class StreamLengthProbeTests: XCTestCase {
    private let mp3 = StreamFormat(codec: "mp3", kbps: 128)
    private let flac = StreamFormat(codec: "flac")

    func testAThirtySecondPreviewUnderAThreeMinuteRowIsShort() {
        XCTAssertTrue(StreamLengthProbe.tooShort(bytes: 480_000, format: mp3, expectedSec: 180, slackSec: 5))
    }

    func testTheFullSongAtALowBitrateIsKept() {
        XCTAssertFalse(StreamLengthProbe.tooShort(bytes: 2_160_000, format: StreamFormat(codec: "aac", kbps: 96), expectedSec: 180, slackSec: 5))
    }

    func testALosslessPreviewIsShortAndTheFullFileIsKept() {
        XCTAssertTrue(StreamLengthProbe.tooShort(bytes: 3_400_000, format: flac, expectedSec: 180, slackSec: 5))
        XCTAssertFalse(StreamLengthProbe.tooShort(bytes: 20_000_000, format: flac, expectedSec: 180, slackSec: 5))
    }

    func testNothingToMeasureIsNeverShort() {
        XCTAssertFalse(StreamLengthProbe.tooShort(bytes: 0, format: mp3, expectedSec: 180, slackSec: 5))
        XCTAssertFalse(StreamLengthProbe.tooShort(bytes: 480_000, format: mp3, expectedSec: 0, slackSec: 5))
    }
}
