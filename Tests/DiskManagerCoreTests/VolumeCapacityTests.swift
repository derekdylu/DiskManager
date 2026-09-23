import XCTest
@testable import DiskManagerCore

final class VolumeCapacityTests: XCTestCase {
    func testZeroImportantUsageFallsBackToPlain() {
        // Mounted disk image / external drive: ImportantUsage reports 0 despite free space
        XCTAssertEqual(effectiveAvailableCapacity(importantUsage: 0, plain: 20_900_000_000), 20_900_000_000)
    }

    func testMissingImportantUsageFallsBackToPlain() {
        XCTAssertEqual(effectiveAvailableCapacity(importantUsage: nil, plain: 1_000), 1_000)
    }

    func testBootVolumeKeepsLargerImportantUsage() {
        // Boot volume: ImportantUsage includes purgeable space and exceeds the plain figure
        XCTAssertEqual(effectiveAvailableCapacity(importantUsage: 55_000, plain: 20_000), 55_000)
    }

    func testMissingPlainUsesImportantUsage() {
        XCTAssertEqual(effectiveAvailableCapacity(importantUsage: 42, plain: nil), 42)
    }

    func testNegativeValuesClampToZero() {
        XCTAssertEqual(effectiveAvailableCapacity(importantUsage: -5, plain: nil), 0)
    }

    func testBothMissingIsNil() {
        XCTAssertNil(effectiveAvailableCapacity(importantUsage: nil, plain: nil))
    }

    func testReadsRealVolume() throws {
        let capacity = try XCTUnwrap(readVolumeCapacity(at: FileManager.default.temporaryDirectory))
        XCTAssertGreaterThan(try XCTUnwrap(capacity.total), 0)
        XCTAssertGreaterThan(try XCTUnwrap(capacity.available), 0)
    }
}
