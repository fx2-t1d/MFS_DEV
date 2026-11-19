import XCTest
@testable import MFS

final class InsulinTableTests: XCTestCase {
    func testTableAndBrandLookup() {
        XCTAssertEqual(InsulinTable.all.count, 10)
        XCTAssertEqual(Set(InsulinTable.all.map(\.id)).count, 10)
        XCTAssertEqual(InsulinTable.profile(forBrand: "novolog")?.category, "Rapid-acting (aspart)")
        XCTAssertEqual(InsulinTable.profile(forBrand: "Apidra")?.category, "Rapid-acting (glulisine)")
        XCTAssertNil(InsulinTable.profile(forBrand: "Nope"))
    }
}
