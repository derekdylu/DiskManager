import XCTest
@testable import DiskManagerCore

final class RateMeterTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    func testNoRateBeforeOneSecondOfSamples() {
        var meter = RateMeter()
        meter.reset(0, at: t0)
        XCTAssertEqual(meter.record(500, at: t0.addingTimeInterval(0.5)), 0)
    }

    func testRateUsesOverallAverageThenSlidingWindow() {
        var meter = RateMeter()
        meter.reset(0, at: t0)
        XCTAssertEqual(meter.record(1000, at: t0.addingTimeInterval(2)), 500, accuracy: 0.01)
        // Speed drops: after 20 s the window (10 s) only sees the slow part
        for second in 3...20 {
            _ = meter.record(1000 + Int64(second - 2) * 10, at: t0.addingTimeInterval(Double(second)))
        }
        let rate = meter.record(1190, at: t0.addingTimeInterval(21))
        XCTAssertEqual(rate, 10, accuracy: 0.01)
    }

    func testRecordWithoutResetStartsMeter() {
        var meter = RateMeter()
        XCTAssertEqual(meter.record(100, at: t0), 0)
        XCTAssertEqual(meter.record(300, at: t0.addingTimeInterval(2)), 100, accuracy: 0.01)
    }
}
