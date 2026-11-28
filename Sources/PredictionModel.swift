import Foundation

// Plug-in API for the prediction/evaluation visualization. Nothing here does the glucose math:
// a model is anything that turns the data known at a moment into one or more predicted curves.
// The visualization draws what a model returns and compares it with what actually happened.
// The language-neutral contract for script models is in docs/PREDICTION_API.md.

struct PredictionPoint: Equatable, Identifiable {
    let date: Date
    let milligramsPerDeciliter: Double
    /// Optional uncertainty band drawn around the value.
    var lower: Double? = nil
    var upper: Double? = nil
    var id: Date { date }
}

/// One named curve from a model, e.g. "IOB" or "UAM". Points are in ascending time order.
struct PredictionSeries: Equatable, Identifiable {
    let name: String
    let points: [PredictionPoint]
    var id: String { name }
}

enum PredictionError: Error, Equatable, LocalizedError {
    case noReadings
    case unsupportedVersion(Int)
    case invalidResponse(String)
    case modelFailed(String)

    var errorDescription: String? {
        switch self {
        case .noReadings: return "There are no glucose readings to predict from."
        case .unsupportedVersion(let version): return "The model speaks prediction API version \(version), which is not supported."
        case .invalidResponse(let detail): return "The model returned an unusable response: \(detail)"
        case .modelFailed(let detail): return "The model failed: \(detail)"
        }
    }
}

/// A mathematical model that can be shown and evaluated. Implementations must only use
/// data in `context` (the caller hides anything after the prediction time).
protocol PredictionModel {
    /// Stable identifier, unique among registered models.
    var id: String { get }
    var name: String { get }
    /// Predicted curves after the latest reading in `context`, spaced `step` apart up to `horizon`.
    func predict(context: ForecastContext, horizon: TimeInterval, step: TimeInterval) throws -> [PredictionSeries]
}

/// Adapts the existing `GlucoseForecaster` so it can be plugged in like any other model.
struct ForecasterPredictionModel: PredictionModel {
    var id = "baseline"
    var name = "Baseline"
    var forecaster = GlucoseForecaster()

    func predict(context: ForecastContext, horizon: TimeInterval, step: TimeInterval) throws -> [PredictionSeries] {
        let points = forecaster.points(context: context, horizon: horizon, step: step)
            .map { PredictionPoint(date: $0.date, milligramsPerDeciliter: $0.milligramsPerDeciliter) }
        guard !points.isEmpty else { throw PredictionError.noReadings }
        return [PredictionSeries(name: name, points: points)]
    }
}

/// The models offered to the visualization.
struct PredictionModelRegistry {
    private(set) var models: [PredictionModel]

    init(models: [PredictionModel] = [ForecasterPredictionModel()]) {
        self.models = []
        for model in models { register(model) }
    }

    /// Adds a model, replacing any registered model with the same id.
    mutating func register(_ model: PredictionModel) {
        models.removeAll { $0.id == model.id }
        models.append(model)
    }

    mutating func unregister(id: String) { models.removeAll { $0.id == id } }

    func model(id: String) -> PredictionModel? { models.first { $0.id == id } }
}

// MARK: Wire format (version 1) shared by every script/connector model

/// Times are seconds since 1970-01-01 UTC; glucose is mg/dl; durations are seconds.
enum PredictionWire {
    static let version = 1

    struct Request: Codable, Equatable {
        struct Reading: Codable, Equatable { var t: Double; var mgdl: Double }
        struct Food: Codable, Equatable { var t: Double; var carbs: Double?; var protein: Double?; var fat: Double? }
        struct Dose: Codable, Equatable { var t: Double; var units: Double }

        var version = PredictionWire.version
        /// The moment being predicted from: the latest reading.
        var time: Double
        var horizon: Double
        var step: Double
        var readings: [Reading]
        var foods: [Food]
        var doses: [Dose]
        /// Optional therapy settings in effect at `time`, for models that need them.
        var settings: Settings? = nil
        /// Free-form choices for one model, e.g. which variant of a shared script to run.
        var options: [String: String]? = nil
    }

    /// Insulin sensitivity in mg/dl per u, carb ratio in c per u, basal in u/h, target in mg/dl, insulin duration in hours.
    struct Settings: Codable, Equatable {
        var isf: Double?
        var carbRatio: Double?
        var basal: Double?
        var target: Double?
        var dia: Double?
        var maxIOB: Double?
    }

    struct Response: Codable, Equatable {
        struct Point: Codable, Equatable { var t: Double; var mgdl: Double; var lower: Double?; var upper: Double? }
        struct Series: Codable, Equatable { var name: String; var points: [Point] }

        var version: Int?
        var error: String?
        var series: [Series]?
    }

    static func request(context: ForecastContext, horizon: TimeInterval, step: TimeInterval,
                        settings: Settings? = nil, options: [String: String]? = nil) throws -> Request {
        guard let latest = context.readings.map(\.date).max() else { throw PredictionError.noReadings }
        return Request(
            time: latest.timeIntervalSince1970, horizon: horizon, step: step,
            readings: context.readings.sorted { $0.date < $1.date }
                .map { .init(t: $0.date.timeIntervalSince1970, mgdl: $0.milligramsPerDeciliter) },
            foods: context.foods.map { .init(t: $0.time.timeIntervalSince1970, carbs: $0.carbohydrates, protein: $0.protein, fat: $0.fat) },
            doses: context.doses.map { .init(t: $0.time.timeIntervalSince1970, units: $0.units) },
            settings: settings, options: options)
    }

    /// Decodes and validates a model's reply. Bad points are rejected, never silently drawn.
    static func series(from data: Data) throws -> [PredictionSeries] {
        let response: Response
        do { response = try JSONDecoder().decode(Response.self, from: data) }
        catch { throw PredictionError.invalidResponse("not valid JSON for this API (\(error.localizedDescription))") }

        if let message = response.error, !message.isEmpty { throw PredictionError.modelFailed(message) }
        // A missing version is accepted as version 1 so tiny scripts stay tiny.
        if let reported = response.version, reported != version { throw PredictionError.unsupportedVersion(reported) }
        guard let series = response.series, !series.isEmpty else { throw PredictionError.invalidResponse("no series") }

        var seen = Set<String>()
        return try series.map { item in
            guard !item.name.isEmpty, seen.insert(item.name).inserted else {
                throw PredictionError.invalidResponse("series names must be non-empty and unique")
            }
            guard !item.points.isEmpty else { throw PredictionError.invalidResponse("series \"\(item.name)\" has no points") }
            let points: [PredictionPoint] = try item.points.map { point in
                let values = [point.t, point.mgdl] + [point.lower, point.upper].compactMap { $0 }
                guard values.allSatisfy(\.isFinite) else {
                    throw PredictionError.invalidResponse("series \"\(item.name)\" has a non-numeric value")
                }
                return PredictionPoint(date: Date(timeIntervalSince1970: point.t), milligramsPerDeciliter: point.mgdl,
                                       lower: point.lower, upper: point.upper)
            }
            return PredictionSeries(name: item.name, points: points.sorted { $0.date < $1.date })
        }
    }
}

// MARK: Script / connector models

/// Carries one request to a model implemented outside Swift and returns its raw reply.
/// A transport knows how to run the model; it knows nothing about glucose.
protocol PredictionTransport {
    func exchange(_ request: Data) throws -> Data
}

/// A model implemented by a script. Swapping oref0, oref1 or an experimental model is a
/// matter of registering another `ScriptPredictionModel` with a different transport.
struct ScriptPredictionModel: PredictionModel {
    let id: String
    let name: String
    let transport: PredictionTransport
    var settings: PredictionWire.Settings? = nil
    var options: [String: String]? = nil

    func predict(context: ForecastContext, horizon: TimeInterval, step: TimeInterval) throws -> [PredictionSeries] {
        let request = try PredictionWire.request(context: context, horizon: horizon, step: step, settings: settings, options: options)
        let reply = try transport.exchange(try JSONEncoder().encode(request))
        return try PredictionWire.series(from: reply)
    }
}

#if canImport(JavaScriptCore)
import JavaScriptCore

/// Runs a JavaScript source in JavaScriptCore (available on iOS). The source must define a
/// global `predict(requestJSON)` that returns the response as a JSON string.
/// A fresh context is made per call so models cannot leak state between predictions.
struct JavaScriptPredictionTransport: PredictionTransport {
    let source: String

    func exchange(_ request: Data) throws -> Data {
        guard let context = JSContext() else { throw PredictionError.modelFailed("JavaScript is unavailable") }
        var failure: String?
        context.exceptionHandler = { _, exception in failure = exception?.toString() }
        context.evaluateScript(source)
        if let failure { throw PredictionError.modelFailed(failure) }
        guard let function = context.objectForKeyedSubscript("predict"), !function.isUndefined else {
            throw PredictionError.modelFailed("the script does not define predict(requestJSON)")
        }
        let reply = function.call(withArguments: [String(decoding: request, as: UTF8.self)])
        if let failure { throw PredictionError.modelFailed(failure) }
        guard let text = reply?.toString(), reply?.isString == true else {
            throw PredictionError.invalidResponse("predict() must return a JSON string")
        }
        return Data(text.utf8)
    }
}
#endif

#if os(macOS) || os(Linux)
/// Runs an external command: request JSON on standard input, response JSON on standard output.
/// For development on a computer; iOS apps cannot launch processes.
struct CommandPredictionTransport: PredictionTransport {
    let executable: URL
    var arguments: [String] = []
    var timeout: TimeInterval = 30

    private final class Capture: @unchecked Sendable { var data = Data() }

    func exchange(_ request: Data) throws -> Data {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors

        do { try process.run() }
        catch { throw PredictionError.modelFailed("could not start \(executable.lastPathComponent): \(error.localizedDescription)") }

        let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        defer { killer.cancel() }

        // Drain output concurrently so a chatty model cannot fill a pipe and deadlock.
        let out = Capture(), err = Capture(), group = DispatchGroup()
        for (pipe, capture) in [(output, out), (errors, err)] {
            group.enter()
            DispatchQueue.global().async {
                capture.data = pipe.fileHandleForReading.readDataToEndOfFile()
                group.leave()
            }
        }
        // A child that already exited closes the pipe; that is reported below, not a crash.
        try? input.fileHandleForWriting.write(contentsOf: request)
        try? input.fileHandleForWriting.close()
        process.waitUntilExit()
        // After a timeout a grandchild may still hold the pipes open, so do not wait for them forever.
        let drained = group.wait(timeout: .now() + 1) == .success

        if process.terminationReason == .uncaughtSignal {
            throw PredictionError.modelFailed("timed out after \(Int(timeout)) s")
        }
        guard process.terminationStatus == 0 else {
            let detail = drained ? String(decoding: err.data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) : ""
            throw PredictionError.modelFailed(detail.isEmpty ? "exit status \(process.terminationStatus)" : detail)
        }
        guard drained else { throw PredictionError.modelFailed("the command closed without finishing its output") }
        return out.data
    }
}
#endif

// MARK: Evaluation

/// A prediction made at one moment, lined up against the readings that followed.
struct PredictionEvaluation: Equatable {
    struct Match: Equatable, Identifiable {
        let date: Date
        let predicted: Double
        let actual: Double
        var error: Double { predicted - actual }
        var id: Date { date }
    }

    /// One curve scored against what happened.
    struct SeriesResult: Equatable, Identifiable {
        let series: PredictionSeries
        /// Predicted points that have a reading within the tolerance.
        let matches: [Match]
        var id: String { series.id }

        var meanAbsoluteError: Double? {
            matches.isEmpty ? nil : matches.map { abs($0.error) }.reduce(0, +) / Double(matches.count)
        }

        var rootMeanSquareError: Double? {
            matches.isEmpty ? nil : (matches.map { $0.error * $0.error }.reduce(0, +) / Double(matches.count)).squareRoot()
        }
    }

    let modelID: String
    let predictionTime: Date
    let results: [SeriesResult]
    /// Readings at or before the prediction time: what the model was allowed to see.
    let known: [GlucoseReading]
    /// Readings after the prediction time, within the horizon.
    let actual: [GlucoseReading]
    /// Why the model produced nothing, if it failed. The visualization shows this instead of a chart of guesses.
    var failure: String? = nil
}

enum PredictionEvaluator {
    /// Runs `model` as of `time` using only data up to then, and matches it to what happened next.
    /// A failing model yields an evaluation with `failure` set; it never takes the screen down.
    static func evaluate(
        model: PredictionModel,
        at time: Date,
        context: ForecastContext,
        horizon: TimeInterval = 2 * 60 * 60,
        step: TimeInterval = 5 * 60,
        tolerance: TimeInterval = 150
    ) -> PredictionEvaluation {
        let known = context.readings.filter { $0.date <= time }.sorted { $0.date < $1.date }
        let actual = context.readings
            .filter { $0.date > time && $0.date <= time.addingTimeInterval(horizon) }
            .sorted { $0.date < $1.date }
        let visible = ForecastContext(
            readings: known,
            foods: context.foods.filter { $0.time <= time },
            doses: context.doses.filter { $0.time <= time })

        func evaluation(results: [PredictionEvaluation.SeriesResult] = [], failure: String? = nil) -> PredictionEvaluation {
            PredictionEvaluation(modelID: model.id, predictionTime: time, results: results,
                                 known: known, actual: actual, failure: failure)
        }

        let series: [PredictionSeries]
        do { series = try model.predict(context: visible, horizon: horizon, step: step) }
        catch { return evaluation(failure: error.localizedDescription) }

        let results = series.map { curve -> PredictionEvaluation.SeriesResult in
            // Anything at or before `time` is hindsight the model must not be credited for.
            let future = curve.points.filter { $0.date > time }
            let matches: [PredictionEvaluation.Match] = future.compactMap { point in
                guard let reading = actual.min(by: { abs($0.date.timeIntervalSince(point.date)) < abs($1.date.timeIntervalSince(point.date)) }),
                      abs(reading.date.timeIntervalSince(point.date)) <= tolerance else { return nil }
                return PredictionEvaluation.Match(date: point.date, predicted: point.milligramsPerDeciliter, actual: reading.milligramsPerDeciliter)
            }
            return PredictionEvaluation.SeriesResult(series: PredictionSeries(name: curve.name, points: future), matches: matches)
        }
        return evaluation(results: results)
    }
}
