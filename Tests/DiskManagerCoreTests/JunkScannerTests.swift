import Darwin
import XCTest
@testable import DiskManagerCore

final class JunkScannerTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dm-junk-\(UUID().uuidString)")
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

    private var smallDupOptions: JunkScanOptions {
        var options = JunkScanOptions()
        options.duplicateMinSize = 16
        return options
    }

    func testFCPCacheDetectedButOriginalMediaProtected() throws {
        try write("MyLib.fcpbundle/Event1/Render Files/r.mov", String(repeating: "r", count: 500))
        try write("MyLib.fcpbundle/Event1/Transcoded Media/Proxy Media/p.mov", String(repeating: "p", count: 300))
        try write("MyLib.fcpbundle/Event1/Original Media/keep.mov", String(repeating: "o", count: 400))
        // A same-named folder outside a library does not count as FCP cache
        try write("NotALibrary/Render Files/normal.txt", "x")

        let report = try JunkScanner.scan(root: root, options: smallDupOptions)
        let fcp = report.items(for: .fcpCache)

        XCTAssertEqual(fcp.count, 2)
        XCTAssertEqual(Set(fcp.map(\.detail)), ["Render Files", "Proxy Media"])
        XCTAssertEqual(report.totalBytes(for: .fcpCache), 800)
        XCTAssertFalse(fcp.contains { $0.relativePath.contains("Original Media") })
        XCTAssertFalse(fcp.contains { $0.relativePath.contains("NotALibrary") })
    }

    func testSystemCruftAndCaches() throws {
        try write("keep.txt", "hello")
        try write(".DS_Store", "junk")
        try write("sub/.DS_Store", "junk")
        try write("sub/._movie.mov", "appledouble")
        try write("photos/.thumbnails/t1.jpg", "thumb")
        try write("LR/MyCatalog Previews.lrdata/preview.db", "prev")
        try write("LR2/MyCatalog Smart Previews.lrdata/sp.db", "smart")

        let report = try JunkScanner.scan(root: root, options: smallDupOptions)

        let cruft = report.items(for: .systemCruft)
        XCTAssertEqual(cruft.count, 3)
        XCTAssertTrue(cruft.contains { $0.detail == "AppleDouble" })

        let caches = report.items(for: .thumbnailCache)
        XCTAssertEqual(
            Set(caches.map(\.relativePath)),
            ["photos/.thumbnails", "LR/MyCatalog Previews.lrdata", "LR2/MyCatalog Smart Previews.lrdata"])
        // detail is a normalized subcategory key without the database name, so the UI can group by subcategory
        let lrDetails = Set(caches.filter { $0.relativePath.hasSuffix(".lrdata") }.map(\.detail))
        XCTAssertEqual(lrDetails, ["Previews.lrdata", "Smart Previews.lrdata"])
        XCTAssertFalse(report.items(for: .systemCruft).contains { $0.relativePath == "keep.txt" })
    }

    func testDiskImagesByExtension() throws {
        try write("backups/sdcard.img", String(repeating: "i", count: 100))
        try write("installers/tool.dmg", String(repeating: "d", count: 50))
        try write("movie.mov", "not an image")

        let report = try JunkScanner.scan(root: root, options: smallDupOptions)
        let images = report.items(for: .diskImages)
        XCTAssertEqual(Set(images.map(\.relativePath)), ["backups/sdcard.img", "installers/tool.dmg"])
    }

    func testDuplicateDetection() throws {
        let payload = String(repeating: "same-content-", count: 10)   // > 16 bytes
        try write("one/a.bin", payload)
        try write("two/deeper/b.bin", payload)
        try write("different.bin", String(repeating: "other-stuff-", count: 10))
        try write("small.bin", "tiny")   // Below threshold, not compared

        let report = try JunkScanner.scan(root: root, options: smallDupOptions)

        XCTAssertEqual(report.duplicateGroups.count, 1)
        let group = try XCTUnwrap(report.duplicateGroups.first)
        XCTAssertEqual(Set(group.files.map(\.relativePath)), ["one/a.bin", "two/deeper/b.bin"])
        XCTAssertEqual(group.wastedBytes, Int64(payload.utf8.count))
    }

    func testSimilarFoldersDetectedAtEightyPercent() throws {
        for index in 1...4 {
            let payload = "shared-\(index)-" + String(repeating: Character("x"), count: index * 7)
            try write("Album A/file\(index).bin", payload)
            try write("Album B/renamed\(index).bin", payload)
        }
        try write("Album A/only-a.bin", "unique-on-a")
        try write("Album B/only-b.bin", "unique-on-b-with-different-size")

        var options = JunkScanOptions()
        options.categories = [.similarFolders]
        options.similarFolderMinFiles = 5
        options.similarFolderThreshold = 0.8
        let report = try JunkScanner.scan(root: root, options: options)

        let group = try XCTUnwrap(report.similarFolderGroups.first {
            Set([$0.first.relativePath, $0.second.relativePath]) == ["Album A", "Album B"]
        })
        XCTAssertEqual(group.matchingFiles, 4)
        XCTAssertEqual(group.firstFileCount, 5)
        XCTAssertEqual(group.secondFileCount, 5)
        XCTAssertEqual(group.similarity, 0.8, accuracy: 0.000_001)
    }

    func testSimilarFoldersBelowThresholdAreNotReported() throws {
        for index in 1...3 {
            try write("A/shared\(index).bin", "shared-\(index)")
            try write("B/shared\(index).bin", "shared-\(index)")
        }
        try write("A/a4.bin", "a-four")
        try write("A/a5.bin", "a-five")
        try write("B/b4.bin", "b-four-and-different")
        try write("B/b5.bin", "b-five-and-different")

        var options = JunkScanOptions()
        options.categories = [.similarFolders]
        options.similarFolderMinFiles = 5
        options.similarFolderThreshold = 0.8
        let report = try JunkScanner.scan(root: root, options: options)

        XCTAssertTrue(report.similarFolderGroups.isEmpty)
    }

    func testSimilarFolderScanNeverPairsParentWithChild() throws {
        for index in 1...5 {
            let payload = "same-content-\(index)"
            try write("Parent/Child/f\(index).bin", payload)
            try write("Other/f\(index).bin", payload)
        }

        var options = JunkScanOptions()
        options.categories = [.similarFolders]
        let report = try JunkScanner.scan(root: root, options: options)

        XCTAssertFalse(report.similarFolderGroups.contains {
            Set([$0.first.relativePath, $0.second.relativePath]) == ["Parent", "Parent/Child"]
        })
    }

    func testDuplicateExportIncludesFileAndFolderGroups() throws {
        for index in 1...5 {
            let payload = "export-shared-\(index)"
            try write("Folder A/file\(index).bin", payload)
            try write("Folder B/copy\(index).bin", payload)
        }
        var options = JunkScanOptions()
        options.duplicateMinSize = 1
        let report = try JunkScanner.scan(root: root, options: options)

        let exported = JunkReportExporter.duplicateTSV(
            report: report, rootPath: "/Volumes/Test\tDrive",
            exportedAt: Date(timeIntervalSince1970: 0))

        XCTAssertTrue(exported.contains("type\tgroup\titem\trole"))
        XCTAssertTrue(exported.contains("duplicate_file\t1\t1\tnewest"))
        XCTAssertTrue(exported.contains("similar_folder\t1\t1\tfirst\t1.000000"))
        XCTAssertTrue(exported.contains("Folder A"))
        XCTAssertTrue(exported.contains("Folder B"))
        XCTAssertTrue(exported.contains("# root\t/Volumes/Test Drive"), "TSV control characters should be sanitized")
    }

    func testSkipsArchiveAndTrash() throws {
        try write("\(SyncEngine.archiveRootName)/old/.DS_Store", "junk")
        try write(".Trashes/501/deleted.dmg", "junk")

        let report = try JunkScanner.scan(root: root, options: smallDupOptions)
        XCTAssertTrue(report.items(for: .systemCruft).isEmpty)
        XCTAssertTrue(report.items(for: .diskImages).isEmpty)
    }

    func testRemovalDeletesAndReportsFreedBytes() throws {
        try write(".DS_Store", "1234")
        try write("sub/.DS_Store", "5678")
        let report = try JunkScanner.scan(root: root, options: smallDupOptions)
        let targets = report.items(for: .systemCruft).map { ($0.relativePath, $0.size) }

        let result = JunkEngine.remove(
            paths: targets, root: root, method: .delete, cancel: CancelFlag())

        XCTAssertEqual(result.deletedCount, 2)
        XCTAssertEqual(result.freedBytes, 8)
        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".DS_Store").path))

        let after = report.removingPaths(Set(result.deletedPaths))
        XCTAssertTrue(after.items(for: .systemCruft).isEmpty)
    }

    func testRemovalCollapsesSelectedFolderAndItsChild() throws {
        try write("folder/child.txt", "1234")

        let result = JunkEngine.remove(
            paths: [("folder", 4), ("folder/child.txt", 4)],
            root: root, method: .delete, cancel: CancelFlag())

        XCTAssertEqual(result.deletedCount, 1)
        XCTAssertEqual(result.freedBytes, 4)
        XCTAssertEqual(result.deletedPaths, ["folder"])
        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("folder").path))
    }

    func testFindsAndRemovesLockedDiskManagerTemporaryFile() throws {
        let rel = "photos/.dmtmp-12AB34CD"
        let url = root.appendingPathComponent(rel)
        defer { _ = Darwin.chflags(url.path, 0) }
        try write(rel, "incomplete")
        XCTAssertEqual(Darwin.chflags(url.path, UInt32(UF_IMMUTABLE)), 0)

        let report = try JunkScanner.scan(root: root, options: smallDupOptions)
        let item = try XCTUnwrap(report.items(for: .systemCruft).first {
            $0.relativePath == rel
        })
        XCTAssertEqual(item.detail, "DiskManager temporary file")

        let result = JunkEngine.remove(
            paths: [(item.relativePath, item.size)], root: root,
            method: .delete, cancel: CancelFlag())

        XCTAssertEqual(result.deletedCount, 1)
        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
}
