import XCTest
@testable import DiskManagerCore

final class TreeScannerTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dm-scan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ rel: String, _ content: String) throws {
        let url = root.appendingPathComponent(rel)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.data(using: .utf8)!.write(to: url)
    }

    func testScanCollectsFilesDirsAndSymlinks() throws {
        try write("a.txt", "hello")
        try write("sub/b.bin", "abc")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("empty"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: root.appendingPathComponent("link").path,
            withDestinationPath: "a.txt")

        let result = try TreeScanner.scan(root: root)

        XCTAssertNotNil(result.entries["a.txt"])
        XCTAssertNotNil(result.entries["sub"])
        XCTAssertNotNil(result.entries["sub/b.bin"])
        XCTAssertNotNil(result.entries["empty"])
        XCTAssertEqual(result.entries["a.txt"]?.size, 5)
        XCTAssertEqual(result.entries["a.txt"]?.kind, .file)
        XCTAssertEqual(result.entries["empty"]?.kind, .directory)
        XCTAssertEqual(result.entries["link"]?.kind, .symlink(target: "a.txt"))
        XCTAssertEqual(result.fileCount, 3)  // a.txt, sub/b.bin, link
        XCTAssertEqual(result.dirCount, 2)
        XCTAssertEqual(result.totalBytes, 8)
    }

    func testScanSkipsSystemNoiseAndArchiveFolder() throws {
        try write("keep.txt", "x")
        try write(".DS_Store", "junk")
        try write("folder/.dmtmp-12AB34CD", "incomplete-copy")
        try write(".Trashes/deleted.txt", "junk")
        try write("\(SyncEngine.archiveRootName)/20250101-000000/old.txt", "junk")

        let result = try TreeScanner.scan(root: root)

        XCTAssertEqual(result.fileCount, 1)
        XCTAssertNotNil(result.entries["keep.txt"])
        XCTAssertNil(result.entries[".DS_Store"])
        XCTAssertNil(result.entries[".Trashes"])
        XCTAssertNil(result.entries[SyncEngine.archiveRootName])
        XCTAssertNil(result.entries["folder/.dmtmp-12AB34CD"])
        XCTAssertFalse(result.entries.keys.contains { $0.contains("deleted.txt") })
        XCTAssertFalse(result.entries.keys.contains { $0.contains("old.txt") })
    }

    func testScanMissingRootThrows() {
        let missing = root.appendingPathComponent("nope")
        XCTAssertThrowsError(try TreeScanner.scan(root: missing))
    }
}
