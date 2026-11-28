import SwiftUI
import Charts

private let predictionPalette: [Color] = [.orange, .purple, .teal, .pink, .brown, .mint, .indigo, .red]

private func color(for layer: PredictionLayer) -> Color {
    if let index = layer.colorIndex { return predictionPalette[index % predictionPalette.count] }
    switch layer.id {
    case "known": return .blue
    case "actual": return .green
    case "insulin": return .pink
    default: return .brown
    }
}

private let axisNumber = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(0...1))

/// Draws the layers against two y axes. SwiftUI Charts has one y scale, so every layer is placed on
/// 0...1 using its own axis and the left and right axes label that range with their real values.
struct PredictionChart: View {
    let layout: PredictionChartLayout
    let predictionTime: Date

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Text(layout.left?.unitLabel ?? "").foregroundStyle(.secondary)
                Spacer()
                Text(layout.right?.unitLabel ?? "").foregroundStyle(.secondary)
            }
            .font(.caption2)
            chart
        }
    }

    private var chart: some View {
        Chart {
            ForEach(layout.layers) { layer in
                ForEach(Array(layer.points.enumerated()), id: \.offset) { _, point in
                    if layer.style == .marker {
                        PointMark(x: .value("Time", point.date), y: .value("Value", layout.normalized(point.value, in: layer)))
                            .foregroundStyle(color(for: layer))
                            .symbolSize(60)
                    } else {
                        if let lower = point.lower, let upper = point.upper {
                            AreaMark(x: .value("Time", point.date),
                                     yStart: .value("Low", layout.normalized(lower, in: layer)),
                                     yEnd: .value("High", layout.normalized(upper, in: layer)),
                                     series: .value("Band", "\(layer.id) band"))
                                .foregroundStyle(color(for: layer).opacity(0.15))
                        }
                        LineMark(x: .value("Time", point.date), y: .value("Value", layout.normalized(point.value, in: layer)),
                                 series: .value("Series", layer.id))
                            .foregroundStyle(color(for: layer))
                            .lineStyle(layer.style == .prediction ? StrokeStyle(lineWidth: 2, dash: [5, 3]) : StrokeStyle(lineWidth: 2))
                    }
                }
            }
            RuleMark(x: .value("Prediction time", predictionTime))
                .foregroundStyle(.secondary)
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 2]))
        }
        .chartYScale(domain: 0...1)
        .chartYAxis {
            AxisMarks(position: .leading, values: layout.left.map { axis in axis.ticks.map(axis.normalized) } ?? []) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let axis = layout.left, let position = value.as(Double.self) {
                        Text(axis.value(atNormalized: position).formatted(axisNumber))
                    }
                }
            }
            AxisMarks(position: .trailing, values: layout.right.map { axis in axis.ticks.map(axis.normalized) } ?? []) { value in
                // Grid lines come from the left axis only, so two sets of lines do not clash.
                AxisValueLabel {
                    if let axis = layout.right, let position = value.as(Double.self) {
                        Text(axis.value(atNormalized: position).formatted(axisNumber))
                    }
                }
            }
        }
        .frame(height: 260)
    }
}

/// Pick models and a moment; see what each predicted from the data available then.
/// Models come from the registry, so new math appears here without view changes.
struct PredictionEvaluationView: View {
    let registry: PredictionModelRegistry
    let context: ForecastContext
    var horizon: TimeInterval = 2 * 60 * 60

    private static let configKey = "MFS.PredictionChartConfig"

    @State private var config = PredictionEvaluationView.loadConfig()
    @State private var offset = 1.0 // 0...1 across the span of readings
    @State private var hidden: Set<String> = []
    @State private var showAxes = false

    static func loadConfig(defaults: UserDefaults = .standard) -> PredictionChartConfig {
        defaults.data(forKey: configKey).flatMap { try? JSONDecoder().decode(PredictionChartConfig.self, from: $0) }
            ?? PredictionChartConfig()
    }

    private var span: ClosedRange<Date>? {
        guard let first = context.readings.map(\.date).min(), let last = context.readings.map(\.date).max(), first < last else { return nil }
        return first...last
    }

    private var predictionTime: Date? {
        span.map { $0.lowerBound.addingTimeInterval($0.upperBound.timeIntervalSince($0.lowerBound) * offset) }
    }

    /// Chosen models that are still registered; the first registered model when none is.
    private var selectedModels: [PredictionModel] {
        let chosen = registry.models.filter { config.selectedModelIDs?.contains($0.id) ?? false }
        return chosen.isEmpty ? Array(registry.models.prefix(1)) : chosen
    }

    private var evaluations: [(name: String, evaluation: PredictionEvaluation)] {
        guard let time = predictionTime else { return [] }
        return selectedModels.map {
            ($0.name, PredictionEvaluator.evaluate(model: $0, at: time, context: context, horizon: horizon))
        }
    }

    var body: some View {
        let evaluations = evaluations
        List {
            if registry.models.isEmpty {
                Text("No prediction models are available.").foregroundStyle(.secondary)
            } else if let time = predictionTime, !evaluations.isEmpty {
                content(evaluations: evaluations, time: time)
            } else {
                Text("Needs at least two glucose readings.").foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Predictions")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                modelsMenu
                Button { showAxes = true } label: { Label("Axes", systemImage: "chart.xyaxis.line") }
            }
        }
        .sheet(isPresented: $showAxes) { PredictionAxesSheet(config: $config) }
        .onChange(of: config) { _, newValue in
            if let data = try? JSONEncoder().encode(newValue) { UserDefaults.standard.set(data, forKey: Self.configKey) }
        }
    }

    private var modelsMenu: some View {
        Menu {
            ForEach(registry.models, id: \.id) { model in
                Toggle(model.name, isOn: Binding(
                    get: { selectedModels.contains { $0.id == model.id } },
                    set: { on in setModel(model.id, selected: on) }))
            }
        } label: { Label("Models", systemImage: "function") }
    }

    private func setModel(_ id: String, selected: Bool) {
        var ids = selectedModels.map(\.id)
        if selected { if !ids.contains(id) { ids.append(id) } } else if ids.count > 1 { ids.removeAll { $0 == id } }
        config.selectedModelIDs = ids
    }

    @ViewBuilder
    private func content(evaluations: [(name: String, evaluation: PredictionEvaluation)], time: Date) -> some View {
        let all = PredictionLayers.make(evaluations: evaluations, context: context, horizon: horizon)
        let layout = PredictionChartLayout(layers: all.filter { !hidden.contains($0.id) }, config: config)
        Section("Prediction") {
            PredictionChart(layout: layout, predictionTime: time)
        }
        Section("Predicted at") {
            Slider(value: $offset, in: 0...1)
            Text(time.formatted(date: .abbreviated, time: .shortened))
                .font(.caption).foregroundStyle(.secondary)
        }
        ForEach(evaluations, id: \.evaluation.modelID) { entry in
            if let failure = entry.evaluation.failure {
                Section(entry.name) { Text(failure).foregroundStyle(.red) }
            }
        }
        Section("Curves and accuracy") {
            ForEach(all) { layer in
                Toggle(isOn: Binding(get: { !hidden.contains(layer.id) },
                                     set: { on in if on { hidden.remove(layer.id) } else { hidden.insert(layer.id) } })) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Circle().fill(color(for: layer)).frame(width: 10, height: 10)
                            Text(layer.label)
                        }
                        if let detail = accuracyText(for: layer, in: evaluations) {
                            Text(detail).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private func accuracyText(for layer: PredictionLayer, in evaluations: [(name: String, evaluation: PredictionEvaluation)]) -> String? {
        guard layer.style == .prediction else { return nil }
        let result = evaluations.lazy.flatMap { entry in
            entry.evaluation.results.map { (id: "\(entry.evaluation.modelID)/\($0.series.name)", result: $0) }
        }.first { $0.id == layer.id }?.result
        guard let result, let mae = result.meanAbsoluteError, let rmse = result.rootMeanSquareError else {
            return "No later readings to compare with yet."
        }
        return "Mean abs. error \(mae.formatted(axisNumber)) mg/dl · RMS error \(rmse.formatted(axisNumber)) mg/dl · \(result.matches.count) points"
    }
}

/// Which data sits on which axis, and how each axis is scaled.
struct PredictionAxesSheet: View {
    @Binding var config: PredictionChartConfig
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(PredictionDataKind.allCases) { kind in
                        Picker("\(kind.label) (\(kind.unit))", selection: Binding(
                            get: { config.side(of: kind) },
                            set: { config.sides[kind] = $0 })) {
                            ForEach(AxisSide.allCases) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.segmented)
                    }
                } header: {
                    Text("Axis for each data type")
                } footer: {
                    Text("Data on the same side shares one scale.")
                }
                axisSection(.left)
                axisSection(.right)
                Section {
                    Button("Reset axes") {
                        var fresh = PredictionChartConfig()
                        fresh.selectedModelIDs = config.selectedModelIDs
                        config = fresh
                    }
                }
            }
            .navigationTitle("Axes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    private func kinds(on side: AxisSide) -> [PredictionDataKind] {
        PredictionDataKind.allCases.filter { config.side(of: $0) == side }
    }

    @ViewBuilder
    private func axisSection(_ side: AxisSide) -> some View {
        let range = config.range(of: side)
        let onSide = kinds(on: side)
        Section {
            Picker("Scale", selection: Binding(
                get: { range.isFixed },
                set: { fixed in
                    let start = onSide.first?.typicalRange ?? 0...100
                    config.setRange(fixed ? .fixed(low: start.lowerBound, high: start.upperBound) : .auto, of: side)
                })) {
                Text("Auto").tag(false)
                Text("Fixed").tag(true)
            }
            .pickerStyle(.segmented)
            if case .fixed(let low, let high) = range {
                LabeledContent("Minimum") {
                    TextField("Min", value: Binding(get: { low }, set: { config.setRange(.fixed(low: $0, high: high), of: side) }),
                              format: .number)
                        .keyboardType(.numbersAndPunctuation).multilineTextAlignment(.trailing)
                }
                LabeledContent("Maximum") {
                    TextField("Max", value: Binding(get: { high }, set: { config.setRange(.fixed(low: low, high: $0), of: side) }),
                              format: .number)
                        .keyboardType(.numbersAndPunctuation).multilineTextAlignment(.trailing)
                }
            }
        } header: {
            Text("\(side.label) axis" + (onSide.isEmpty ? "" : " · " + onSide.map(\.label).joined(separator: ", ")))
        } footer: {
            if onSide.isEmpty { Text("Nothing is on this axis.") }
        }
    }
}
