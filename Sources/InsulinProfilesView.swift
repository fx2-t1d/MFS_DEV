import SwiftUI

private func timeText(_ minute: Int) -> String {
    let hour = (minute / 60) % 24
    let suffix = hour < 12 ? "am" : "pm"
    let display = hour % 12 == 0 ? 12 : hour % 12
    return minute % 60 == 0 ? "\(display)\(suffix)" : String(format: "%d:%02d%@", display, minute % 60, suffix)
}

struct InsulinProfilesView: View {
    @EnvironmentObject private var store: InsulinProfileStore
    @Environment(\.dismiss) private var dismiss
    @State private var editing: InsulinProfile?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    row(store.main)
                } header: {
                    Text("Main")
                } footer: {
                    Text("Used whenever no alternative profile is selected.")
                }

                Section {
                    ForEach(store.alternatives) { profile in row(profile) }
                        .onDelete { offsets in
                            let ids = offsets.map { store.alternatives[$0].id }
                            ids.forEach(store.delete)
                        }
                    Button("Add alternative profile", systemImage: "plus") {
                        editing = InsulinProfile(name: "", segments: store.main.segments.map {
                            ProfileSegment(startMinute: $0.startMinute, basalUnitsPerHour: $0.basalUnitsPerHour, sensitivityMgdlPerUnit: $0.sensitivityMgdlPerUnit)
                        })
                    }
                } header: {
                    Text("Alternatives")
                } footer: {
                    Text("Event profiles such as Sick are chosen by hand. Selecting one keeps it in effect until you switch back; automatic switching can plug in later.")
                }
            }
            .navigationTitle("Insulin profiles")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
            .sheet(item: $editing) { ProfileEditor(profile: $0) }
        }
    }

    private func row(_ profile: InsulinProfile) -> some View {
        HStack {
            Button { editing = profile } label: {
                VStack(alignment: .leading) {
                    Text(profile.name).foregroundStyle(.primary)
                    Text(profile.segments.isEmpty ? "No time frames yet" : "\(profile.segments.count) time frame(s)")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if store.active.id == profile.id {
                Label("In use", systemImage: "checkmark.circle.fill").labelStyle(.titleAndIcon).font(.footnote).foregroundStyle(.green)
            } else if !profile.isMain, profile.issues.isEmpty {
                Button("Use") { store.activate(profile.id) }.buttonStyle(.bordered)
            }
            if store.active.id == profile.id, !profile.isMain {
                Button("Back to main") { store.activate(nil) }.buttonStyle(.bordered)
            }
        }
    }
}

private struct ProfileEditor: View {
    @EnvironmentObject private var store: InsulinProfileStore
    @Environment(\.dismiss) private var dismiss
    @State var profile: InsulinProfile

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("e.g. Sick", text: $profile.name).disabled(profile.isMain)
                }
                Section {
                    ForEach($profile.segments) { $segment in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                DatePicker("From", selection: startBinding($segment), displayedComponents: .hourAndMinute)
                                Text("to \(timeText(profile.endMinute(of: segment)))").foregroundStyle(.secondary)
                            }
                            HStack {
                                numberField("Basal", value: $segment.basalUnitsPerHour, unit: "U/h")
                                numberField("Sensitivity", value: $segment.sensitivityMgdlPerUnit, unit: "mg/dL per U")
                            }
                        }
                    }
                    .onDelete { profile.segments.remove(atOffsets: $0) }
                    Button("Add time frame", systemImage: "plus") {
                        let used = Set(profile.segments.map(\.startMinute))
                        let start = profile.segments.isEmpty ? 0 : (stride(from: 0, to: 1440, by: 30).first { !used.contains($0) } ?? 0)
                        let last = profile.sortedSegments.last
                        profile.segments.append(ProfileSegment(startMinute: start,
                            basalUnitsPerHour: last?.basalUnitsPerHour ?? 0, sensitivityMgdlPerUnit: last?.sensitivityMgdlPerUnit ?? 50))
                    }
                } header: {
                    Text("Time frames")
                } footer: {
                    Text("Each frame runs until the next one starts; the last wraps past midnight. Basal is units per hour. Sensitivity is how many mg/dL one unit lowers glucose. Enter your own values.")
                }
                if !profile.issues.isEmpty {
                    Section { ForEach(profile.issues, id: \.self) { Text($0).font(.footnote).foregroundStyle(.red) } }
                }
            }
            .navigationTitle(profile.name.isEmpty ? "New profile" : profile.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    // The main profile may stay empty until the user fills it in.
                    Button("Save") { store.save(profile); dismiss() }
                        .disabled(profile.isMain ? !profile.issues.filter { $0 != "Add at least one time frame." }.isEmpty : !profile.issues.isEmpty)
                }
            }
        }
    }

    private func startBinding(_ segment: Binding<ProfileSegment>) -> Binding<Date> {
        Binding(
            get: { Calendar.current.date(bySettingHour: segment.wrappedValue.startMinute / 60, minute: segment.wrappedValue.startMinute % 60, second: 0, of: Date()) ?? Date() },
            set: { segment.wrappedValue.startMinute = InsulinProfile.minuteOfDay($0) })
    }

    private func numberField(_ title: String, value: Binding<Double>, unit: String) -> some View {
        VStack(alignment: .leading) {
            Text("\(title) (\(unit))").font(.caption).foregroundStyle(.secondary)
            TextField("0", value: value, format: .number)
                .keyboardType(.decimalPad)
                .textFieldStyle(.roundedBorder)
        }
    }
}
