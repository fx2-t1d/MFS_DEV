import SwiftData
import SwiftUI

struct DoseLogView: View {
    @Query(sort: \FoodEntry.loggedAt, order: .reverse) private var entries: [FoodEntry]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if entries.isEmpty {
                    Text("Nothing logged yet. Accept a meal and tap Log dose in Manage.").foregroundStyle(.secondary)
                }
                ForEach(entries) { entry in
                    NavigationLink { DoseLogDetail(entry: entry) } label: {
                        VStack(alignment: .leading) {
                            Text(entry.name).lineLimit(1)
                            Text("\(entry.loggedAt.formatted(date: .abbreviated, time: .shortened)) · \(entry.method.rawValue)")
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
    @EnvironmentObject private var database: RecordDatabase
    @Query private var tags: [TagAssignment]
    @State private var newTag = ""
    let entry: FoodEntry

    init(entry: FoodEntry) {
        self.entry = entry
        let group = entry.groupID
        _tags = Query(filter: #Predicate<TagAssignment> { $0.groupID == group }, sort: \.createdAt)
    }

    private func value(_ number: Double?, _ unit: String) -> String {
        number.map { "\($0.formatted(.number.precision(.fractionLength(0...1)))) \(unit)" } ?? "—"
    }

    private var snapshot: DosingSnapshot? {
        let group = entry.groupID
        guard let record = (try? database.records(inGroup: group))?.first(where: { $0.type == .dosingDecision }),
              let object = (try? JSONSerialization.jsonObject(with: record.payload)) as? [String: Any],
              let body = object["mfsSnapshot"],
              let data = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        return try? JSONDecoder().decode(DosingSnapshot.self, from: data)
    }

    private func addTag() {
        try? database.addTag(newTag, to: entry.groupID)
        newTag = ""
    }

    var body: some View {
        let snapshot = snapshot
        List {
            Section("Meal") {
                if let photo = entry.photo, let image = UIImage(data: photo) {
                    Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 180)
                }
                ForEach(entry.items, id: \.persistentModelID) { item in
                    LabeledContent(item.name, value: "\(item.servings.formatted()) serving\(item.servings == 1 ? "" : "s")")
                }
                LabeledContent("Entered by", value: entry.method.rawValue)
                LabeledContent("Eaten", value: entry.mealTime.formatted(date: .abbreviated, time: .shortened))
                LabeledContent("Carbs", value: value(entry.carbs, "c"))
                LabeledContent("Fiber", value: value(entry.fiber, "g"))
                LabeledContent("Protein", value: value(entry.protein, "p"))
                LabeledContent("Fat", value: value(entry.fat, "g"))
            }
            if let snapshot {
                Section("At the time") {
                    LabeledContent("Glucose", value: value(snapshot.glucoseMgdl, "mg/dl"))
                    LabeledContent("Profile", value: snapshot.profileName)
                    LabeledContent("Dosing tab", value: snapshot.dosingMode)
                    LabeledContent("Bolus shown", value: value(snapshot.recommendedBolusUnits, "u"))
                    LabeledContent("Enhanced basal shown", value: value(snapshot.enhancedBasalUnitsPerHour, "u/h"))
                    LabeledContent("Enhanced for", value: snapshot.enhancedBasalMinutes.map { "\($0) min" } ?? "—")
                }
            }
            Section("Tags") {
                ForEach(tags) { tag in
                    Text(tag.name)
                        .swipeActions { Button("Remove", role: .destructive) { try? database.removeTag(tag) } }
                }
                HStack {
                    TextField("Add tag, e.g. chicken", text: $newTag).onSubmit(addTag)
                    Button("Add", action: addTag).disabled(newTag.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            let similar = (try? database.similarMeals(to: entry.groupID)) ?? []
            if !similar.isEmpty {
                Section("Similar meals") {
                    ForEach(similar, id: \.entry.groupID) { match in
                        VStack(alignment: .leading) {
                            Text(match.entry.name).lineLimit(1)
                            Text("\(Int(match.score * 100))% · \(match.sharedTags.joined(separator: ", "))")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section {} footer: { Text("Locked. Recorded numbers are what was shown; no insulin was sent from this app.") }
        }
        .navigationTitle(entry.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}
