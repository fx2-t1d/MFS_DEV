import SwiftUI

/// A meal locked into the log, with the numbers shown when it was logged. Entries are never edited.
/// Later steps (bolus, basal changes) attach to the entry; nothing is sent to a pump from here.
struct DoseLogEntry: Identifiable, Codable, Equatable {
    struct Item: Codable, Equatable {
        var name: String
        var servings: Double
        var carbs: Double?
        var protein: Double?
        var fat: Double?
        var fiber: Double?
    }

    var id = UUID()
    var loggedAt: Date
    var mealTime: Date
    var mealName: String
    var items: [Item]
    var carbs: Double?
    var protein: Double?
    var fat: Double?
    var fiber: Double?
    var photoFile: String?
    var glucoseMgdl: Double?
    var profileName: String
    var dosingMode: String
    var recommendedBolus: Double?
    var recommendedBasalUnitsPerHour: Double?
    var recommendedBasalMinutes: Int?
    var formula: DoseFormula
    var status = "Logged"
}

final class DoseLogStore: ObservableObject {
    @Published private(set) var entries: [DoseLogEntry] = []
    @Published private(set) var lastLoggedMealID: UUID?

    private let directory: URL
    private var file: URL { directory.appendingPathComponent("entries.json") }

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("dose-log", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode([DoseLogEntry].self, from: data) {
            entries = saved
        }
    }

    func photoURL(_ entry: DoseLogEntry) -> URL? { entry.photoFile.map { directory.appendingPathComponent($0) } }

    @discardableResult
    func log(meal: AcceptedMeal, mealTime: Date, glucose: Double?, profileName: String,
             recommendation: DoseRecommendation, formula: DoseFormula) -> DoseLogEntry {
        let food = meal.combined
        var entry = DoseLogEntry(
            loggedAt: Date(), mealTime: mealTime, mealName: food.product.name,
            items: meal.items.map { .init(name: $0.product.name, servings: $0.servings, carbs: $0.totalCarbohydrates,
                                          protein: $0.totalProtein, fat: $0.totalFat, fiber: $0.totalFiber) },
            carbs: food.totalCarbohydrates, protein: food.totalProtein, fat: food.totalFat, fiber: food.totalFiber,
            glucoseMgdl: glucose, profileName: profileName, dosingMode: recommendation.mode.label,
            recommendedBolus: recommendation.bolusUnits,
            recommendedBasalUnitsPerHour: recommendation.enhancedBasalUnitsPerHour,
            recommendedBasalMinutes: recommendation.enhancedBasalMinutes, formula: formula)
        if let jpeg = meal.photoJPEG {
            let name = "\(entry.id.uuidString).jpg"
            if (try? jpeg.write(to: directory.appendingPathComponent(name), options: .atomic)) != nil { entry.photoFile = name }
        }
        entries.insert(entry, at: 0)
        lastLoggedMealID = meal.id
        if let data = try? JSONEncoder().encode(entries) { try? data.write(to: file, options: .atomic) }
        DiagnosticsLog.shared.record("DoseLog", "Logged \(entry.mealName): \(entry.carbs ?? 0) c, \(entry.protein ?? 0) p, \(entry.fat ?? 0) g fat")
        return entry
    }
}

struct DoseLogView: View {
    @EnvironmentObject private var log: DoseLogStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if log.entries.isEmpty {
                    Text("Nothing logged yet. Accept a meal and tap Log dose in Manage.").foregroundStyle(.secondary)
                }
                ForEach(log.entries) { entry in
                    NavigationLink { DoseLogDetail(entry: entry) } label: {
                        VStack(alignment: .leading) {
                            Text(entry.mealName).lineLimit(1)
                            Text("\(entry.loggedAt.formatted(date: .abbreviated, time: .shortened)) · \(entry.status)")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Dose log")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
    }
}

private struct DoseLogDetail: View {
    @EnvironmentObject private var log: DoseLogStore
    let entry: DoseLogEntry

    private func value(_ number: Double?, _ unit: String) -> String {
        number.map { "\($0.formatted(.number.precision(.fractionLength(0...1)))) \(unit)" } ?? "—"
    }

    var body: some View {
        List {
            Section("Meal") {
                if let url = log.photoURL(entry), let image = UIImage(contentsOfFile: url.path) {
                    Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 180)
                }
                ForEach(Array(entry.items.enumerated()), id: \.offset) { _, item in
                    LabeledContent(item.name, value: "\(item.servings.formatted()) × \(value(item.carbs.map { $0 / max(item.servings, 0.0001) }, "c"))")
                }
                LabeledContent("Eaten", value: entry.mealTime.formatted(date: .abbreviated, time: .shortened))
                LabeledContent("Carbs", value: value(entry.carbs, "c"))
                LabeledContent("Fiber", value: value(entry.fiber, "g"))
                LabeledContent("Protein", value: value(entry.protein, "p"))
                LabeledContent("Fat", value: value(entry.fat, "g"))
            }
            Section("At the time") {
                LabeledContent("Glucose", value: value(entry.glucoseMgdl, "mg/dl"))
                LabeledContent("Profile", value: entry.profileName)
                LabeledContent("Dosing tab", value: entry.dosingMode)
                LabeledContent("Bolus shown", value: value(entry.recommendedBolus, "u"))
                LabeledContent("Enhanced basal shown", value: value(entry.recommendedBasalUnitsPerHour, "u/h"))
                LabeledContent("Enhanced for", value: entry.recommendedBasalMinutes.map { "\($0) min" } ?? "—")
            }
            Section {
                LabeledContent("Status", value: entry.status)
            } footer: {
                Text("Locked. Recorded numbers are what was shown; no insulin was sent from this app.")
            }
        }
        .navigationTitle(entry.mealName)
        .navigationBarTitleDisplayMode(.inline)
    }
}
