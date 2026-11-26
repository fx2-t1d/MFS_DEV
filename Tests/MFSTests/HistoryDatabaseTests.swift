import XCTest
@testable import MFS

@MainActor
final class HistoryDatabaseTests: XCTestCase {
    private var directory: URL!
    private let t = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: directory) }

    func testGlucoseSurvivesARelaunch() {
        var first: HistoryDatabase? = HistoryDatabase(directory: directory)
        let feed = GlucoseFeed(database: first)
        feed.merge([GlucoseReading(date: t, milligramsPerDeciliter: 110), GlucoseReading(date: t.addingTimeInterval(300), milligramsPerDeciliter: 118)])
        feed.merge([GlucoseReading(date: t, milligramsPerDeciliter: 110)])
        first = nil

        let reopened = GlucoseFeed(database: HistoryDatabase(directory: directory))
        XCTAssertEqual(reopened.readings.map(\.milligramsPerDeciliter), [110, 118])
    }

    func testPumpEventsAreNotStoredTwice() {
        let database = HistoryDatabase(inMemory: true)
        let event = PumpHistoryEvent(date: t, title: "Bolus")
        database.addPumpEvents([event])
        database.addPumpEvents([event, PumpHistoryEvent(date: t, title: "Basal")])
        XCTAssertEqual(database.pumpEvents().map(\.title).sorted(), ["Basal", "Bolus"])
    }

    func testLogIsCappedAndClearable() {
        let database = HistoryDatabase(inMemory: true)
        for i in 0..<(HistoryDatabase.maxLogLines + 5) { database.addLogLine("line \(i)", at: t.addingTimeInterval(Double(i))) }
        let lines = database.logLines()
        XCTAssertEqual(lines.count, HistoryDatabase.maxLogLines)
        XCTAssertEqual(lines.first, "line 5")
        database.clearLog()
        XCTAssertTrue(database.logLines().isEmpty)
    }

    func testEarlierJSONFilesAreImportedOnceAndKept() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let file = directory.appendingPathComponent("glucose-history.json")
        try encoder.encode([GlucoseReading(date: t, milligramsPerDeciliter: 99)]).write(to: file)

        XCTAssertEqual(HistoryDatabase(directory: directory).glucose().map(\.milligramsPerDeciliter), [99])
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.appendingPathExtension("imported").path))
        XCTAssertEqual(HistoryDatabase(directory: directory).glucose().count, 1)
    }
}
