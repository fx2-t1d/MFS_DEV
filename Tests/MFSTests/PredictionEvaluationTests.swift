import XCTest
@testable import MFS

final class PredictionEvaluationTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func readings(_ values: [Double]) -> [GlucoseReading] {
        values.enumerated().map { GlucoseReading(date: t0.addingTimeInterval(Double($0.offset) * 300), milligramsPerDeciliter: $0.element) }
    }

    private struct SeenModel: PredictionModel {
        let id = "seen"
        let name = "Seen"
        let record: (ForecastContext) -> Void
        func predict(context: ForecastContext, horizon: TimeInterval, step: TimeInterval) throws -> [PredictionSeries] {
            record(context)
            return [PredictionSeries(name: "Seen", points: [PredictionPoint(date: context.readings.last!.date.addingTimeInterval(step), milligramsPerDeciliter: 100)])]
        }
    }

    private struct FixedTransport: PredictionTransport {
        let reply: String
        var capture: ((Data) -> Void)? = nil
        func exchange(_ request: Data) throws -> Data {
            capture?(request)
            return Data(reply.utf8)
        }
    }

    private func script(_ reply: String, capture: ((Data) -> Void)? = nil) -> ScriptPredictionModel {
        ScriptPredictionModel(id: "script", name: "Script", transport: FixedTransport(reply: reply, capture: capture))
    }

    func testModelOnlySeesDataUpToThePredictionTime() {
        var seen: ForecastContext?
        let all = readings([100, 110, 120, 130])
        let context = ForecastContext(readings: all, foods: [FoodEvent(time: t0.addingTimeInterval(900), carbohydrates: 10, protein: nil, fat: nil)])
        let result = PredictionEvaluator.evaluate(model: SeenModel { seen = $0 }, at: t0.addingTimeInterval(300), context: context)
        XCTAssertEqual(seen?.readings, Array(all.prefix(2)))
        XCTAssertTrue(seen?.foods.isEmpty ?? false)
        XCTAssertEqual(result.actual, Array(all.suffix(2)))
    }

    func testErrorsComparePredictionsWithLaterReadings() throws {
        let context = ForecastContext(readings: readings([100, 100, 110, 130]))
        let result = PredictionEvaluator.evaluate(model: ForecasterPredictionModel(), at: t0.addingTimeInterval(300), context: context, horizon: 600)
        // Baseline holds 100: errors are -10 and -30.
        let series = try XCTUnwrap(result.results.first)
        XCTAssertEqual(series.matches.map(\.error), [-10, -30])
        XCTAssertEqual(series.meanAbsoluteError, 20)
    }

    func testRegistryReplacesModelsWithTheSameID() {
        var registry = PredictionModelRegistry()
        registry.register(ForecasterPredictionModel(id: "baseline", name: "Replaced"))
        registry.register(ForecasterPredictionModel(id: "other", name: "Other"))
        XCTAssertEqual(registry.models.map(\.name), ["Replaced", "Other"])
    }

    func testScriptModelSendsContextAndReturnsEveryCurve() throws {
        var request: PredictionWire.Request?
        let model = script(#"{"version":1,"series":[{"name":"IOB","points":[{"t":1700000600,"mgdl":105}]},{"name":"UAM","points":[{"t":1700000600,"mgdl":120,"lower":110,"upper":130}]}]}"#) {
            request = try? JSONDecoder().decode(PredictionWire.Request.self, from: $0)
        }
        let context = ForecastContext(readings: readings([100, 110]),
                                      doses: [DoseEvent(time: t0, units: 2)])
        let series = try model.predict(context: context, horizon: 3600, step: 300)
        XCTAssertEqual(series.map(\.name), ["IOB", "UAM"])
        XCTAssertEqual(series[1].points.first?.upper, 130)
        XCTAssertEqual(request?.time, 1_700_000_300)
        XCTAssertEqual(request?.readings.count, 2)
        XCTAssertEqual(request?.doses, [.init(t: 1_700_000_000, units: 2)])
    }

    func testUnusableReplyIsReportedNotDrawn() {
        let context = ForecastContext(readings: readings([100, 110, 120]))
        let bad = [
            "not json",
            #"{"version":2,"series":[]}"#,
            #"{"series":[]}"#,
            #"{"series":[{"name":"A","points":[]}]}"#,
            #"{"series":[{"name":"A","points":[{"t":1,"mgdl":1}]},{"name":"A","points":[{"t":1,"mgdl":1}]}]}"#,
            #"{"error":"profile missing"}"#,
        ]
        for reply in bad {
            let result = PredictionEvaluator.evaluate(model: script(reply), at: t0.addingTimeInterval(300), context: context)
            XCTAssertNotNil(result.failure, reply)
            XCTAssertTrue(result.results.isEmpty, reply)
        }
    }

    func testPointsAtOrBeforeThePredictionTimeAreNotScored() throws {
        let context = ForecastContext(readings: readings([100, 100, 110]))
        let model = script(#"{"series":[{"name":"A","points":[{"t":1700000300,"mgdl":100},{"t":1700000600,"mgdl":110}]}]}"#)
        let result = PredictionEvaluator.evaluate(model: model, at: t0.addingTimeInterval(300), context: context)
        XCTAssertEqual(try XCTUnwrap(result.results.first).series.points.count, 1)
        XCTAssertEqual(try XCTUnwrap(result.results.first).meanAbsoluteError, 0)
    }

    #if os(macOS) || os(Linux)
    private func command(_ shell: String, timeout: TimeInterval = 10) -> ScriptPredictionModel {
        ScriptPredictionModel(id: "cmd", name: "Cmd", transport: CommandPredictionTransport(
            executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", shell], timeout: timeout))
    }

    func testCommandModelReadsRequestAndWritesResponse() throws {
        // Echoes a series whose value is the number of bytes received, proving stdin was delivered.
        let model = command(#"n=$(wc -c); echo "{\"series\":[{\"name\":\"Bytes\",\"points\":[{\"t\":1700000600,\"mgdl\":$n}]}]}""#)
        let series = try model.predict(context: ForecastContext(readings: readings([100, 110])), horizon: 600, step: 300)
        XCTAssertGreaterThan(try XCTUnwrap(series.first?.points.first?.milligramsPerDeciliter), 50)
    }

    func testCommandFailureAndTimeoutAreReported() {
        let context = ForecastContext(readings: readings([100, 110]))
        XCTAssertThrowsError(try command("echo oops >&2; exit 3").predict(context: context, horizon: 600, step: 300)) {
            XCTAssertEqual($0 as? PredictionError, .modelFailed("oops"))
        }
        let started = Date()
        XCTAssertThrowsError(try command("exec sleep 30", timeout: 0.5).predict(context: context, horizon: 600, step: 300)) {
            XCTAssertEqual($0 as? PredictionError, .modelFailed("timed out after 0 s"))
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }
    #endif

    #if canImport(JavaScriptCore)
    func testJavaScriptModelRoundTrips() throws {
        let source = """
        function predict(json) {
          var r = JSON.parse(json);
          return JSON.stringify({version: 1, series: [{name: "Flat", points: [{t: r.time + r.step, mgdl: r.readings[r.readings.length - 1].mgdl}]}]});
        }
        """
        let model = ScriptPredictionModel(id: "js", name: "JS", transport: JavaScriptPredictionTransport(source: source))
        let series = try model.predict(context: ForecastContext(readings: readings([100, 111])), horizon: 600, step: 300)
        XCTAssertEqual(series.first?.points.first?.milligramsPerDeciliter, 111)
    }

    func testJavaScriptErrorsAreReported() {
        let model = ScriptPredictionModel(id: "js", name: "JS", transport: JavaScriptPredictionTransport(source: "function predict(j) { throw new Error('boom'); }"))
        XCTAssertThrowsError(try model.predict(context: ForecastContext(readings: readings([100, 111])), horizon: 600, step: 300))
    }
    #endif

    // MARK: Axes

    private func layer(_ id: String, _ kind: PredictionDataKind, _ values: [Double]) -> PredictionLayer {
        PredictionLayer(id: id, label: id, kind: kind, style: .line, colorIndex: nil,
                        points: values.enumerated().map { PredictionLayerPoint(date: t0.addingTimeInterval(Double($0.offset) * 300), value: $0.element) })
    }

    func testGlucoseDefaultsToTheRightAxisAndOthersToTheLeft() throws {
        let layout = PredictionChartLayout(
            layers: [layer("g", .glucose, [100, 200]), layer("i", .insulin, [0, 4])], config: PredictionChartConfig())
        XCTAssertEqual(layout.right?.kinds, [.glucose])
        XCTAssertEqual(layout.left?.kinds, [.insulin])
    }

    func testAutoScaleFitsEachSideAndFixedScaleIsHonoured() throws {
        var config = PredictionChartConfig()
        let layers = [layer("g", .glucose, [100, 200]), layer("i", .insulin, [0, 4])]
        let auto = try XCTUnwrap(PredictionChartLayout(layers: layers, config: config).right)
        XCTAssertLessThan(auto.low, 100)
        XCTAssertGreaterThan(auto.high, 200)

        config.right = .fixed(low: 50, high: 250)
        let fixed = try XCTUnwrap(PredictionChartLayout(layers: layers, config: config).right)
        XCTAssertEqual(fixed.normalized(150), 0.5)
        XCTAssertEqual(fixed.normalized(500), 1, "values past a fixed range are clamped to the edge")
    }

    func testMovingADataTypeMovesItsAxis() {
        var config = PredictionChartConfig()
        config.sides[.insulin] = .right
        let layout = PredictionChartLayout(layers: [layer("g", .glucose, [100]), layer("i", .insulin, [2])], config: config)
        XCTAssertNil(layout.left)
        XCTAssertEqual(layout.right?.kinds, [.glucose, .insulin])
    }

    func testFlatAndEmptyDataStillGetUsableAxes() {
        let flat = PredictionAxis.make(range: .auto, values: [120, 120], kinds: [.glucose])
        XCTAssertLessThan(flat.low, flat.high)
        let empty = PredictionAxis.make(range: .auto, values: [], kinds: [.glucose])
        XCTAssertEqual(empty.normalized(0.5), 0.5)
        let backwards = PredictionAxis.make(range: .fixed(low: 300, high: 40), values: [], kinds: [.glucose])
        XCTAssertEqual(backwards.low, 40)
    }

    func testTicksAreRoundAndInsideTheRange() {
        XCTAssertEqual(PredictionAxis.niceTicks(low: 40, high: 300), [50, 100, 150, 200, 250, 300])
    }

    func testLayersCombineSelectedModelsAndCarryDoses() {
        let all = readings([100, 100, 110, 130])
        let context = ForecastContext(readings: all, foods: [FoodEvent(time: t0, carbohydrates: 30, protein: nil, fat: nil)],
                                      doses: [DoseEvent(time: t0, units: 2)])
        let time = t0.addingTimeInterval(300)
        let evaluations = [
            (name: "A", evaluation: PredictionEvaluator.evaluate(model: ForecasterPredictionModel(id: "a", name: "A"), at: time, context: context)),
            (name: "B", evaluation: PredictionEvaluator.evaluate(model: ForecasterPredictionModel(id: "b", name: "B"), at: time, context: context)),
        ]
        let layers = PredictionLayers.make(evaluations: evaluations, context: context, horizon: 7200)
        XCTAssertEqual(layers.map(\.id), ["known", "actual", "a/A", "b/B", "insulin", "carbohydrates"])
        XCTAssertEqual(layers.compactMap(\.colorIndex), [0, 1])
    }

    func testChartConfigSurvivesEncoding() throws {
        var config = PredictionChartConfig()
        config.sides[.insulin] = .right
        config.left = .fixed(low: 0, high: 12)
        config.selectedModelIDs = ["oref1"]
        XCTAssertEqual(try JSONDecoder().decode(PredictionChartConfig.self, from: JSONEncoder().encode(config)), config)
    }

    func testDescartes1RaisesTheForecastForFoodEnteredNowAndFlatDoesNot() throws {
        let data = readings([100, 100, 100])
        let now = data.last!.date
        let food = FoodEvent(time: now, carbohydrates: 40, protein: 10, fat: 0)
        let context = ForecastContext(readings: data, foods: [food])
        let descartes = try ForecasterPredictionModel.descartes1().predict(context: context, horizon: 7200, step: 300)[0].points
        let flat = try ForecasterPredictionModel.flat.predict(context: context, horizon: 7200, step: 300)[0].points
        XCTAssertEqual(descartes.first?.milligramsPerDeciliter ?? 0, 100, accuracy: 3) // a step after the reading
        XCTAssertGreaterThan(descartes.last!.milligramsPerDeciliter, 110)
        XCTAssertTrue(flat.allSatisfy { $0.milligramsPerDeciliter == 100 })
    }

    func testDescartes1CountsOnlyTheRiseAfterTheLatestReading() throws {
        let data = readings([100, 100, 100])
        let eaten = data.last!.date.addingTimeInterval(-3600)
        let withFood = ForecastContext(readings: data, foods: [FoodEvent(time: eaten, carbohydrates: 40, protein: 0, fat: 0)])
        let points = try ForecasterPredictionModel.descartes1().predict(context: withFood, horizon: 3600, step: 300)[0].points
        let earlier = DescartesFoodInfluence().change(at: data.last!.date, context: withFood)
        XCTAssertEqual(earlier, 0, accuracy: 1e-9)
        XCTAssertGreaterThanOrEqual(points.last!.milligramsPerDeciliter, 100)
    }
}
