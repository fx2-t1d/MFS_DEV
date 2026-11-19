import Foundation
import Vision

enum NutritionField: Hashable, Identifiable, CaseIterable {
    case carbohydrates, protein, totalFat, calories, saturatedFat, transFat, cholesterol, sodium
    case fiber, totalSugars, addedSugars
    case vitaminD, calcium, iron, potassium, salt

    var id: Self { self }

    var label: String {
        switch self {
        case .calories: return "Calories"
        case .totalFat: return "Total Fat"
        case .saturatedFat: return "Saturated Fat"
        case .transFat: return "Trans Fat"
        case .cholesterol: return "Cholesterol"
        case .sodium: return "Sodium"
        case .carbohydrates: return "Total Carbohydrate"
        case .fiber: return "Dietary Fiber"
        case .totalSugars: return "Total Sugars"
        case .addedSugars: return "Added Sugars"
        case .protein: return "Protein"
        case .vitaminD: return "Vitamin D"
        case .calcium: return "Calcium"
        case .iron: return "Iron"
        case .potassium: return "Potassium"
        case .salt: return "Salt"
        }
    }

    var apiNutrient: String {
        switch self {
        case .calories: return "energy-kcal"
        case .totalFat: return "fat"
        case .saturatedFat: return "saturated-fat"
        case .transFat: return "trans-fat"
        case .cholesterol: return "cholesterol"
        case .sodium: return "sodium"
        case .carbohydrates: return "carbohydrates"
        case .fiber: return "fiber"
        case .totalSugars: return "sugars"
        case .addedSugars: return "added-sugars"
        case .protein: return "proteins"
        case .vitaminD: return "vitamin-d"
        case .calcium: return "calcium"
        case .iron: return "iron"
        case .potassium: return "potassium"
        case .salt: return "salt"
        }
    }

    var unit: String {
        switch self {
        case .calories: return "kcal"
        case .cholesterol, .calcium, .iron, .potassium: return "mg"
        case .vitaminD: return "µg"
        default: return "g"
        }
    }
}

struct OpenFoodFactsProduct {
    let barcode: String
    let name: String
    let brands: String?
    let servingSize: String?
    let nutritionValues: [NutritionField: String]
    // Original OFF numeric values, before display rounding; mass nutrients are in grams.
    var nutrientsPer100g: [NutritionField: Double] = [:]
    var packageQuantity: Double? = nil
    var packageUnit: String? = nil
    var servingQuantity: Double? = nil
    var servingUnit: String? = nil

    var nutritionPerServing: [NutritionField: String] {
        nutrition(for: servingQuantity, unit: servingUnit)
    }

    var nutritionPerPackage: [NutritionField: String] {
        nutrition(for: packageQuantity, unit: packageUnit)
    }

    private func nutrition(for quantity: Double?, unit: String?) -> [NutritionField: String] {
        guard let quantity, quantity.isFinite, quantity > 0,
              unit == "g" || unit == "ml" else { return [:] }
        // OFF _100g values use a 100 ml basis for volume-based products.
        var result: [NutritionField: String] = [:]
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.maximumFractionDigits = 2
        for (field, value) in nutrientsPer100g {
            let scaled = value * quantity / 100
            guard scaled.isFinite, scaled >= 0 else { continue }
            // OFF mass nutrient values are grams, independently of display units.
            let display = scaled * (field.unit == "mg" ? 1000 : field.unit == "µg" ? 1_000_000 : 1)
            guard let number = formatter.string(from: NSNumber(value: display)) else { continue }
            result[field] = "\(number) \(field.unit)"
        }
        return result
    }

    var servingsInPackage: Double? {
        guard let packageQuantity, let servingQuantity,
              packageQuantity.isFinite, servingQuantity.isFinite,
              packageQuantity > 0, servingQuantity > 0,
              let packageUnit, ["g", "ml"].contains(packageUnit),
              packageUnit == servingUnit else { return nil }
        let count = packageQuantity / servingQuantity
        return count.isFinite && count > 0 ? count : nil
    }
}

struct OpenFoodFactsClient {
    var session: URLSession = .shared

    func product(for barcode: String) async throws -> OpenFoodFactsProduct? {
        var components = URLComponents(string: "https://world.openfoodfacts.org/api/v3/product/\(barcode)")
        components?.queryItems = [
            URLQueryItem(name: "fields", value: "code,product_name,brands,serving_size,serving_quantity,serving_quantity_unit,product_quantity,product_quantity_unit,nutriments")
        ]
        guard let url = components?.url else { throw OpenFoodFactsError.invalidURL }

        var request = URLRequest(url: url)
        request.setValue("MFS iOS/1.0 (https://world.openfoodfacts.org/)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw OpenFoodFactsError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else {
            if response.statusCode == 404 { return nil }
            throw OpenFoodFactsError.server(response.statusCode)
        }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let product = root["product"] as? [String: Any] else {
            return nil
        }

        let nutriments = product["nutriments"] as? [String: Any] ?? [:]
        var values: [NutritionField: String] = [:]
        var numericValues: [NutritionField: Double] = [:]
        for field in NutritionField.allCases {
            let key = "\(field.apiNutrient)_100g"
            guard let number = numericValue(nutriments[key]) else { continue }
            numericValues[field] = number
            values[field] = "\(formatted(number * (field.unit == "mg" ? 1000 : field.unit == "µg" ? 1_000_000 : 1))) \(field.unit)"
        }

        return OpenFoodFactsProduct(
            barcode: (product["code"] as? String) ?? barcode,
            name: (product["product_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "Food product",
            brands: (product["brands"] as? String)?.nilIfEmpty,
            servingSize: (product["serving_size"] as? String)?.nilIfEmpty,
            nutritionValues: values,
            nutrientsPer100g: numericValues,
            packageQuantity: numericValue(product["product_quantity"]),
            packageUnit: product["product_quantity_unit"] as? String,
            servingQuantity: numericValue(product["serving_quantity"]),
            servingUnit: product["serving_quantity_unit"] as? String
        )
    }

    private func numericValue(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }

    private func formatted(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 2
        formatter.minimumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

enum NutritionBarcodeScanner {
    static func barcode(in capturedImage: Data) throws -> String? {
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.ean13, .ean8, .upce, .code128]
        try VNImageRequestHandler(data: capturedImage).perform([request])
        return request.results?
            .sorted { $0.boundingBox.midY > $1.boundingBox.midY }
            .compactMap(\.payloadStringValue)
            .first
    }

    static func lookupProduct(
        fromCapturedImage data: Data,
        using client: OpenFoodFactsClient,
        barcodeDetector: (Data) throws -> String? = { try barcode(in: $0) }
    ) async throws -> OpenFoodFactsProduct? {
        guard let code = try barcodeDetector(data) else { throw OpenFoodFactsError.barcodeNotFound }
        return try await client.product(for: code)
    }
}

enum OpenFoodFactsError: LocalizedError {
    case invalidURL
    case invalidResponse
    case barcodeNotFound
    case server(Int)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Could not create the Open Food Facts request."
        case .invalidResponse: return "Open Food Facts returned an invalid response."
        case .barcodeNotFound: return "No barcode detected. Center the barcode and try again."
        case .server(let status): return "Open Food Facts is unavailable (HTTP \(status)). Try again."
        }
    }
}


// Local fragments of Tidepool's published Nutrition schema, not upload records.
struct TidepoolNutrition: Encodable {
    struct Grams: Encodable {
        let total: Double
        let units = "grams"
    }
    struct Energy: Encodable {
        let value: Double
        let units = "kilocalories"
    }
    struct Carbohydrate: Encodable {
        let net: Double
        let total: Double?
        let dietaryFiber: Double?
        let sugars: Double?
        let units = "grams"
    }
    var energy: Energy?
    var fat: Grams?
    var protein: Grams?
    var carbohydrate: Carbohydrate?
}

enum TidepoolCarbohydrateBasis {
    case unverified
    case totalMinusHalfFiber
    // Caller must verify that OFF carbohydrates means total, including fiber,
    // and supply the user-edited net grams per 100 g.
    case confirmedTotalAndNet(netPer100g: Double)
}

struct TidepoolNutritionMapping {
    let nutrition: TidepoolNutrition
    let consumedGrams: Double
    let issues: [String]
}

enum TidepoolNutritionMappingError: Error {
    case invalidConsumedGrams
}

enum TidepoolNutritionMapper {
    static func map(
        _ product: OpenFoodFactsProduct,
        consumedGrams: Double,
        carbohydrateBasis: TidepoolCarbohydrateBasis = .totalMinusHalfFiber
    ) throws -> TidepoolNutritionMapping {
        guard consumedGrams.isFinite, consumedGrams > 0 else {
            throw TidepoolNutritionMappingError.invalidConsumedGrams
        }
        var issues: [String] = []
        let scale = consumedGrams / 100
        func scaled(_ value: Double?, label: String, maximum: Double) -> Double? {
            guard let value else { return nil }
            let result = value * scale
            guard value.isFinite, value >= 0, result.isFinite, result <= maximum else {
                issues.append("\(label) omitted: invalid value or Tidepool range exceeded.")
                return nil
            }
            return result
        }
        func nutrient(_ field: NutritionField, maximum: Double = 1000) -> Double? {
            scaled(product.nutrientsPer100g[field], label: field.label, maximum: maximum)
        }
        var nutrition = TidepoolNutrition()
        nutrition.energy = nutrient(.calories, maximum: 10000).map { .init(value: $0) }
        nutrition.fat = nutrient(.totalFat).map { .init(total: $0) }
        nutrition.protein = nutrient(.protein).map { .init(total: $0) }
        switch carbohydrateBasis {
        case .unverified:
            issues.append("Carbohydrates omitted: confirm total-carbohydrate basis and net grams per 100 g.")
        case .totalMinusHalfFiber:
            if let total = nutrient(.carbohydrates), let fiber = nutrient(.fiber), fiber <= total {
                nutrition.carbohydrate = .init(net: total - fiber / 2, total: total,
                    dietaryFiber: fiber, sugars: nutrient(.totalSugars))
            } else {
                issues.append("Carbohydrates omitted: total and fiber are required for the net estimate; provide a user override.")
            }
        case .confirmedTotalAndNet(let netPer100g):
            if let net = scaled(netPer100g, label: "Net carbohydrate", maximum: 1000) {
                let total = nutrient(.carbohydrates)
                if let total, net > total {
                    issues.append("Carbohydrates omitted: confirmed net exceeds total.")
                } else {
                    nutrition.carbohydrate = .init(net: net, total: total,
                        dietaryFiber: nutrient(.fiber), sugars: nutrient(.totalSugars))
                }
            }
        }
        let supported: Set<NutritionField> = [.calories, .totalFat, .protein, .carbohydrates, .fiber, .totalSugars]
        for field in NutritionField.allCases where !supported.contains(field) {
            if product.nutrientsPer100g[field] != nil || product.nutritionValues[field] != nil {
                issues.append("\(field.label) retained locally: no dedicated Tidepool Nutrition field.")
            }
        }
        if product.nutrientsPer100g.isEmpty {
            issues.append("No numeric source values; formatted display strings are not parsed.")
        }
        return .init(nutrition: nutrition, consumedGrams: consumedGrams, issues: issues)
    }
}

struct AcceptedFood: Identifiable {
    let id = UUID()
    let product: OpenFoodFactsProduct
    let servings: Double
    var photoJPEG: Data? = nil
    let acceptedAt = Date()

    var totalCarbohydrates: Double? {
        guard let quantity = product.servingQuantity, quantity.isFinite, quantity > 0,
              product.servingUnit == "g" || product.servingUnit == "ml",
              servings.isFinite, servings > 0,
              let total = product.nutrientsPer100g[.carbohydrates], total.isFinite, total >= 0 else { return nil }
        let result = total * quantity / 100 * servings
        return result.isFinite ? result : nil
    }

    var totalProtein: Double? { consumedAmount(of: .protein) }

    var totalFiber: Double? { consumedAmount(of: .fiber) }

    var totalFat: Double? { consumedAmount(of: .totalFat) }

    private func consumedAmount(of nutrient: NutritionField) -> Double? {
        guard let quantity = product.servingQuantity, quantity.isFinite, quantity > 0,
              product.servingUnit == "g" || product.servingUnit == "ml",
              servings.isFinite, servings > 0,
              let per100g = product.nutrientsPer100g[nutrient], per100g.isFinite, per100g >= 0 else { return nil }
        let result = per100g * quantity / 100 * servings
        return result.isFinite ? result : nil
    }

    var netCarbohydrates: Double? {
        guard let quantity = product.servingQuantity, quantity.isFinite, quantity > 0,
              product.servingUnit == "g" || product.servingUnit == "ml",
              servings.isFinite, servings > 0,
              let total = product.nutrientsPer100g[.carbohydrates],
              let fiber = product.nutrientsPer100g[.fiber],
              total.isFinite, fiber.isFinite, total >= 0, fiber >= 0, fiber <= total else { return nil }
        let result = (total - fiber / 2) * quantity / 100 * servings
        return result.isFinite ? result : nil
    }
}

/// One accepted record made of several foods plus an optional photo. Later actions use the whole record.
struct AcceptedMeal: Identifiable {
    let items: [AcceptedFood]
    let photoJPEG: Data?
    /// The whole meal as a single 100 g "serving", so entered totals are the record's totals.
    let combined: AcceptedFood

    var id: UUID { combined.id }

    init(items: [AcceptedFood], photoJPEG: Data? = nil) {
        self.items = items
        self.photoJPEG = photoJPEG
        if items.count == 1, var only = items.first {
            only.photoJPEG = photoJPEG ?? only.photoJPEG
            combined = only
            return
        }
        var totals: [NutritionField: Double] = [:]
        for item in items {
            guard let quantity = item.product.servingQuantity, quantity.isFinite, quantity > 0,
                  item.product.servingUnit == "g" || item.product.servingUnit == "ml",
                  item.servings.isFinite, item.servings > 0 else { continue }
            for (field, per100g) in item.product.nutrientsPer100g where per100g.isFinite && per100g >= 0 {
                totals[field, default: 0] += per100g * quantity / 100 * item.servings
            }
        }
        let product = OpenFoodFactsProduct(
            barcode: "", name: items.map(\.product.name).joined(separator: ", "), brands: nil,
            servingSize: "whole meal", nutritionValues: [:], nutrientsPer100g: totals,
            servingQuantity: 100, servingUnit: "g")
        combined = AcceptedFood(product: product, servings: 1, photoJPEG: photoJPEG)
    }
}

/// Local extension boundary. Contains no credentials, endpoint, or networking.
struct TidepoolPreparedFood {
    let acceptedFoodID: UUID
    let nutritionJSON: Data?
    let issues: [String]

    init(food: AcceptedFood) {
        acceptedFoodID = food.id
        guard food.product.servingUnit == "g", let serving = food.product.servingQuantity,
              serving.isFinite, serving > 0 else {
            nutritionJSON = nil
            issues = ["A serving size in grams is required by the current local Tidepool mapper."]
            return
        }
        do {
            let mapped = try TidepoolNutritionMapper.map(food.product, consumedGrams: serving * food.servings)
            nutritionJSON = try JSONEncoder().encode(mapped.nutrition)
            issues = mapped.issues
        } catch {
            nutritionJSON = nil
            issues = ["Unable to prepare nutrition: invalid consumed amount or encoding failure."]
        }
    }
}
