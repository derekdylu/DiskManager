import Darwin
import XCTest
@testable import DiskManagerCore

final class SyncEngineTests: XCTestCase {
    var sourceRoot: URL!
    var destRoot: URL!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("dm-sync-\(UUID().uuidString)")
        sourceRoot = base.appendingPathComponent("A")
        destRoot = base.appendingPathComponent("B")
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: sourceRoot.deletingLastPathComponent())
    }

    private func write(_ rel: String, _ content: String, under root: URL) throws {
        let url = root.appendingPathComponent(rel)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.data(using: .utf8)!.write(to: url)
    }

    private func read(_ rel: String, under root: URL) throws -> String {
        try String(contentsOf: root.appendingPathComponent(rel), encoding: .utf8)
    }

    private func runSync(policy: OrphanPolicy = .archive) throws -> (SyncPlan, SyncResult) {
        let plan = Differ.diff(
            source: try TreeScanner.scan(root: sourceRoot),
            dest: try TreeScanner.scan(root: destRoot))
        let result = SyncEngine.execute(
            plan: plan, sourceRoot: sourceRoot, destRoot: destRoot,
            orphanPolicy: policy, cancel: CancelFlag(), progress: { _ in })
        return (plan, result)
    }

    func testInitialMirrorIntoEmptyDestination() throws {
        try write("file1.txt", "hello", under: sourceRoot)
        try write("dir/nested.bin", String(repeating: "x", count: 100_000), under: sourceRoot)
        try FileManager.default.createDirectory(
            at: sourceRoot.appendingPathComponent("empty-dir"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: sourceRoot.appendingPathComponent("link").path,
            withDestinationPath: "file1.txt")

        // Give file1 a past modification time to verify it is preserved after copying
        let oldDate = Date(timeIntervalSinceNow: -100_000)
        try FileManager.default.setAttributes(
            [.modificationDate: oldDate],
            ofItemAtPath: sourceRoot.appendingPathComponent("file1.txt").path)

        let (plan, result) = try runSync()

        XCTAssertEqual(plan.copies.count, 3)  // file1, nested.bin, link
        XCTAssertEqual(plan.dirCreates.count, 2)  // dir, empty-dir
        XCTAssertEqual(result.copied, 3)
        XCTAssertEqual(result.dirsCreated, 2)
        XCTAssertTrue(result.failures.isEmpty, "\(result.failures)")
        XCTAssertFalse(result.wasCancelled)

        XCTAssertEqual(try read("file1.txt", under: destRoot), "hello")
        XCTAssertEqual(
            try read("dir/nested.bin", under: destRoot),
            String(repeating: "x", count: 100_000))
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(
                atPath: destRoot.appendingPathComponent("link").path),
            "file1.txt")

        // Modification time preserved (2-second tolerance)
        let destMtime = try FileManager.default.attributesOfItem(
            atPath: destRoot.appendingPathComponent("file1.txt").path)[.modificationDate] as! Date
        XCTAssertLessThan(abs(destMtime.timeIntervalSince(oldDate)), 2.0)

        // Scanning again should show both sides fully in sync
        let (planAfter, _) = try runSync()
        XCTAssertTrue(planAfter.isEmpty, "同步後重新比對應為空計畫")
    }

    func testUpdateOrphanAndArchive() throws {
        // Initial state: both sides identical
        try write("file1.txt", "hello", under: sourceRoot)
        try write("dir/nested.bin", "data-v1", under: sourceRoot)
        _ = try runSync()

        // Changes on A: file1 content modified, entire dir deleted
        try write("file1.txt", "hello world!", under: sourceRoot)
        try FileManager.default.removeItem(at: sourceRoot.appendingPathComponent("dir"))
        // B has an extra file that A does not
        try write("extra.txt", "only-on-B", under: destRoot)

        let (plan, result) = try runSync(policy: .archive)

        XCTAssertEqual(plan.updates.count, 1)
        XCTAssertEqual(plan.orphans.map(\.relativePath).sorted(), ["dir", "extra.txt"])
        XCTAssertEqual(result.updated, 1)
        XCTAssertEqual(result.orphansHandled, 2)
        XCTAssertTrue(result.failures.isEmpty, "\(result.failures)")

        XCTAssertEqual(try read("file1.txt", under: destRoot), "hello world!")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: destRoot.appendingPathComponent("dir").path))

        // Moved-away files must be fully present in the archive folder
        let archiveFolder = try XCTUnwrap(result.archiveFolder)
        XCTAssertEqual(
            try read("\(archiveFolder)/dir/nested.bin", under: destRoot), "data-v1")
        XCTAssertEqual(
            try read("\(archiveFolder)/extra.txt", under: destRoot), "only-on-B")

        // Re-diffing after sync should be empty (the archive folder is excluded from scanning)
        let (planAfter, _) = try runSync()
        XCTAssertTrue(planAfter.isEmpty)
    }

    func testKeepPolicyLeavesOrphansAlone() throws {
        try write("common.txt", "same", under: sourceRoot)
        try write("common.txt", "same", under: destRoot)
        // Make mtime identical on both sides
        let date = Date(timeIntervalSinceNow: -5000)
        for root in [sourceRoot!, destRoot!] {
            try FileManager.default.setAttributes(
                [.modificationDate: date],
                ofItemAtPath: root.appendingPathComponent("common.txt").path)
        }
        try write("extra.txt", "precious", under: destRoot)

        let (plan, result) = try runSync(policy: .keep)

        XCTAssertEqual(plan.orphans.count, 1)
        XCTAssertEqual(result.orphansHandled, 0)
        XCTAssertEqual(try read("extra.txt", under: destRoot), "precious")
        XCTAssertNil(result.archiveFolder)
    }

    func testTypeConflictFileReplacesDirectory() throws {
        // A: thing is a file; B: thing is a directory with contents
        try write("thing", "i-am-a-file", under: sourceRoot)
        try write("thing/child.txt", "old-child", under: destRoot)

        let (plan, result) = try runSync(policy: .archive)

        XCTAssertTrue(plan.updates.contains { $0.reason == .typeConflict })
        XCTAssertTrue(result.failures.isEmpty, "\(result.failures)")
        XCTAssertEqual(try read("thing", under: destRoot), "i-am-a-file")

        // The old directory's contents are archived, not lost
        let archiveFolder = try XCTUnwrap(result.archiveFolder)
        XCTAssertEqual(
            try read("\(archiveFolder)/thing/child.txt", under: destRoot), "old-child")
    }

    func testTypeConflictDirectoryReplacesFile() throws {
        // A: thing is a directory (containing a file); B: thing is a file
        try write("thing/new-child.txt", "new-child", under: sourceRoot)
        try write("thing", "i-was-a-file", under: destRoot)

        let (plan, result) = try runSync(policy: .archive)

        XCTAssertTrue(plan.updates.contains { $0.reason == .typeConflict })
        XCTAssertTrue(result.failures.isEmpty, "\(result.failures)")
        XCTAssertEqual(try read("thing/new-child.txt", under: destRoot), "new-child")

        let archiveFolder = try XCTUnwrap(result.archiveFolder)
        XCTAssertEqual(
            try read("\(archiveFolder)/thing", under: destRoot), "i-was-a-file")
    }

    func testArchiveReplacedKeepsOldVersionOnOverwrite() throws {
        // Union mode: archive the old version before overwriting
        try write("doc.txt", "NEW", under: sourceRoot)
        try write("doc.txt", "OLD-VERSION", under: destRoot)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -50_000)],
            ofItemAtPath: destRoot.appendingPathComponent("doc.txt").path)

        let plan = Differ.diff(
            source: try TreeScanner.scan(root: sourceRoot),
            dest: try TreeScanner.scan(root: destRoot))
        XCTAssertEqual(plan.updates.count, 1)

        let result = SyncEngine.execute(
            plan: plan, sourceRoot: sourceRoot, destRoot: destRoot,
            orphanPolicy: .keep, archiveReplaced: true,
            cancel: CancelFlag(), progress: { _ in })

        XCTAssertTrue(result.failures.isEmpty, "\(result.failures)")
        XCTAssertEqual(try read("doc.txt", under: destRoot), "NEW")
        let archiveFolder = try XCTUnwrap(result.archiveFolder)
        XCTAssertEqual(try read("\(archiveFolder)/doc.txt", under: destRoot), "OLD-VERSION")
    }

    func testCancellationStopsEarly() throws {
        for i in 0..<50 {
            try write("file\(i).txt", "content-\(i)", under: sourceRoot)
        }
        let plan = Differ.diff(
            source: try TreeScanner.scan(root: sourceRoot),
            dest: try TreeScanner.scan(root: destRoot))
        let flag = CancelFlag()
        flag.cancel()  // Cancel before starting
        let result = SyncEngine.execute(
            plan: plan, sourceRoot: sourceRoot, destRoot: destRoot,
            orphanPolicy: .archive, cancel: flag, progress: { _ in })
        XCTAssertTrue(result.wasCancelled)
        XCTAssertEqual(result.copied, 0)
    }

    func testImmutableFileCopiesAndCanLaterBeReplaced() throws {
        let source = sourceRoot.appendingPathComponent("locked.jpg")
        let destination = destRoot.appendingPathComponent("locked.jpg")
        defer {
            _ = Darwin.chflags(source.path, 0)
            _ = Darwin.chflags(destination.path, 0)
        }

        try write("locked.jpg", "version-one", under: sourceRoot)
        XCTAssertEqual(Darwin.chflags(source.path, UInt32(UF_IMMUTABLE)), 0)

        let (_, initialResult) = try runSync()

        XCTAssertTrue(initialResult.failures.isEmpty, "\(initialResult.failures)")
        XCTAssertEqual(try read("locked.jpg", under: destRoot), "version-one")
        XCTAssertNotEqual((fileFlags(atPath: destination.path) ?? 0) & UInt32(UF_IMMUTABLE), 0)

        // The next sync must be able to replace the destination file that kept the locked flag last time.
        XCTAssertEqual(Darwin.chflags(source.path, 0), 0)
        try write("locked.jpg", "version-two-is-newer", under: sourceRoot)
        let (_, updateResult) = try runSync()

        XCTAssertTrue(updateResult.failures.isEmpty, "\(updateResult.failures)")
        XCTAssertEqual(try read("locked.jpg", under: destRoot), "version-two-is-newer")
        XCTAssertEqual((fileFlags(atPath: destination.path) ?? 0) & UInt32(UF_IMMUTABLE), 0)

        let leftovers = try FileManager.default.contentsOfDirectory(atPath: destRoot.path)
        XCTAssertFalse(leftovers.contains { $0.hasPrefix(".dmtmp-") })
    }
}
