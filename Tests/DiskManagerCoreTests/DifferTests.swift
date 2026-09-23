import XCTest
@testable import DiskManagerCore

final class DifferTests: XCTestCase {
    private func makeResult(_ items: [FileEntry]) -> ScanResult {
        var result = ScanResult()
        items.forEach { result.add($0) }
        return result
    }

    private func file(_ path: String, size: Int64 = 1, mtime: TimeInterval = 1000) -> FileEntry {
        FileEntry(relativePath: path, kind: .file, size: size, modified: Date(timeIntervalSince1970: mtime))
    }

    private func dir(_ path: String) -> FileEntry {
        FileEntry(relativePath: path, kind: .directory, size: 0, modified: .distantPast)
    }

    func testNewFilesAndDirs() {
        let source = makeResult([file("a.txt", size: 5), dir("sub"), file("sub/b.txt", size: 3)])
        let dest = makeResult([])
        let plan = Differ.diff(source: source, dest: dest)

        XCTAssertEqual(plan.copies.map(\.relativePath), ["a.txt", "sub/b.txt"])
        XCTAssertEqual(plan.dirCreates, ["sub"])
        XCTAssertEqual(plan.updates.count, 0)
        XCTAssertEqual(plan.orphans.count, 0)
        XCTAssertEqual(plan.bytesToCopy, 8)
    }

    func testIdenticalTreesAreEmptyPlan() {
        let items = [file("a.txt", size: 5, mtime: 1000), dir("sub"), file("sub/b.txt", size: 3, mtime: 500)]
        let plan = Differ.diff(source: makeResult(items), dest: makeResult(items))
        XCTAssertTrue(plan.isEmpty)
    }

    func testMtimeToleranceForFATFilesystems() {
        let source = makeResult([file("a.txt", size: 5, mtime: 1000)])
        let within = Differ.diff(source: source, dest: makeResult([file("a.txt", size: 5, mtime: 1001.5)]))
        XCTAssertTrue(within.isEmpty, "2 秒以內的時間差不應觸發更新")

        let beyond = Differ.diff(source: source, dest: makeResult([file("a.txt", size: 5, mtime: 1005)]))
        XCTAssertEqual(beyond.updates.count, 1)
        XCTAssertEqual(beyond.updates.first?.reason, .timeChanged)
    }

    func testSizeChangeWins() {
        let plan = Differ.diff(
            source: makeResult([file("a.txt", size: 9, mtime: 1000)]),
            dest: makeResult([file("a.txt", size: 5, mtime: 1000)]))
        XCTAssertEqual(plan.updates.first?.reason, .sizeChanged)
        XCTAssertEqual(plan.bytesToCopy, 9)
    }

    func testOrphansReportTopmostOnly() throws {
        let source = makeResult([file("keep.txt")])
        let dest = makeResult([
            file("keep.txt"),
            dir("extra"), file("extra/one.txt", size: 10), file("extra/two.txt", size: 20),
            file("lonely.txt", size: 7),
        ])
        let plan = Differ.diff(source: source, dest: dest)

        XCTAssertEqual(plan.orphans.map(\.relativePath), ["extra", "lonely.txt"])
        XCTAssertEqual(plan.orphanBytes, 37)

        // An orphan directory must aggregate the size of all files beneath it
        let extraDir = try XCTUnwrap(plan.orphans.first { $0.relativePath == "extra" })
        XCTAssertEqual(extraDir.size, 30)
    }

    func testDifferenceOnlyNeverCopiesOrOverwrites() {
        let reference = makeResult([
            file("shared.txt", size: 5, mtime: 1000),
            file("reference-only.txt", size: 3),
        ])
        let target = makeResult([
            file("shared.txt", size: 9, mtime: 2000),
            dir("target-only"), file("target-only/a.txt", size: 7),
        ])

        let plan = Differ.differenceOnly(reference: reference, target: target)

        XCTAssertEqual(plan.orphans.map(\.relativePath), ["target-only"])
        XCTAssertEqual(plan.orphanBytes, 7)
        XCTAssertTrue(plan.copies.isEmpty)
        XCTAssertTrue(plan.updates.isEmpty)
        XCTAssertTrue(plan.dirCreates.isEmpty)
        XCTAssertEqual(plan.bytesToCopy, 0)
    }

    func testTypeConflict() {
        let plan = Differ.diff(
            source: makeResult([file("thing", size: 4)]),
            dest: makeResult([dir("thing")]))
        XCTAssertEqual(plan.updates.count, 1)
        XCTAssertEqual(plan.updates.first?.reason, .typeConflict)
    }

    func testSymlinkTargetChange() {
        let source = makeResult([FileEntry(relativePath: "link", kind: .symlink(target: "new"), size: 0, modified: .distantPast)])
        let dest = makeResult([FileEntry(relativePath: "link", kind: .symlink(target: "old"), size: 0, modified: .distantPast)])
        let plan = Differ.diff(source: source, dest: dest)
        XCTAssertEqual(plan.updates.first?.reason, .linkChanged)
    }

    func testUnicodeNormalizationDoesNotCauseFalseDiff() {
        let nfc = "café.txt"                    // é = U+00E9
        let nfd = "cafe\u{0301}.txt"            // e + U+0301
        XCTAssertNotEqual(Array(nfc.utf8), Array(nfd.utf8), "兩種形式的位元組應不同")
        let plan = Differ.diff(
            source: makeResult([file(nfc, size: 5, mtime: 1000)]),
            dest: makeResult([file(nfd, size: 5, mtime: 1000)]))
        XCTAssertTrue(plan.isEmpty, "同名檔案僅 Unicode 正規化不同時，不應視為差異")
    }
}
