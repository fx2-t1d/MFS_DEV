import Foundation

/// Food effect from the toy dose formula (`DoseFormula`, "toy model two").
/// B(t) is read as mg/dl of rise per minute after eating, so the effect at a time is the area under B
/// up to then. Rise that already happened by the latest reading is in that reading, so only the
/// rise after it is added.
struct DescartesFoodInfluence: GlucoseInfluence {
    var formula = DoseFormula()

    func change(at date: Date, context: ForecastContext) -> Double {
        guard let latest = context.readings.map(\.date).max() else { return 0 }
        return context.foods.reduce(0) { total, food in
            let curve = formula.curve(carbohydrate: food.carbohydrates, fiber: nil, protein: food.protein, fat: food.fat)
                .map { $0 - formula.offset }
            return total + Self.rise(curve, atMinutes: date.timeIntervalSince(food.time) / 60)
                - Self.rise(curve, atMinutes: latest.timeIntervalSince(food.time) / 60)
        }
    }

    /// Area under the per-minute curve from 0 to `minutes`, interpolated between grid minutes.
    static func rise(_ curve: [Double], atMinutes minutes: Double) -> Double {
        guard minutes > 0 else { return 0 }
        let whole = min(Int(minutes), curve.count - 1)
        let area = curve[..<whole].reduce(0, +)
        let partial = whole < curve.count - 1 ? (minutes - Double(whole)) * curve[whole] : 0
        return area + partial
    }
}

extension ForecasterPredictionModel {
    /// The app's own model: the latest reading plus the toy formula's food effect.
    static func descartes1(formula: DoseFormula = DoseFormula()) -> ForecasterPredictionModel {
        ForecasterPredictionModel(id: "descartes1", name: "Descartes1",
                                  forecaster: GlucoseForecaster(foodInfluence: DescartesFoodInfluence(formula: formula)))
    }

    /// The original placeholder forecast: the latest reading held flat.
    static var flat: ForecasterPredictionModel { ForecasterPredictionModel(id: "flat", name: "Flat") }
}
