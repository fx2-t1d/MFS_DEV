import Foundation
import os.log

/// What one CGM host has delivered to the app so far.
struct PipelineStats: Equatable {
    var callbacks = 0
    var samplesReceived = 0
    var samplesMerged = 0
    var lastResult = "none yet"
    var lastResultAt: Date?
    var newestSampleDate: Date?
}

/// In-app troubleshooting log: a ring buffer shown in the Troubleshooting screen and mirrored to the unified log.
final class DiagnosticsLog: ObservableObject {
    static let shared = DiagnosticsLog()
    private static let maxLines = 500
    private let logger = Logger(subsystem: "MFS", category: "Diagnostics")
    private let stamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    @Published private(set) var lines: [String]
    @Published private(set) var stats: [String: PipelineStats] = [:]

    /// Earlier lines are loaded from the history database on the main thread right after creation.
    init() {
        lines = []
        DispatchQueue.main.async { [self] in lines = HistoryDatabase.shared.logLines() + lines }
    }

    func record(_ source: String, _ message: String) {
        let line = "\(stamp.string(from: Date())) [\(source)] \(message)"
        logger.info("\(line, privacy: .public)")
        DispatchQueue.main.async {
            self.lines.append(line)
            if self.lines.count > Self.maxLines { self.lines.removeFirst(self.lines.count - Self.maxLines) }
            HistoryDatabase.shared.addLogLine(line)
        }
    }

    func update(_ source: String, _ change: @escaping (inout PipelineStats) -> Void) {
        DispatchQueue.main.async { change(&self.stats[source, default: PipelineStats()]) }
    }

    func clear() {
        DispatchQueue.main.async { self.lines = []; self.stats = [:]; HistoryDatabase.shared.clearLog() }
    }
}
