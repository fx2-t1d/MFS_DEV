import Foundation
import SwiftData

/// Every `type` in the Tidepool extended data model (fx2-t1d/TidepoolApi_extended, reference/data/models/datatype.v1.yaml).
/// Keep in sync with that file.
enum TidepoolDataType: String, CaseIterable, Codable {
    case alert, basal, biometric, bloodKetone, bolus, cbg, cgmSettings, controllerSettings, controllerStatus
    case deviceEvent, deviceStatus, dosingDecision, food, insulin, physicalActivity, pumpSettings, pumpStatus
    case reportedState, smbg, upload, water, wizard
}

enum RecordState: String, Codable {
    /// Kept on the phone only; no upload mapping exists yet.
    case local
    /// Ready to send once the user confirms an upload.
    case pending, uploaded, failed
}

/// How the food was entered.
enum FoodLogMethod: String, Codable, CaseIterable {
    case barcode, table, photo
}

/// One Tidepool datum of any type. `payload` is the datum's JSON exactly as it would be uploaded, so no type needs its own table;
/// the columns beside it are what the app queries and what tracks upload.
@Model
final class DataRecord {
    @Attribute(.unique) var id: UUID
    var typeRaw: String
    var subType: String?
    var time: Date
    /// Ties together the records of one event, such as a meal and the dosing decision made for it.
    var groupID: UUID?
    /// Who produced it: "mfs", "libre3", "g7", "omnipod", "healthkit", ...
    var origin: String
    var payload: Data
    var stateRaw: String
    var uploadedAt: Date?
    var attempts: Int
    var lastError: String?
    var createdAt: Date

    init(id: UUID = UUID(), type: TidepoolDataType, subType: String? = nil, time: Date, groupID: UUID? = nil,
         origin: String, payload: Data, state: RecordState = .local) {
        self.id = id
        typeRaw = type.rawValue
        self.subType = subType
        self.time = time
        self.groupID = groupID
        self.origin = origin
        self.payload = payload
        stateRaw = state.rawValue
        attempts = 0
        createdAt = Date()
    }

    var type: TidepoolDataType? { TidepoolDataType(rawValue: typeRaw) }
    var state: RecordState {
        get { RecordState(rawValue: stateRaw) ?? .local }
        set { stateRaw = newValue.rawValue }
    }
}

/// The extra information a food datum cannot carry: how it was entered, the picture, and each item.
/// `groupID` equals the `groupID` of its `food` DataRecord.
@Model
final class FoodEntry {
    @Attribute(.unique) var groupID: UUID
    var methodRaw: String
    var name: String
    var loggedAt: Date
    var mealTime: Date
    var carbs: Double?
    var protein: Double?
    var fat: Double?
    var fiber: Double?
    @Attribute(.externalStorage) var photo: Data?
    @Relationship(deleteRule: .cascade, inverse: \FoodItemRecord.entry) var items: [FoodItemRecord] = []

    init(groupID: UUID, method: FoodLogMethod, name: String, loggedAt: Date = Date(), mealTime: Date,
         carbs: Double?, protein: Double?, fat: Double?, fiber: Double?, photo: Data?) {
        self.groupID = groupID
        methodRaw = method.rawValue
        self.name = name
        self.loggedAt = loggedAt
        self.mealTime = mealTime
        self.carbs = carbs
        self.protein = protein
        self.fat = fat
        self.fiber = fiber
        self.photo = photo
    }

    var method: FoodLogMethod { FoodLogMethod(rawValue: methodRaw) ?? .table }
}

@Model
final class FoodItemRecord {
    var name: String
    var barcode: String
    var brand: String?
    var servings: Double
    var servingQuantity: Double?
    var servingUnit: String?
    var carbs: Double?
    var protein: Double?
    var fat: Double?
    var fiber: Double?
    /// Every nutrient the source gave, per 100 g, as JSON keyed by nutrient name.
    var nutrientsPer100g: Data?
    var entry: FoodEntry?

    init(name: String, barcode: String, brand: String?, servings: Double, servingQuantity: Double?, servingUnit: String?,
         carbs: Double?, protein: Double?, fat: Double?, fiber: Double?, nutrientsPer100g: Data?) {
        self.name = name
        self.barcode = barcode
        self.brand = brand
        self.servings = servings
        self.servingQuantity = servingQuantity
        self.servingUnit = servingUnit
        self.carbs = carbs
        self.protein = protein
        self.fat = fat
        self.fiber = fiber
        self.nutrientsPer100g = nutrientsPer100g
    }
}

/// What was shown when a meal was logged. Stored as the payload of a `dosingDecision` record.
struct DosingSnapshot: Codable, Equatable {
    var glucoseMgdl: Double?
    var profileName: String
    var dosingMode: String
    var recommendedBolusUnits: Double?
    var enhancedBasalUnitsPerHour: Double?
    var enhancedBasalMinutes: Int?
    var formula: DoseFormula
}

/// The on-phone database for all record types. It survives app updates; the app never deletes from it.
@MainActor
final class RecordDatabase: ObservableObject {
    let container: ModelContainer
    var context: ModelContext { container.mainContext }

    init(inMemory: Bool = false) throws {
        container = try ModelContainer(for: DataRecord.self, FoodEntry.self, FoodItemRecord.self,
                                       configurations: ModelConfiguration(isStoredInMemoryOnly: inMemory))
    }

    /// Falls back to memory only if the store cannot be opened, so a database problem never stops the app.
    static func openOrFallback() -> RecordDatabase {
        if let database = try? RecordDatabase() { return database }
        DiagnosticsLog.shared.record("Database", "Could not open the record database; using memory only")
        return try! RecordDatabase(inMemory: true)
    }

    @discardableResult
    func add(_ type: TidepoolDataType, subType: String? = nil, time: Date, groupID: UUID? = nil, origin: String,
             datum: [String: Any], state: RecordState = .local) throws -> DataRecord {
        let payload = try JSONSerialization.data(withJSONObject: datum, options: [.sortedKeys])
        let record = DataRecord(type: type, subType: subType, time: time, groupID: groupID, origin: origin, payload: payload, state: state)
        context.insert(record)
        try context.save()
        return record
    }

    func records(of type: TidepoolDataType, from: Date = .distantPast, to: Date = .distantFuture, limit: Int? = nil) throws -> [DataRecord] {
        let raw = type.rawValue
        var descriptor = FetchDescriptor<DataRecord>(
            predicate: #Predicate { $0.typeRaw == raw && $0.time >= from && $0.time <= to },
            sortBy: [SortDescriptor(\.time, order: .reverse)])
        descriptor.fetchLimit = limit
        return try context.fetch(descriptor)
    }

    func records(inGroup group: UUID) throws -> [DataRecord] {
        try context.fetch(FetchDescriptor<DataRecord>(predicate: #Predicate { $0.groupID == group },
                                                      sortBy: [SortDescriptor(\.time)]))
    }

    func pendingUpload(limit: Int = 100) throws -> [DataRecord] {
        let pending = RecordState.pending.rawValue, failed = RecordState.failed.rawValue
        var descriptor = FetchDescriptor<DataRecord>(
            predicate: #Predicate { $0.stateRaw == pending || $0.stateRaw == failed },
            sortBy: [SortDescriptor(\.time)])
        descriptor.fetchLimit = limit
        return try context.fetch(descriptor)
    }

    func markUploaded(_ records: [DataRecord], at date: Date = Date()) throws {
        for record in records {
            record.state = .uploaded
            record.uploadedAt = date
            record.attempts += 1
            record.lastError = nil
        }
        try context.save()
    }

    func markFailed(_ records: [DataRecord], error: String) throws {
        for record in records {
            record.state = .failed
            record.attempts += 1
            record.lastError = error
        }
        try context.save()
    }

    func foodEntry(group: UUID) throws -> FoodEntry? {
        try context.fetch(FetchDescriptor<FoodEntry>(predicate: #Predicate { $0.groupID == group })).first
    }

    /// Stores an accepted meal as a `food` record plus its FoodEntry (method, photo, items), and a `dosingDecision`
    /// record holding what was shown. Returns the group id shared by all three. Re-logging the same meal is a no-op.
    @discardableResult
    func logMeal(_ meal: AcceptedMeal, method: FoodLogMethod? = nil, mealTime: Date, dosing: DosingSnapshot?) throws -> UUID {
        let group = meal.id
        if try foodEntry(group: group) != nil { return group }
        let food = meal.combined
        let method = method ?? (meal.items.contains { !$0.product.barcode.isEmpty } ? .barcode : (meal.items.isEmpty ? .photo : .table))

        var datum: [String: Any] = ["type": TidepoolDataType.food.rawValue, "time": BiometricMapper.timestamp(mealTime), "name": food.product.name]
        var issues: [String] = []
        if let json = TidepoolPreparedFood(food: food).nutritionJSON,
           let nutrition = try? JSONSerialization.jsonObject(with: json) {
            datum["nutrition"] = nutrition
        } else {
            issues = TidepoolPreparedFood(food: food).issues
        }
        let record = try add(.food, time: mealTime, groupID: group, origin: "mfs", datum: datum,
                             state: datum["nutrition"] == nil ? .local : .pending)
        record.lastError = issues.isEmpty ? nil : issues.joined(separator: " ")

        let entry = FoodEntry(groupID: group, method: method, name: food.product.name, mealTime: mealTime,
                              carbs: food.totalCarbohydrates, protein: food.totalProtein, fat: food.totalFat,
                              fiber: food.totalFiber, photo: meal.photoJPEG)
        context.insert(entry)
        for item in meal.items {
            let per100g = Dictionary(uniqueKeysWithValues: item.product.nutrientsPer100g.map { ($0.key.label, $0.value) })
            let row = FoodItemRecord(
                name: item.product.name, barcode: item.product.barcode, brand: item.product.brands, servings: item.servings,
                servingQuantity: item.product.servingQuantity, servingUnit: item.product.servingUnit,
                carbs: item.totalCarbohydrates, protein: item.totalProtein, fat: item.totalFat, fiber: item.totalFiber,
                nutrientsPer100g: try? JSONEncoder().encode(per100g))
            context.insert(row)
            row.entry = entry
        }
        if let dosing {
            let body = try JSONEncoder().encode(dosing)
            let object = (try JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
            try add(.dosingDecision, subType: "mealLog", time: Date(), groupID: group, origin: "mfs",
                    datum: ["type": TidepoolDataType.dosingDecision.rawValue, "time": BiometricMapper.timestamp(Date()), "mfsSnapshot": object])
        }
        try context.save()
        DiagnosticsLog.shared.record("Database", "Logged meal \(food.product.name) via \(method.rawValue)")
        return group
    }
}
