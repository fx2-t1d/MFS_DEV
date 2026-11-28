import Foundation

// Chart layout for the prediction view: which data sits on which of the two y axes, and how each axis
// is scaled. Pure logic with no SwiftUI so it can be tested; the view only draws what this produces.

enum PredictionDataKind: String, CaseIterable, Identifiable, Codable {
    case glucose, insulin, carbohydrates

    var id: String { rawValue }

    var label: String {
        switch self {
        case .glucose: return "Glucose"
        case .insulin: return "Insulin"
        case .carbohydrates: return "Carbohydrates"
        }
    }

    /// A starting range when the user switches an axis to a fixed scale.
    var typicalRange: ClosedRange<Double> {
        switch self {
        case .glucose: return 40...300
        case .insulin: return 0...10
        case .carbohydrates: return 0...100
        }
    }

    var unit: String {
        switch self {
        case .glucose: return "mg/dl"
        case .insulin: return "u"
        case .carbohydrates: return "c"
        }
    }
}

enum AxisSide: String, CaseIterable, Identifiable, Codable {
    case left, right
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

/// How an axis picks its range: from the data shown (auto) or fixed by the user.
enum AxisRange: Equatable, Codable {
    case auto
    case fixed(low: Double, high: Double)

    var isFixed: Bool { if case .fixed = self { return true } else { return false } }
}

struct PredictionChartConfig: Equatable, Codable {
    var sides: [PredictionDataKind: AxisSide] = [.glucose: .right, .insulin: .left, .carbohydrates: .left]
    var left: AxisRange = .auto
    var right: AxisRange = .auto
    /// Models drawn together. nil until the user chooses, when the first registered model is used.
    var selectedModelIDs: [String]? = nil

    func side(of kind: PredictionDataKind) -> AxisSide { sides[kind] ?? (kind == .glucose ? .right : .left) }

    func range(of side: AxisSide) -> AxisRange { side == .left ? left : right }

    mutating func setRange(_ range: AxisRange, of side: AxisSide) {
        if side == .left { left = range } else { right = range }
    }
}

/// A resolved axis: its range and the tick values to label.
struct PredictionAxis: Equatable {
    let low: Double
    let high: Double
    let ticks: [Double]
    /// The kinds drawn against this axis, for the unit label.
    let kinds: [PredictionDataKind]

    var unitLabel: String { kinds.map(\.unit).joined(separator: " / ") }

    /// Position of `value` in 0...1 across the axis; values outside the range are clamped so they stay on the chart.
    func normalized(_ value: Double) -> Double {
        let span = high - low
        guard span > 0 else { return 0.5 }
        return min(max((value - low) / span, 0), 1)
    }

    func value(atNormalized position: Double) -> Double { low + position * (high - low) }

    static func make(range: AxisRange, values: [Double], kinds: [PredictionDataKind]) -> PredictionAxis {
        let low: Double, high: Double
        switch range {
        case .fixed(let a, let b) where a.isFinite && b.isFinite && a != b:
            (low, high) = (min(a, b), max(a, b))
        default:
            let finite = values.filter(\.isFinite)
            if let lo = finite.min(), let hi = finite.max() {
                // Pad so lines do not sit on the frame; a flat series gets a visible span.
                let pad = hi > lo ? (hi - lo) * 0.08 : max(abs(hi) * 0.1, 1)
                (low, high) = (lo - pad, hi + pad)
            } else {
                (low, high) = (0, 1)
            }
        }
        return PredictionAxis(low: low, high: high, ticks: niceTicks(low: low, high: high), kinds: kinds)
    }

    /// Round tick values (1, 2, 5 times a power of ten) inside the range, about `count` of them.
    static func niceTicks(low: Double, high: Double, count: Int = 5) -> [Double] {
        let span = high - low
        guard span > 0, span.isFinite, count > 0 else { return [] }
        let rough = span / Double(count)
        let magnitude = pow(10, floor(log10(rough)))
        let fraction = rough / magnitude
        let step = (fraction <= 1.5 ? 1 : fraction <= 3 ? 2 : fraction <= 7 ? 5 : 10) * magnitude
        var ticks: [Double] = []
        var tick = (low / step).rounded(.up) * step
        while tick <= high + step * 1e-9, ticks.count < 50 {
            ticks.append((tick / step).rounded() * step)
            tick += step
        }
        return ticks
    }
}

struct PredictionLayerPoint: Equatable {
    let date: Date
    let value: Double
    var lower: Double? = nil
    var upper: Double? = nil
}

/// One drawable thing on the chart.
struct PredictionLayer: Identifiable, Equatable {
    enum Style: Equatable { case line, prediction, marker }

    let id: String
    let label: String
    let kind: PredictionDataKind
    let style: Style
    /// Index into the chart palette for predictions; nil for the fixed colours of recorded data.
    let colorIndex: Int?
    let points: [PredictionLayerPoint]
}

/// Everything the chart draws, with each axis resolved from the layers placed on it.
struct PredictionChartLayout: Equatable {
    let layers: [PredictionLayer]
    let config: PredictionChartConfig
    let left: PredictionAxis?
    let right: PredictionAxis?

    init(layers: [PredictionLayer], config: PredictionChartConfig) {
        self.layers = layers
        self.config = config
        func axis(_ side: AxisSide) -> PredictionAxis? {
            let onSide = layers.filter { config.side(of: $0.kind) == side }
            guard !onSide.isEmpty else { return nil }
            let values = onSide.flatMap { layer in layer.points.flatMap { [$0.value] + [$0.lower, $0.upper].compactMap { $0 } } }
            let kinds = PredictionDataKind.allCases.filter { kind in onSide.contains { $0.kind == kind } }
            return PredictionAxis.make(range: config.range(of: side), values: values, kinds: kinds)
        }
        left = axis(.left)
        right = axis(.right)
    }

    func axis(for kind: PredictionDataKind) -> PredictionAxis? {
        config.side(of: kind) == .left ? left : right
    }

    /// Position 0...1 of a value from `layer` on its own axis.
    func normalized(_ value: Double, in layer: PredictionLayer) -> Double {
        axis(for: layer.kind)?.normalized(value) ?? 0.5
    }
}

enum PredictionLayers {
    /// Builds the layers for one prediction moment. `evaluations` pairs each selected model's name with its result.
    /// Recorded glucose is the same for every model, so it is drawn once.
    static func make(
        evaluations: [(name: String, evaluation: PredictionEvaluation)],
        context: ForecastContext,
        horizon: TimeInterval
    ) -> [PredictionLayer] {
        guard let first = evaluations.first?.evaluation else { return [] }
        let time = first.predictionTime
        var layers: [PredictionLayer] = []

        layers.append(PredictionLayer(
            id: "known", label: "Known glucose", kind: .glucose, style: .line, colorIndex: nil,
            points: first.known.map { PredictionLayerPoint(date: $0.date, value: $0.milligramsPerDeciliter) }))
        layers.append(PredictionLayer(
            id: "actual", label: "Actual glucose", kind: .glucose, style: .line, colorIndex: nil,
            points: first.actual.map { PredictionLayerPoint(date: $0.date, value: $0.milligramsPerDeciliter) }))

        var colorIndex = 0
        for (name, evaluation) in evaluations {
            for result in evaluation.results {
                let label = result.series.name == name ? name : "\(name) · \(result.series.name)"
                layers.append(PredictionLayer(
                    id: "\(evaluation.modelID)/\(result.series.name)", label: label, kind: .glucose, style: .prediction,
                    colorIndex: colorIndex,
                    points: result.series.points.map {
                        PredictionLayerPoint(date: $0.date, value: $0.milligramsPerDeciliter, lower: $0.lower, upper: $0.upper)
                    }))
                colorIndex += 1
            }
        }

        let window = (time.addingTimeInterval(-horizon))...(time.addingTimeInterval(horizon))
        let doses = context.doses.filter { window.contains($0.time) }
        if !doses.isEmpty {
            layers.append(PredictionLayer(
                id: "insulin", label: "Insulin doses", kind: .insulin, style: .marker, colorIndex: nil,
                points: doses.map { PredictionLayerPoint(date: $0.time, value: $0.units) }))
        }
        let foods = context.foods.filter { window.contains($0.time) && ($0.carbohydrates ?? 0) > 0 }
        if !foods.isEmpty {
            layers.append(PredictionLayer(
                id: "carbohydrates", label: "Carbohydrates", kind: .carbohydrates, style: .marker, colorIndex: nil,
                points: foods.map { PredictionLayerPoint(date: $0.time, value: $0.carbohydrates ?? 0) }))
        }
        return layers
    }
}
