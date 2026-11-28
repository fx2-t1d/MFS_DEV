import SwiftUI
import Charts

/// One thing that can be overlaid on the Evaluate chart.
enum EvaluateSeries: String, CaseIterable, Identifiable {
    case glucose, insulinOnBoard, bolus, basal, heartRate, heartRateVariability, sleep

    var id: String { rawValue }

    var label: String {
        switch self {
        case .glucose: return "Glucose"
        case .insulinOnBoard: return "Insulin on board"
        case .bolus: return "Bolus"
        case .basal: return "Basal"
        case .heartRate: return "Heart rate"
        case .heartRateVariability: return "Heart rate variability"
        case .sleep: return "Sleep"
        }
    }

    var units: String {
        switch self {
        case .glucose: return "mg/dl"
        case .insulinOnBoard, .bolus: return "u"
        case .basal: return "u/h"
        case .heartRate: return "bpm"
        case .heartRateVariability: return "ms"
        case .sleep: return "min"
        }
    }

    var color: Color {
        switch self {
        case .glucose: return .blue
        case .insulinOnBoard: return .purple
        case .bolus: return .pink
        case .basal: return .teal
        case .heartRate: return .red
        case .heartRateVariability: return .orange
        case .sleep: return .indigo
        }
    }

    var metric: BiometricMetric? {
        switch self {
        case .heartRate: return .heartRate
        case .heartRateVariability: return .heartRateVariability
        case .sleep: return .sleepDuration
        default: return nil
        }
    }

    static let insulinParts: [EvaluateSeries] = [.insulinOnBoard, .bolus, .basal]
    static let biometrics: [EvaluateSeries] = [.heartRate, .heartRateVariability, .sleep]
}

/// Reads recent biometrics from Apple Health for display. Read-only; nothing is sent anywhere.
@MainActor
final class EvaluateBiometrics: ObservableObject {
    @Published private(set) var samples: [BiometricMetric: [BiometricSample]] = [:]
    @Published private(set) var message: String?

    func load() async {
        do {
            let batch = try await HealthBiometricReader().read(kinds: Set(HealthDataKind.allCases), state: BiometricSyncState())
            samples = Dictionary(grouping: batch.samples, by: \.metric).mapValues { $0.sorted { $0.time < $1.time } }
            message = batch.samples.isEmpty ? "No biometric data from Apple Health yet. Connect Apple Health under Service connections." : nil
        } catch {
            message = "Apple Health data is unavailable: \(error.localizedDescription)"
        }
    }
}

/// Every available measurement on one chart. Each checked series is drawn on its own 0–100% scale
/// of the values shown, because the units differ.
struct EvaluateView: View {
    @EnvironmentObject private var feed: GlucoseFeed
    @EnvironmentObject private var actions: DeviceActions
    @EnvironmentObject private var profiles: InsulinProfileStore
    @EnvironmentObject private var foodStore: AcceptedFoodStore
    @EnvironmentObject private var formulaStore: DoseFormulaStore
    @StateObject private var biometrics = EvaluateBiometrics()
    @State private var enabled: Set<EvaluateSeries> = [.glucose]
    @State private var hours = 24

    private static let rangeHours = [6, 12, 24, 72, 168]

    private var predictionRegistry: PredictionModelRegistry {
        .standard(settings: profiles.segment(at: Date()).map(PredictionWire.Settings.init(segment:)),
                  formula: formulaStore.formula)
    }

    private var predictionContext: ForecastContext {
        // The food enters at its meal time, but never later than the latest reading.
        let anchor = feed.readings.last?.date ?? Date()
        let foods = foodStore.food.map {
            [FoodEvent(time: min(foodStore.mealTime ?? anchor, anchor), carbohydrates: $0.totalCarbohydrates,
                       protein: $0.totalProtein, fat: $0.totalFat)]
        } ?? []
        return ForecastContext(readings: feed.readings, foods: foods,
                        doses: actions.insulinDoses.filter { $0.kind == .bolus }.map { DoseEvent(time: $0.start, units: $0.units) })
    }

    private var domain: ClosedRange<Date> {
        let end = Date()
        return end.addingTimeInterval(-TimeInterval(hours) * 3600)...end
    }

    private func points(for series: EvaluateSeries) -> [(date: Date, value: Double)] {
        switch series {
        case .glucose:
            return feed.readings.map { ($0.date, $0.milligramsPerDeciliter) }
        case .insulinOnBoard:
            let doses = actions.insulinDoses
            return doses.isEmpty ? [] : InsulinOnBoard.timeline(doses: doses, from: domain.lowerBound, to: domain.upperBound)
                .map { ($0.date, $0.units) }
        case .bolus:
            return actions.insulinDoses.filter { $0.kind == .bolus }.map { ($0.start, $0.units) }
        case .basal:
            return actions.insulinDoses.filter { $0.kind == .basal }.flatMap { [($0.start, $0.amount), ($0.end, $0.amount)] }
        case .heartRate, .heartRateVariability, .sleep:
            return (series.metric.flatMap { biometrics.samples[$0] } ?? []).map { ($0.time, $0.value) }
        }
    }

    private func visible(_ series: EvaluateSeries) -> [(date: Date, value: Double)] {
        points(for: series).filter { domain.contains($0.date) }
    }

    /// Value scaled to 0...1 across the visible values of its own series.
    private func scaled(_ series: EvaluateSeries) -> [(date: Date, value: Double)] {
        let shown = visible(series)
        guard let low = shown.map(\.value).min(), let high = shown.map(\.value).max() else { return [] }
        let span = high - low
        return shown.map { ($0.date, span > 0 ? ($0.value - low) / span : 0.5) }
    }

    var body: some View {
        List {
            Section("Chart") {
                if enabled.isEmpty {
                    Text("Check a measurement below to overlay it.").foregroundStyle(.secondary)
                } else {
                    chart
                }
                Picker("Range", selection: $hours) {
                    ForEach(Self.rangeHours, id: \.self) { Text($0 < 48 ? "\($0) h" : "\($0 / 24) d").tag($0) }
                }
                .pickerStyle(.segmented)
            }
            PredictionEvaluationView(registry: predictionRegistry, context: predictionContext)
            Section("Glucose") { toggle(.glucose) }
            Section {
                ForEach(EvaluateSeries.insulinParts) { toggle($0) }
            } header: {
                Text("Insulin")
            } footer: {
                Text("From the paired pump's history. Insulin on board counts boluses only, using Loop's rapid-acting model (6 h, 75 min peak).")
            }
            Section {
                ForEach(EvaluateSeries.biometrics) { toggle($0) }
            } header: {
                Text("Biometrics")
            } footer: {
                if let message = biometrics.message { Text(message) }
            }
        }
        .task { await biometrics.load() }
    }

    private func toggle(_ series: EvaluateSeries) -> some View {
        let count = visible(series).count
        return Toggle(isOn: Binding(
            get: { enabled.contains(series) },
            set: { on in if on { enabled.insert(series) } else { enabled.remove(series) } })) {
            HStack {
                Circle().fill(series.color).frame(width: 10, height: 10)
                VStack(alignment: .leading, spacing: 2) {
                    Text(series.label)
                    Text(count == 0 ? "No data in range" : rangeText(series))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .toggleStyle(.checkbox)
    }

    private func rangeText(_ series: EvaluateSeries) -> String {
        let values = visible(series).map(\.value)
        guard let low = values.min(), let high = values.max() else { return "" }
        let format = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(0...1))
        return "\(low.formatted(format))–\(high.formatted(format)) \(series.units)"
    }

    private var chart: some View {
        Chart {
            ForEach(EvaluateSeries.allCases.filter { enabled.contains($0) }) { series in
                ForEach(Array(scaled(series).enumerated()), id: \.offset) { _, point in
                    if series == .sleep || series == .bolus {
                        PointMark(x: .value("Time", point.date), y: .value("Scaled", point.value))
                            .foregroundStyle(series.color)
                    } else {
                        LineMark(x: .value("Time", point.date), y: .value("Scaled", point.value),
                                 series: .value("Series", series.label))
                            .foregroundStyle(series.color)
                    }
                }
            }
        }
        .chartXScale(domain: domain)
        .chartYScale(domain: 0...1)
        .chartYAxis(.hidden)
        .frame(height: 240)
    }
}

/// A checkbox look for `Toggle`, which iOS lacks.
struct CheckboxToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack {
                Image(systemName: configuration.isOn ? "checkmark.square.fill" : "square")
                    .foregroundStyle(configuration.isOn ? Color.accentColor : Color.secondary)
                configuration.label
                Spacer()
            }
        }
        .buttonStyle(.plain)
    }
}

extension ToggleStyle where Self == CheckboxToggleStyle {
    static var checkbox: CheckboxToggleStyle { CheckboxToggleStyle() }
}
