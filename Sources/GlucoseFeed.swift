import Foundation

/// Glucose readings shown by the UI, fed by whichever CGM host is active.
/// Every reading is kept in the on-device history database across launches and new builds. Use from the main thread.
final class GlucoseFeed: ObservableObject {
    @Published private(set) var readings: [GlucoseReading]
    private let database: HistoryDatabase?

    init(database: HistoryDatabase? = .shared) {
        self.database = database
        readings = database?.glucose() ?? []
    }

    func merge(_ new: [GlucoseReading]) {
        let known = Set(readings.map(\.date))
        let added = new.filter { !known.contains($0.date) }
        guard !added.isEmpty else { return }
        readings = (readings + added).sorted { $0.date < $1.date }
        database?.addGlucose(added)
    }
}
