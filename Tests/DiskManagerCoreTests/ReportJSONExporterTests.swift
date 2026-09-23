import XCTest
@testable import DiskManagerCore

final class ReportJSONExporterTests: XCTestCase {
    private func object(_ json: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    private func item(_ path: String, _ size: Int64, _ reason: PlanItem.Reason) -> PlanItem {
        PlanItem(relativePath: path, destRelativePath: nil, kind: .file, size: size, reason: reason)
    }

    func testPlanJSONListsEveryOperationByDefault() throws {
        var plan = SyncPlan()
        plan.copies = [item("Photos/a.jpg", 10, .new), item("Photos/b.jpg", 30, .new)]
        plan.updates = [item("Docs/c.txt", 5, .sizeChanged)]
        plan.dirCreates = ["Photos"]
        plan.orphans = [item("Old/d.bin", 100, .extraneous)]
        plan.bytesToCopy = 45
        plan.orphanBytes = 100

        let json = try object(ReportJSONExporter.planJSON(
            .init(mode: "mirror", aPath: "/Volumes/A", bPath: "/Volumes/B", toB: plan)))

        XCTAssertEqual(json["kind"] as? String, "sync_plan")
        XCTAssertEqual(json["mode"] as? String, "mirror")
        XCTAssertEqual(json["truncated"] as? Bool, false)
        XCTAssertEqual(json["operations_total"] as? Int, 5)
        XCTAssertEqual((json["operations"] as? [[String: Any]])?.count, 5)
        let role = (json["b"] as? [String: Any])?["role"] as? String
        XCTAssertEqual(role, "working_space_modified")
    }

    func testPlanJSONLimitKeepsLargestItemsButCompleteTotals() throws {
        var plan = SyncPlan()
        plan.copies = (1...50).map { item("Big/file\($0).bin", Int64($0), .new) }
        plan.bytesToCopy = plan.copies.reduce(0) { $0 + $1.size }

        let json = try object(ReportJSONExporter.planJSON(
            .init(mode: "mirror", aPath: "/a", bPath: "/b", toB: plan), itemLimit: 3, pretty: false))

        XCTAssertEqual(json["truncated"] as? Bool, true)
        XCTAssertEqual(json["operations_total"] as? Int, 50)
        let listed = try XCTUnwrap(json["operations"] as? [[String: Any]])
        XCTAssertEqual(listed.compactMap { $0["size_bytes"] as? Int }, [50, 49, 48])
        let folder = try XCTUnwrap((json["folder_totals"] as? [[String: Any]])?.first)
        XCTAssertEqual(folder["top_level_folder"] as? String, "Big")
        XCTAssertEqual(folder["items"] as? Int, 50)
        XCTAssertEqual(folder["size_bytes"] as? Int, 1275)
    }

    func testUnionPlanJSONHasBothDirections() throws {
        var toB = SyncPlan()
        toB.copies = [item("onlyA.txt", 1, .new)]
        var toA = SyncPlan()
        toA.copies = [item("onlyB.txt", 2, .new)]

        let json = try object(ReportJSONExporter.planJSON(
            .init(mode: "union", aPath: "/a", bPath: "/b", toB: toB, toA: toA)))

        let directions = Set((json["operations"] as? [[String: Any]] ?? []).compactMap { $0["direction"] as? String })
        XCTAssertEqual(directions, ["to_a", "to_b"])
        XCTAssertEqual((json["a"] as? [String: Any])?["role"] as? String, "union_member")
    }

    func testJunkJSONIncludesSubcategoryTotalsAndDuplicates() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var report = JunkReport()
        report.categorized[.systemCruft] = [
            JunkItem(relativePath: "a/.DS_Store", size: 6, isDirectory: false, modified: now, detail: ".DS_Store"),
            JunkItem(relativePath: "b/.DS_Store", size: 8, isDirectory: false, modified: now, detail: ".DS_Store"),
        ]
        report.duplicateGroups = [DuplicateGroup(fingerprint: "abc", fileSize: 100, files: [
            JunkItem(relativePath: "x/1.mov", size: 100, isDirectory: false, modified: now, detail: ""),
            JunkItem(relativePath: "y/1.mov", size: 100, isDirectory: false, modified: now, detail: ""),
        ])]

        let json = try object(ReportJSONExporter.junkJSON(report: report, rootPath: "/Volumes/A", itemLimit: 1))

        XCTAssertEqual(json["kind"] as? String, "junk_scan")
        let subtotal = try XCTUnwrap((json["subcategory_totals"] as? [[String: Any]])?.first)
        XCTAssertEqual(subtotal["items"] as? Int, 2)
        XCTAssertEqual(subtotal["size_bytes"] as? Int, 14)
        XCTAssertEqual((json["items"] as? [[String: Any]])?.count, 1)
        let listing = try XCTUnwrap((json["listing"] as? [String: Any])?["items"] as? [String: Any])
        XCTAssertEqual(listing["truncated"] as? Bool, true)
        let group = try XCTUnwrap((json["duplicate_groups"] as? [[String: Any]])?.first)
        XCTAssertEqual(group["wasted_bytes"] as? Int, 100)
    }
}
