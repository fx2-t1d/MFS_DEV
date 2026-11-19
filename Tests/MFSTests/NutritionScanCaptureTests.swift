import Foundation
import XCTest

final class NutritionScanCaptureTests: XCTestCase {
    func testCapturedPhotoLooksUpBarcodeAndFillsNutrition() async throws {
        let fixtureURL = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: "IMG_0270", withExtension: "HEIC"),
            "IMG_0270 must be included as a test bundle resource."
        )
        let capturedImage = try Data(contentsOf: fixtureURL)
        XCTAssertFalse(capturedImage.isEmpty)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OpenFoodFactsStubURLProtocol.self]
        let client = OpenFoodFactsClient(session: URLSession(configuration: configuration))
        let product = try await NutritionBarcodeScanner.lookupProduct(
            fromCapturedImage: capturedImage,
            using: client,
            barcodeDetector: { imageData in
                XCTAssertEqual(imageData, capturedImage)
                return "888849000012"
            }
        )
        let result = try XCTUnwrap(product, "The database stub should return the scanned product.")

        XCTAssertEqual(result.barcode, "888849000012")
        XCTAssertEqual(result.name, "Fixture Snack")
        XCTAssertEqual(result.servingsInPackage, 5)
        XCTAssertEqual(result.nutritionPerServing[.protein], "8.4 g")
        XCTAssertEqual(result.nutritionPerServing[.calories], "168 kcal")
        XCTAssertEqual(result.nutritionPerPackage[.calories], "840 kcal")
        XCTAssertEqual(result.nutritionPerPackage[.protein], "42 g")
        XCTAssertEqual(result.nutrientsPer100g[.protein], 21)
        XCTAssertEqual(result.nutritionValues[.carbohydrates], "22 g")
        XCTAssertEqual(result.nutritionValues[.addedSugars], "0 g")
        XCTAssertEqual(result.nutritionValues[.protein], "21 g")
        XCTAssertEqual(OpenFoodFactsStubURLProtocol.lastRequestedPath, "/api/v3/product/888849000012")
        XCTAssertTrue(OpenFoodFactsStubURLProtocol.lastUserAgent?.contains("MFS iOS/1.0") == true)
    }
}

private final class OpenFoodFactsStubURLProtocol: URLProtocol {
    static var lastRequestedPath: String?
    static var lastUserAgent: String?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        Self.lastRequestedPath = url.path
        Self.lastUserAgent = request.value(forHTTPHeaderField: "User-Agent")
        let barcode = url.lastPathComponent
        let payload: [String: Any] = [
            "status": "success",
            "product": [
                "code": barcode,
                "product_name": "Fixture Snack",
                "brands": "MFS Test Fixture",
                "serving_size": "40 g",
                "serving_quantity": "40",
                "serving_quantity_unit": "g",
                "product_quantity": 200,
                "product_quantity_unit": "g",
                "nutriments": [
                    "energy-kcal_100g": 420.0,
                    "carbohydrates_100g": 22.0,
                    "added-sugars_100g": 0.0,
                    "proteins_100g": 21.0
                ]
            ]
        ]
        let body = try! JSONSerialization.data(withJSONObject: payload)
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class TidepoolNutritionMappingTests: XCTestCase {
    private func product(_ values: [NutritionField: Double]) -> OpenFoodFactsProduct {
        .init(barcode: "123", name: "Sample", brands: nil, servingSize: "40 g",
              nutritionValues: [:], nutrientsPer100g: values)
    }

    func testScalingAndSchemaEncoding() throws {
        let result = try TidepoolNutritionMapper.map(product([
            .calories: 420, .totalFat: 10, .protein: 21,
            .carbohydrates: 22, .fiber: 2, .totalSugars: 0, .sodium: 0.5
        ]), consumedGrams: 40, carbohydrateBasis: .confirmedTotalAndNet(netPer100g: 20))
        XCTAssertEqual(result.nutrition.energy?.value, 168)
        XCTAssertEqual(result.nutrition.protein?.total, 8.4)
        XCTAssertEqual(result.nutrition.fat?.total, 4)
        XCTAssertEqual(result.nutrition.carbohydrate?.net, 8)
        XCTAssertEqual(result.nutrition.carbohydrate?.dietaryFiber, 0.8)
        XCTAssertEqual(result.nutrition.carbohydrate?.sugars, 0)
        XCTAssertTrue(result.issues.contains { $0.contains("Sodium") })
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(result.nutrition)) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["energy", "fat", "protein", "carbohydrate"])
        XCTAssertEqual((json["energy"] as? [String: Any])?["units"] as? String, "kilocalories")
        XCTAssertEqual((json["carbohydrate"] as? [String: Any])?["units"] as? String, "grams")
    }

    func testDefaultNetEstimateAndUserOverride() throws {
        let food = product([.carbohydrates: 22, .fiber: 4])
        let estimated = try TidepoolNutritionMapper.map(food, consumedGrams: 50)
        XCTAssertEqual(estimated.nutrition.carbohydrate?.net, 10)
        let edited = try TidepoolNutritionMapper.map(food, consumedGrams: 50,
            carbohydrateBasis: .confirmedTotalAndNet(netPer100g: 18))
        XCTAssertEqual(edited.nutrition.carbohydrate?.net, 9)
        let unknown = try TidepoolNutritionMapper.map(food, consumedGrams: 50, carbohydrateBasis: .unverified)
        XCTAssertNil(unknown.nutrition.carbohydrate)
    }

    func testUnknownCarbsMissingValuesAndZero() throws {
        let result = try TidepoolNutritionMapper.map(product([.carbohydrates: 22, .protein: 0]), consumedGrams: 100)
        XCTAssertNil(result.nutrition.carbohydrate)
        XCTAssertNil(result.nutrition.fat)
        XCTAssertEqual(result.nutrition.protein?.total, 0)
    }

    func testInvalidInputsAndSchemaLimits() throws {
        for amount in [0.0, -1, Double.nan, Double.infinity] {
            XCTAssertThrowsError(try TidepoolNutritionMapper.map(product([:]), consumedGrams: amount))
        }
        let result = try TidepoolNutritionMapper.map(product([
            .protein: .nan, .totalFat: -1, .calories: 10001, .carbohydrates: 10
        ]), consumedGrams: 100, carbohydrateBasis: .confirmedTotalAndNet(netPer100g: 11))
        XCTAssertNil(result.nutrition.energy)
        XCTAssertNil(result.nutrition.fat)
        XCTAssertNil(result.nutrition.protein)
        XCTAssertNil(result.nutrition.carbohydrate)
        let boundary = try TidepoolNutritionMapper.map(product([.protein: 1000, .calories: 10000]), consumedGrams: 100)
        XCTAssertEqual(boundary.nutrition.protein?.total, 1000)
        XCTAssertEqual(boundary.nutrition.energy?.value, 10000)
        let overflow = try TidepoolNutritionMapper.map(product([.protein: 1000]), consumedGrams: 101)
        XCTAssertNil(overflow.nutrition.protein)
    }
}

final class PackageServingsTests: XCTestCase {
    func testPackageDefaultsRequireCompatiblePositiveQuantities() {
        var product = OpenFoodFactsProduct(barcode: "1", name: "Food", brands: nil,
            servingSize: nil, nutritionValues: [:])
        XCTAssertNil(product.servingsInPackage)
        XCTAssertTrue(product.nutritionPerServing.isEmpty)
        XCTAssertTrue(product.nutritionPerPackage.isEmpty)
        product.nutrientsPer100g = [.protein: 10, .calcium: 0.12]
        product.packageQuantity = 250
        product.servingQuantity = 100
        product.packageUnit = "g"
        product.servingUnit = "g"
        XCTAssertEqual(product.servingsInPackage, 2.5)
        XCTAssertEqual(product.nutritionPerServing[.protein], "10 g")
        XCTAssertEqual(product.nutritionPerPackage[.protein], "25 g")
        XCTAssertEqual(product.nutritionPerPackage[.calcium], "300 mg")
        product.servingUnit = "ml"
        XCTAssertNil(product.servingsInPackage)
        product.packageUnit = "ml"
        XCTAssertEqual(product.servingsInPackage, 2.5)
        for invalid in [0.0, -1, Double.nan, Double.infinity] {
            product.servingQuantity = invalid
            XCTAssertNil(product.servingsInPackage)
        }
    }
}

final class AcceptedFoodTests: XCTestCase {
    func testSelectedServingsTotalNetAndLocalPreparation() throws {
        let product = OpenFoodFactsProduct(barcode: "123", name: "Snack", brands: nil,
            servingSize: "40 g", nutritionValues: [:],
            nutrientsPer100g: [.carbohydrates: 60, .fiber: 10],
            servingQuantity: 40, servingUnit: "g")
        let accepted = AcceptedFood(product: product, servings: 2.5)
        XCTAssertEqual(accepted.totalCarbohydrates, 60)
        XCTAssertEqual(accepted.netCarbohydrates, 55)
        let draft = TidepoolPreparedFood(food: accepted)
        XCTAssertEqual(draft.acceptedFoodID, accepted.id)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(draft.nutritionJSON)) as? [String: Any])
        let carbs = try XCTUnwrap(json["carbohydrate"] as? [String: Any])
        XCTAssertEqual(carbs["total"] as? Double, 60)
        XCTAssertEqual(carbs["net"] as? Double, 55)
    }

    func testMissingFiberDoesNotBlockTotalAndVolumeDoesNotBecomeGrams() {
        let product = OpenFoodFactsProduct(barcode: "123", name: "Drink", brands: nil,
            servingSize: "100 ml", nutritionValues: [:],
            nutrientsPer100g: [.carbohydrates: 12], servingQuantity: 100, servingUnit: "ml")
        let food = AcceptedFood(product: product, servings: 2)
        XCTAssertEqual(food.totalCarbohydrates, 24)
        XCTAssertNil(food.netCarbohydrates)
        XCTAssertNil(TidepoolPreparedFood(food: food).nutritionJSON)
    }

    func testMealCombinesRowsAndPhotoIntoOneRecord() {
        func food(_ name: String, carbs: Double, protein: Double, servings: Double) -> AcceptedFood {
            AcceptedFood(product: OpenFoodFactsProduct(barcode: "", name: name, brands: nil, servingSize: "serving",
                nutritionValues: [:], nutrientsPer100g: [.carbohydrates: carbs, .protein: protein],
                servingQuantity: 100, servingUnit: "g"), servings: servings)
        }
        let photo = Data([1, 2, 3])
        let meal = AcceptedMeal(items: [food("Rice", carbs: 30, protein: 3, servings: 2), food("Egg", carbs: 1, protein: 6, servings: 1)], photoJPEG: photo)
        XCTAssertEqual(meal.combined.totalCarbohydrates, 61)
        XCTAssertEqual(meal.combined.totalProtein, 12)
        XCTAssertEqual(meal.combined.product.name, "Rice, Egg")
        XCTAssertEqual(meal.combined.photoJPEG, photo)
    }
}
