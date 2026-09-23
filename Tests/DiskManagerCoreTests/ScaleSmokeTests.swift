import XCTest
@testable import DiskManagerCore

/// Scale smoke test: verifies memory does not grow unboundedly when scanning a large number of files.
/// Skipped by default (generates tens of thousands of files, slow); to run it use:
///   DM_SCALE_TEST=1 swift test --filter ScaleSmokeTests
final class ScaleSmokeTests: XCTestCase {
    func testScanMemoryStaysBounded() throws {
        guard ProcessInfo.processInfo.environment["DM_SCALE_TEST"] == "1" else {
            throw XCTSkip("需要 DM_SCALE_TEST=1 才執行")
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dm-scale-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        // 60k regular files + 20k same-size files (forces the duplicate-check phase to fingerprint-hash all of them)
        let fm = FileManager.default
        for dir in 0..<600 {
            let dirURL = root.appendingPathComponent(String(format: "dir%03d", dir))
            try fm.createDirectory(at: dirURL, withIntermediateDirectories: true)
            for file in 0..<100 {
                let data = "content-\(dir)-\(file)-\(String(repeating: "x", count: 40))".data(using: .utf8)!
                try data.write(to: dirURL.appendingPathComponent("f\(file).dat"))
            }
        }
        let dupDir = root.appendingPathComponent("dups")
        try fm.createDirectory(at: dupDir, withIntermediateDirectories: true)
        let dupPayload = Data(repeating: 0xAB, count: 64)
        for i in 0..<20_000 {
            try dupPayload.write(to: dupDir.appendingPathComponent("d\(i).bin"))
        }

        let before = peakRSSMB()

        let scan = try TreeScanner.scan(root: root)
        XCTAssertEqual(scan.fileCount, 80_000)

        var options = JunkScanOptions()
        options.duplicateMinSize = 16
        let report = try JunkScanner.scan(root: root, options: options)
        XCTAssertFalse(report.duplicateGroups.isEmpty)

        let after = peakRSSMB()
        print("[scale] peak RSS before=\(before)MB after=\(after)MB delta=\(after - before)MB")
        // Before the autoreleasepool issue was fixed, the delta here started at several GB
        XCTAssertLessThan(after - before, 1500, "掃描 8 萬個檔案的記憶體增量異常，疑似又出現堆積")
    }

    private func peakRSSMB() -> Int {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Int(usage.ru_maxrss / 1024 / 1024)   // ru_maxrss is in bytes on macOS
    }
}
