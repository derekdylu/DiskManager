import XCTest
@testable import DiskManagerCore

final class UnionDifferTests: XCTestCase {
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

    func testFillsBothDirections() {
        let a = makeResult([file("onlyA.txt", size: 5), dir("dirA"), file("dirA/x.txt", size: 2)])
        let b = makeResult([file("onlyB.txt", size: 7)])
        let union = Differ.unionDiff(a: a, b: b)

        XCTAssertEqual(union.aToB.copies.map(\.relativePath), ["dirA/x.txt", "onlyA.txt"])
        XCTAssertEqual(union.aToB.dirCreates, ["dirA"])
        XCTAssertEqual(union.aToB.bytesToCopy, 7)
        XCTAssertEqual(union.bToA.copies.map(\.relativePath), ["onlyB.txt"])
        XCTAssertEqual(union.bToA.bytesToCopy, 7)
        XCTAssertTrue(union.unresolved.isEmpty)
        XCTAssertTrue(union.aToB.orphans.isEmpty)
        XCTAssertTrue(union.bToA.orphans.isEmpty)
    }

    func testNewerSideWinsConflicts() {
        let a = makeResult([file("both.txt", size: 10, mtime: 2000)])   // A is newer
        let b = makeResult([file("both.txt", size: 8, mtime: 1000)])
        let union = Differ.unionDiff(a: a, b: b)

        XCTAssertEqual(union.aToB.updates.count, 1)
        XCTAssertEqual(union.aToB.updates.first?.relativePath, "both.txt")
        XCTAssertTrue(union.bToA.updates.isEmpty)

        let reversed = Differ.unionDiff(a: b, b: a)   // Swap sides: B is newer
        XCTAssertTrue(reversed.aToB.updates.isEmpty)
        XCTAssertEqual(reversed.bToA.updates.count, 1)
    }

    func testIdenticalFilesUntouched() {
        let items = [file("same.txt", size: 5, mtime: 1000)]
        let union = Differ.unionDiff(a: makeResult(items), b: makeResult(items))
        XCTAssertTrue(union.aToB.isEmpty)
        XCTAssertTrue(union.bToA.isEmpty)
        XCTAssertTrue(union.unresolved.isEmpty)
    }

    func testAmbiguousConflictIsUnresolved() {
        // Different sizes but modification times within tolerance: cannot tell which is newer
        let a = makeResult([file("weird.txt", size: 10, mtime: 1000)])
        let b = makeResult([file("weird.txt", size: 8, mtime: 1001)])
        let union = Differ.unionDiff(a: a, b: b)

        XCTAssertEqual(union.unresolved.count, 1)
        XCTAssertEqual(union.unresolved.first?.kind, .ambiguous)
        XCTAssertTrue(union.aToB.updates.isEmpty)
        XCTAssertTrue(union.bToA.updates.isEmpty)
    }

    func testTypeMismatchBlocksDescendants() {
        // x is a directory (containing a file) on A but a file on B -> conflict, and the directory contents must not be copied
        let a = makeResult([dir("x"), file("x/inner.txt", size: 3), file("free.txt", size: 1)])
        let b = makeResult([file("x", size: 9)])
        let union = Differ.unionDiff(a: a, b: b)

        XCTAssertEqual(union.unresolved.count, 1)
        XCTAssertEqual(union.unresolved.first?.kind, .typeMismatch)
        XCTAssertEqual(union.aToB.copies.map(\.relativePath), ["free.txt"])
        XCTAssertTrue(union.aToB.dirCreates.isEmpty)
        XCTAssertEqual(union.aToB.bytesToCopy, 1)
    }

    func testSymlinkTargetMismatchIsUnresolved() {
        let a = makeResult([FileEntry(relativePath: "link", kind: .symlink(target: "p"), size: 0, modified: .distantPast)])
        let b = makeResult([FileEntry(relativePath: "link", kind: .symlink(target: "q"), size: 0, modified: .distantPast)])
        let union = Differ.unionDiff(a: a, b: b)
        XCTAssertEqual(union.unresolved.first?.kind, .linkMismatch)
    }

    func testCaseOnlyPathDifferenceMatchesOnCaseInsensitiveVolumes() {
        var a = ScanResult(caseSensitiveNames: false)
        a.add(dir("Chinese Poll"))
        a.add(FileEntry(
            relativePath: "Chinese Poll/clip.mov",
            kind: .symlink(target: "/Movies/clip.mov"), size: 0, modified: .distantPast))

        var b = ScanResult(caseSensitiveNames: false)
        b.add(dir("Chinese poll"))
        b.add(FileEntry(
            relativePath: "Chinese poll/clip.mov",
            kind: .symlink(target: "/Movies/clip.mov"), size: 0, modified: .distantPast))

        let union = Differ.unionDiff(a: a, b: b)

        XCTAssertTrue(union.aToB.isEmpty)
        XCTAssertTrue(union.bToA.isEmpty)
        XCTAssertTrue(union.unresolved.isEmpty)
    }

    func testCaseOnlyPathDifferenceRemainsDistinctOnCaseSensitiveVolumes() {
        var a = ScanResult(caseSensitiveNames: true)
        a.add(dir("Chinese Poll"))
        var b = ScanResult(caseSensitiveNames: true)
        b.add(dir("Chinese poll"))

        let union = Differ.unionDiff(a: a, b: b)

        XCTAssertEqual(union.aToB.dirCreates, ["Chinese Poll"])
        XCTAssertEqual(union.bToA.dirCreates, ["Chinese poll"])
    }
}
