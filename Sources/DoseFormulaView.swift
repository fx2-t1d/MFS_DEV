import SwiftUI

/// Edits B(t) = x·c(t) + y·p(t) + z·f(t) as a table with one row per nutrient.
struct DoseFormulaView: View {
    @EnvironmentObject private var formulaStore: DoseFormulaStore
    @EnvironmentObject private var foodStore: AcceptedFoodStore
    @EnvironmentObject private var feed: GlucoseFeed
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("B(t) = x·c(t) + y·p(t) + z·f(t)")
                        .font(.title3.monospaced().bold())
                    Text("B(t) is the impact on blood glucose t minutes after eating. c, p and f are time functions of carbohydrate, protein and fat grams. x, y and z are constants you choose; a negative value lowers glucose.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    ScrollView(.horizontal, showsIndicators: true) { table }
                    preview
                }
                .padding()
            }
            .navigationTitle("Dose formula")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    private var table: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
            GridRow {
                header("B(t)"); header(""); header("Constant"); header("Time function")
                header("Span (min)"); header("Glucose scalar"); header("Fiber")
            }
            Divider().gridCellUnsizedAxes(.horizontal)
            row(label: "B(t)", sign: "=", constant: "x", name: "c(t)  carbohydrate", term: $formulaStore.formula.carbohydrate, showFiber: true)
            row(label: "", sign: "+", constant: "y", name: "p(t)  protein", term: $formulaStore.formula.protein, showFiber: false)
            row(label: "", sign: "+", constant: "z", name: "f(t)  fat", term: $formulaStore.formula.fat, showFiber: false)
        }
    }

    private func header(_ text: String) -> some View {
        Text(text).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
    }

    private func row(label: String, sign: String, constant: String, name: String, term: Binding<DoseTerm>, showFiber: Bool) -> some View {
        GridRow {
            Text(label).font(.headline.monospaced())
            Text(sign).font(.headline.monospaced())
            VStack(alignment: .leading, spacing: 2) {
                TextField(constant, value: term.coefficient, format: .number)
                    .keyboardType(.numbersAndPunctuation)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
                Text(name).font(.caption2).foregroundStyle(.secondary)
            }
            Picker("Time function", selection: term.function) {
                ForEach(DoseTimeFunction.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.menu)
            TextField("min", value: term.durationMinutes, format: .number)
                .keyboardType(.decimalPad)
                .textFieldStyle(.roundedBorder)
                .frame(width: 70)
            Picker("Glucose scalar", selection: term.scalar) {
                ForEach(GlucoseScalar.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.menu)
            if showFiber {
                Picker("Fiber", selection: $formulaStore.formula.fiber) {
                    ForEach(CarbFiberTreatment.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.menu)
            } else {
                Text("—").foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var preview: some View {
        if let food = foodStore.food {
            let glucose = feed.readings.last?.milligramsPerDeciliter
            VStack(alignment: .leading, spacing: 6) {
                Text("Preview for \(food.product.name)").font(.headline)
                Text(glucose == nil ? "No glucose reading: terms with × G(t) count as 0." : "G(t) is held at the latest reading, \(Int(glucose!.rounded())) mg/dL.")
                    .font(.footnote).foregroundStyle(.secondary)
                ForEach([0.0, 30, 60, 120, 180], id: \.self) { minutes in
                    let value = formulaStore.formula.impact(
                        carbohydrate: food.totalCarbohydrates, fiber: food.totalFiber,
                        protein: food.totalProtein, fat: food.totalFat,
                        minutes: minutes, glucose: glucose)
                    LabeledContent("t = \(Int(minutes)) min", value: value.formatted(.number.precision(.fractionLength(0...2))))
                }
            }
        } else {
            Text("Accept a food to preview B(t).").font(.footnote).foregroundStyle(.secondary)
        }
    }
}
