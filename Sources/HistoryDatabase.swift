import Foundation
import SwiftData

struct PumpHistoryEvent: Hashable, Codable {
    let date: Date
    let title: String
}

@Model final class StoredGlucose {
    @Attribute(.unique) var date: Date
    var milligramsPerDeciliter: Double
    init(date: Date, milligramsPerDeciliter: Double) {
        self.date = date
        self.milligramsPerDeciliter = milligramsPerDeciliter
    }
}

@Model final class StoredPumpEvent {
    /// Date and title together, so the same event is never stored twice.
    @Attribute(.unique) var key: String
    var date: Date
    var title: String
    init(date: Date, title: String) {
        key = "\(date.timeIntervalSince1970)|\(title)"
        self.date = date
        self.title = title
    }
}

@Model final class StoredLogLine {
    var date: Date
    var text: String
    init(date: Date, text: String) {
        self.date = date
        self.text = text
    }
}

/// On-device history in a SwiftData (SQLite) store in Application Support: transactional, survives app updates and new builds.
/// Use from the main thread only. The app never deletes the store; if it cannot be opened, history falls back to memory for
/// that run and the file is left untouched.
final class HistoryDatabase {
    static let shared = HistoryDatabase()
    static let maxLogLines = 500

    private let context: ModelContext
    /// False when the on-disk store could not be opened and this run is memory-only.
    let isPersistent: Bool

    /// `directory` nil uses Application Support; `inMemory` is for tests.
    init(directory: URL? = nil, inMemory: Bool = false) {
        let schema = Schema([StoredGlucose.self, StoredPumpEvent.self, StoredLogLine.self])
        var persistent = !inMemory
        let container: ModelContainer
        if inMemory {
            container = try! ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        } else {
            let base = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            let configuration = ModelConfiguration(schema: schema, url: base.appendingPathComponent("History.store"))
            if let opened = try? ModelContainer(for: schema, configurations: configuration) {
                container = opened
            } else {
                persistent = false
                container = try! ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
            }
        }
        isPersistent = persistent
        context = ModelContext(container)
        context.autosaveEnabled = false
        if persistent, let base = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            importLegacyFiles(from: base)
        }
    }

    // MARK: Glucose

    func glucose() -> [GlucoseReading] {
        let rows = (try? context.fetch(FetchDescriptor<StoredGlucose>(sortBy: [SortDescriptor(\.date)]))) ?? []
        return rows.map { GlucoseReading(date: $0.date, milligramsPerDeciliter: $0.milligramsPerDeciliter) }
    }

    func addGlucose(_ readings: [GlucoseReading]) {
        for reading in readings { context.insert(StoredGlucose(date: reading.date, milligramsPerDeciliter: reading.milligramsPerDeciliter)) }
        try? context.save()
    }

    // MARK: Pump

    func pumpEvents() -> [PumpHistoryEvent] {
        let rows = (try? context.fetch(FetchDescriptor<StoredPumpEvent>(sortBy: [SortDescriptor(\.date)]))) ?? []
        return rows.map { PumpHistoryEvent(date: $0.date, title: $0.title) }
    }

    func addPumpEvents(_ events: [PumpHistoryEvent]) {
        for event in events { context.insert(StoredPumpEvent(date: event.date, title: event.title)) }
        try? context.save()
    }

    // MARK: Diagnostics log

    func logLines() -> [String] {
        let rows = (try? context.fetch(FetchDescriptor<StoredLogLine>(sortBy: [SortDescriptor(\.date)]))) ?? []
        return rows.map(\.text)
    }

    func addLogLine(_ text: String, at date: Date = Date()) {
        context.insert(StoredLogLine(date: date, text: text))
        let excess = ((try? context.fetchCount(FetchDescriptor<StoredLogLine>())) ?? 0) - Self.maxLogLines
        if excess > 0 {
            var oldest = FetchDescriptor<StoredLogLine>(sortBy: [SortDescriptor(\.date)])
            oldest.fetchLimit = excess
            for row in (try? context.fetch(oldest)) ?? [] { context.delete(row) }
        }
        try? context.save()
    }

    func clearLog() {
        try? context.delete(model: StoredLogLine.self)
        try? context.save()
    }

    // MARK: One-time import of the earlier JSON files

    /// Imports the JSON history written by the previous version, then renames each file to `.imported` (kept as a backup).
    private func importLegacyFiles(from directory: URL) {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        func legacy<T: Decodable>(_ name: String, _ type: T.Type) -> (T, () -> Void)? {
            let url = directory.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url), let value = try? decoder.decode(type, from: data) else { return nil }
            return (value, { try? FileManager.default.moveItem(at: url, to: url.appendingPathExtension("imported")) })
        }
        if let (readings, done) = legacy("glucose-history.json", [GlucoseReading].self) {
            let known = Set(glucose().map(\.date))
            addGlucose(readings.filter { !known.contains($0.date) })
            done()
        }
        if let (events, done) = legacy("pump-history.json", [PumpHistoryEvent].self) {
            addPumpEvents(events)
            done()
        }
        if let (lines, done) = legacy("diagnostics-log.json", [String].self) {
            let base = Date().addingTimeInterval(-Double(lines.count))
            for (offset, line) in lines.enumerated() { context.insert(StoredLogLine(date: base.addingTimeInterval(Double(offset)), text: line)) }
            try? context.save()
            done()
        }
    }
}
