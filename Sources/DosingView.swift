import SwiftUI

private func unitsText(_ units: Double?) -> String {
    units.map { "\($0.formatted(.number.precision(.fractionLength(0...1)))) u" } ?? "—"
}

private func rateText(_ rate: Double?) -> String {
    rate.map { "\($0.formatted(.number.precision(.fractionLength(0...2)))) u/h" } ?? "—"
}

/// Dosing section of Manage: three tabs on top, the formula behind Advanced.
/// Everything here is shown for the user to act on; the app sends nothing to a pump.
struct DosingSection: View {
    @EnvironmentObject private var dosing: DosingStore
    @EnvironmentObject private var foodStore: AcceptedFoodStore
    @EnvironmentObject private var formulaStore: DoseFormulaStore
    @EnvironmentObject private var profileStore: InsulinProfileStore
    @EnvironmentObject private var feed: GlucoseFeed
    @EnvironmentObject private var actions: DeviceActions

    var body: some View {
        Section("Dosing") {
            Picker("Dosing", selection: $dosing.mode) {
                ForEach(DosingMode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            switch dosing.mode {
            case .mealSpecific: mealSpecific
            case .simple: simple
            case .experimental: experimental
            }
        }
        Section("Recommendation") {
            RecommendationView(recommendation: DosingSummary.recommendation(
                mode: dosing.mode, food: foodStore.food, formula: formulaStore.formula,
                profiles: profileStore, dosing: dosing, glucose: feed.readings.last,
                iob: RecordedInsulinOnBoard(doses: actions.insulinDoses)))
        }
        Section {
            NavigationLink("Advanced: dose formula") { DoseFormulaView() }
        }
    }

    private var mealSpecific: some View {
        Group {
            Text("Doses learned for this meal from your Evaluate results.")
            Text("No evaluated results for this meal yet. Review the meal in the Evaluate tab to build them.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var simple: some View {
        Group {
            LabeledContent("Carbs") {
                numberField("Carbs", Binding(get: { dosing.simpleCarbs }, set: { dosing.simpleCarbs = $0 }), unit: "c")
            }
            LabeledContent("Protein") {
                numberField("Protein", Binding(get: { dosing.simpleProtein }, set: { dosing.simpleProteinEntry = $0 }), unit: "p")
            }
            Text("The c and p numbers are turned into units with the carb ratio in your insulin profile.")
                .font(.footnote).foregroundStyle(.secondary)
            if dosing.simpleProteinEntry != nil {
                Button("Protein = carbs ÷ \(Int(DosingStore.proteinDivisor))") { dosing.simpleProteinEntry = nil }
                    .font(.footnote)
            } else {
                Text("Protein defaults to carbs ÷ \(Int(DosingStore.proteinDivisor)). Type a number to override it.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private func numberField(_ title: String, _ value: Binding<Double?>, unit: String) -> some View {
        HStack(spacing: 4) {
            TextField(title, value: value, format: .number.precision(.fractionLength(0...1)))
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(width: 80)
            Text(unit).foregroundStyle(.secondary)
        }
    }

    private var experimental: some View {
        Group {
            Text("Draws on the dose formula for a bolus plus an enhanced basal that together offset the meal's modelled impact. Review it in the Evaluate tab.")
            Text("Experimental: the formula is not fitted to data.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }
}

enum DosingSummary {
    /// Gathers what the recommenders read. Sources that do not exist yet are the "Unavailable" placeholders.
    static func inputs(food: AcceptedFood?, profiles: InsulinProfileStore, dosing: DosingStore, glucose: GlucoseReading?,
                       now: Date = Date(), iob: InsulinOnBoardSource = UnavailableInsulinOnBoard(),
                       history: MealHistorySource = UnavailableMealHistory()) -> DoseInputs {
        let segment = profiles.segment(at: now)
        return DoseInputs(
            mealName: food?.product.name,
            carbohydrate: food?.totalCarbohydrates, fiber: food?.totalFiber,
            protein: food?.totalProtein, fat: food?.totalFat,
            glucose: glucose?.milligramsPerDeciliter,
            carbRatioGramsPerUnit: segment?.carbRatioGramsPerUnit,
            sensitivityMgdlPerUnit: segment?.sensitivityMgdlPerUnit,
            targetMgdl: segment?.targetMgdl,
            insulinOnBoard: iob.units(at: now),
            basalUnitsPerHour: segment?.basalUnitsPerHour,
            simpleCarbGrams: dosing.simpleCarbs, simpleProteinGrams: dosing.simpleProtein,
            mealHistoryBolus: food.flatMap { history.bolusUnits(forMealNamed: $0.product.name) })
    }

    static func recommendation(mode: DosingMode, food: AcceptedFood?, formula: DoseFormula, profiles: InsulinProfileStore,
                               dosing: DosingStore, glucose: GlucoseReading?,
                               iob: InsulinOnBoardSource = UnavailableInsulinOnBoard()) -> DoseRecommendation {
        DoseRecommenders.recommender(for: mode)
            .recommend(inputs(food: food, profiles: profiles, dosing: dosing, glucose: glucose, iob: iob), formula: formula)
    }
}

/// The recommended bolus with how it was built, and which inputs are still placeholders.
struct RecommendationView: View {
    let recommendation: DoseRecommendation

    var body: some View {
        Group {
            LabeledContent("Recommended bolus") {
                Text(unitsText(recommendation.bolusUnits)).font(.title3.bold())
            }
            ForEach(recommendation.parts) { part in
                LabeledContent(part.label, value: signedUnits(part.units)).font(.footnote)
            }
            if let rise = recommendation.expectedRiseMgdl {
                LabeledContent("Expected rise", value: "+\(rise.formatted(.number.precision(.fractionLength(0)))) mg/dl")
            }
            if let rate = recommendation.enhancedBasalUnitsPerHour, let minutes = recommendation.enhancedBasalMinutes {
                LabeledContent("Enhanced basal", value: "+\(rateText(rate)) for \(minutes / 60) h \(minutes % 60) min")
            }
            if !recommendation.missing.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Incomplete. Not available yet:")
                        .font(.footnote.weight(.semibold))
                    ForEach(recommendation.missing) { Text("• \($0.label)").font(.footnote) }
                }
                .foregroundStyle(.secondary)
            }
            Text("Shown for you to review. Nothing is sent to the pump.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private func signedUnits(_ units: Double) -> String {
        "\(units >= 0 ? "+" : "−")\(abs(units).formatted(.number.precision(.fractionLength(0...2)))) u"
    }
}

/// Meal grams and the recommendation for the selected dosing tab, pinned to the bottom of Manage.
struct DosingFooter: View {
    let food: AcceptedFood?
    @EnvironmentObject private var dosing: DosingStore
    @EnvironmentObject private var formulaStore: DoseFormulaStore
    @EnvironmentObject private var profileStore: InsulinProfileStore
    @EnvironmentObject private var feed: GlucoseFeed
    @EnvironmentObject private var actions: DeviceActions

    var body: some View {
        let recommendation = DosingSummary.recommendation(
            mode: dosing.mode, food: food, formula: formulaStore.formula,
            profiles: profileStore, dosing: dosing, glucose: feed.readings.last,
            iob: RecordedInsulinOnBoard(doses: actions.insulinDoses))
        Grid(horizontalSpacing: 8, verticalSpacing: 10) {
            GridRow {
                cell(grams(food?.totalCarbohydrates, "c"), "Carbohydrate", "Carbs in the meal (c)")
                cell(grams(food?.totalProtein, "p"), "Protein", "Protein in the meal (p)")
                cell(grams(food?.totalFat, "g"), "Fat", "Fat in the meal (g)")
            }
            Divider()
            GridRow {
                cell(unitsText(recommendation.bolusUnits), "Bolus", recommendation.isComplete ? "Recommended (u)" : "Incomplete (u)")
                cell(rateText(recommendation.enhancedBasalUnitsPerHour.map { $0 + (currentBasal ?? 0) } ?? currentBasal),
                     "Basal", recommendation.enhancedBasalUnitsPerHour == nil ? "Current rate (u/h)" : "Enhanced rate (u/h)")
                cell(recommendation.enhancedBasalMinutes.map { "\($0) min" } ?? "—", "Enhanced for", "Basal boost length")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .overlay(alignment: .top) { Rectangle().fill(Color.primary.opacity(0.35)).frame(height: 1) }
        .shadow(color: .black.opacity(0.15), radius: 4, y: -2)
    }

    private var currentBasal: Double? { profileStore.segment(at: Date())?.basalUnitsPerHour }

    private func grams(_ value: Double?, _ unit: String) -> String {
        value.map { "\($0.formatted()) \(unit)" } ?? "Unavailable"
    }

    private func cell(_ value: String, _ title: String, _ definition: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.title3.bold())
            Text(title).font(.caption.weight(.semibold))
            Text(definition).font(.caption2).foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
    }
}
