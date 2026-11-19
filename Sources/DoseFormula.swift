import Foundation

/// B(t) = x·c(t) + y·p(t) + z·f(t): impact on blood glucose at time t after eating.
/// Every term shares one shape: constant × time function of the nutrient amount × optional glucose scalar.
enum DoseTimeFunction: String, Codable, CaseIterable, Identifiable {
    case constant, linearRise, linearDecay, logRise, logDecay

    var id: String { rawValue }

    var label: String {
        switch self {
        case .constant: return "Constant"
        case .linearRise: return "Linear rise"
        case .linearDecay: return "Linear decay"
        case .logRise: return "Logarithmic rise"
        case .logDecay: return "Logarithmic decay"
        }
    }

    /// Shape factor in 0...1 for t minutes after eating over a span of `duration` minutes.
    func shape(minutes t: Double, duration: Double) -> Double {
        guard t >= 0, duration > 0 else { return 0 }
        let progress = min(t / duration, 1)
        // Logarithmic curves use a 10 minute scale: fast at first, flattening later.
        let log = Foundation.log(1 + t / 10) / Foundation.log(1 + duration / 10)
        switch self {
        case .constant: return 1
        case .linearRise: return progress
        case .linearDecay: return 1 - progress
        case .logRise: return min(log, 1)
        case .logDecay: return max(1 - log, 0)
        }
    }
}

enum GlucoseScalar: String, Codable, CaseIterable, Identifiable {
    case none, glucose

    var id: String { rawValue }
    var label: String { self == .none ? "None" : "× G(t)" }
}

enum CarbFiberTreatment: String, Codable, CaseIterable, Identifiable {
    case ignore, half, full

    var id: String { rawValue }

    var label: String {
        switch self {
        case .ignore: return "Total carbs"
        case .half: return "Net (fiber ÷ 2)"
        case .full: return "Net (all fiber)"
        }
    }
}

struct DoseTerm: Codable, Equatable {
    var coefficient: Double = 0
    var function: DoseTimeFunction = .constant
    var durationMinutes: Double = 180
    var scalar: GlucoseScalar = .none

    func value(amount: Double, minutes: Double, glucose: Double?) -> Double {
        var result = coefficient * amount * function.shape(minutes: minutes, duration: durationMinutes)
        if scalar == .glucose { result *= glucose ?? 0 }
        return result
    }
}

struct DoseFormula: Codable, Equatable {
    var carbohydrate = DoseTerm()
    var protein = DoseTerm()
    var fat = DoseTerm()
    var fiber: CarbFiberTreatment = .ignore

    func carbAmount(total: Double?, fiber grams: Double?) -> Double? {
        guard let total else { return nil }
        let fiberGrams = grams ?? 0
        switch fiber {
        case .ignore: return total
        case .half: return max(total - fiberGrams / 2, 0)
        case .full: return max(total - fiberGrams, 0)
        }
    }

    /// Missing nutrient amounts contribute nothing.
    func impact(carbohydrate c: Double?, fiber: Double?, protein p: Double?, fat f: Double?,
                minutes: Double, glucose: Double?) -> Double {
        let carbs = carbAmount(total: c, fiber: fiber) ?? 0
        return carbohydrate.value(amount: carbs, minutes: minutes, glucose: glucose)
            + protein.value(amount: p ?? 0, minutes: minutes, glucose: glucose)
            + fat.value(amount: f ?? 0, minutes: minutes, glucose: glucose)
    }
}

final class DoseFormulaStore: ObservableObject {
    @Published var formula: DoseFormula { didSet { save() } }
    private let defaults: UserDefaults
    private let key = "MFS.DoseFormula"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key), let saved = try? JSONDecoder().decode(DoseFormula.self, from: data) {
            formula = saved
        } else {
            formula = DoseFormula()
        }
    }

    private func save() {
        defaults.set(try? JSONEncoder().encode(formula), forKey: key)
    }
}
