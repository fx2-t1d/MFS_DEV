import XCTest
@testable import MFS

@MainActor
final class RecordDatabaseTests: XCTestCase {
    private func meal(barcode: String = "", photo: Data? = nil) -> AcceptedMeal {
        let product = OpenFoodFactsProduct(
            barcode: barcode, name: "Rice", brands: nil, servingSize: "whole meal", nutritionValues: [:],
            nutrientsPer100g: [.carbohydrates: 45, .protein: 4, .totalFat: 1], servingQuantity: 100, servingUnit: "g")
        return AcceptedMeal(items: [AcceptedFood(product: product, servings: 1)], photoJPEG: photo)
    }

    private let snapshot = DosingSnapshot(glucoseMgdl: 140, profileName: "Main", dosingMode: "Simple", recommendedBolusUnits: 3,
                                          enhancedBasalUnitsPerHour: nil, enhancedBasalMinutes: nil, formula: DoseFormula())

    func testLoggingStoresFoodEntryItemsPhotoAndDecisionUnderOneGroup() throws {
        let db = try RecordDatabase(inMemory: true)
        let meal = meal(photo: Data([1, 2, 3]))
        let group = try db.logMeal(meal, mealTime: Date(), dosing: snapshot)

        XCTAssertEqual(group, meal.id)
        XCTAssertEqual(Set(try db.records(inGroup: group).compactMap(\.type)), [.food, .dosingDecision])
        let entry = try XCTUnwrap(db.foodEntry(group: group))
        XCTAssertEqual(entry.method, .table)
        XCTAssertEqual(entry.photo, Data([1, 2, 3]))
        XCTAssertEqual(entry.items.count, 1)
        XCTAssertEqual(try XCTUnwrap(entry.carbs), 45, accuracy: 0.001)
    }

    func testMethodIsBarcodeWhenAnItemWasScanned() throws {
        let db = try RecordDatabase(inMemory: true)
        let group = try db.logMeal(meal(barcode: "123"), mealTime: Date(), dosing: nil)
        XCTAssertEqual(try db.foodEntry(group: group)?.method, .barcode)
    }

    func testLoggingTheSameMealTwiceStoresItOnce() throws {
        let db = try RecordDatabase(inMemory: true)
        let meal = meal()
        try db.logMeal(meal, mealTime: Date(), dosing: snapshot)
        try db.logMeal(meal, mealTime: Date(), dosing: snapshot)
        XCTAssertEqual(try db.records(of: .food).count, 1)
        XCTAssertEqual(try db.records(of: .dosingDecision).count, 1)
    }

    func testAnyTidepoolTypeCanBeStoredAndUploadStateTracked() throws {
        let db = try RecordDatabase(inMemory: true)
        let now = Date()
        for type in TidepoolDataType.allCases {
            try db.add(type, time: now, origin: "test", datum: ["type": type.rawValue], state: .pending)
        }
        let pending = try db.pendingUpload()
        XCTAssertEqual(pending.count, TidepoolDataType.allCases.count)
        try db.markUploaded(Array(pending.prefix(3)))
        try db.markFailed([pending[3]], error: "offline")
        XCTAssertEqual(try db.pendingUpload().count, TidepoolDataType.allCases.count - 3)
        XCTAssertEqual(pending[3].lastError, "offline")
    }

    func testSimilarMealsRankBySharedTags() throws {
        let db = try RecordDatabase(inMemory: true)
        func log(_ name: String, tags: [String]) throws -> UUID {
            let product = OpenFoodFactsProduct(barcode: "", name: name, brands: nil, servingSize: "whole meal", nutritionValues: [:],
                                               nutrientsPer100g: [.carbohydrates: 10, .protein: 10], servingQuantity: 100, servingUnit: "g")
            let group = try db.logMeal(AcceptedMeal(items: [AcceptedFood(product: product, servings: 1)]), mealTime: Date(), dosing: nil)
            for tag in tags { try db.addTag(tag, to: group) }
            return group
        }
        let plate = try log("Plate", tags: ["Chicken", "green beans", "bacon"])
        _ = try log("Chicken and beans", tags: ["chicken", " Green Beans "])
        _ = try log("Pasta", tags: ["pasta"])
        _ = try log("Chicken only", tags: ["chicken", "rice", "salad", "soup"])

        let matches = try db.similarMeals(to: plate)
        XCTAssertEqual(matches.map(\.entry.name), ["Chicken and beans", "Chicken only"])
        XCTAssertEqual(matches[0].score, 2.0 / 3.0, accuracy: 0.001)
        XCTAssertEqual(matches[0].sharedTags, ["chicken", "green beans"])
        XCTAssertEqual(try db.tags(for: plate).count, 3)
        try db.addTag("CHICKEN", to: plate)
        XCTAssertEqual(try db.tags(for: plate).count, 3)
    }
}
