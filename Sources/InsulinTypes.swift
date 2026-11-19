import Foundation

/// Approximate pharmacology of common insulins, for future dose and forecast models.
/// Values are population approximations, not dosing advice.
struct InsulinProfile: Identifiable, Equatable {
    enum Delivery: String {
        case injectionOrPump = "Subcutaneous injection or insulin pump"
        case injection = "Subcutaneous injection"
        case inhaled = "Inhalation (not for pumps)"
    }

    /// Hours; `max` nil means "min or longer".
    struct HoursRange: Equatable {
        let min: Double
        let max: Double?
    }

    let id: String
    let category: String
    let brandNames: [String]
    let delivery: Delivery
    /// nil when no single figure applies; see `halfLifeNote`.
    let halfLifeHours: HoursRange?
    let halfLifeNote: String
    let durationHours: HoursRange
}

enum InsulinTable {
    static let all: [InsulinProfile] = [
        InsulinProfile(id: "rapid-lispro", category: "Rapid-acting (lispro)",
                       brandNames: ["Humalog", "Admelog", "Lyumjev"], delivery: .injectionOrPump,
                       halfLifeHours: .init(min: 1, max: 1), halfLifeNote: "~1 hour",
                       durationHours: .init(min: 3, max: 5)),
        InsulinProfile(id: "rapid-aspart", category: "Rapid-acting (aspart)",
                       brandNames: ["Novolog", "Fiasp"], delivery: .injectionOrPump,
                       halfLifeHours: .init(min: 1, max: 1), halfLifeNote: "~1 hour",
                       durationHours: .init(min: 3, max: 5)),
        InsulinProfile(id: "rapid-glulisine", category: "Rapid-acting (glulisine)",
                       brandNames: ["Apidra"], delivery: .injectionOrPump,
                       halfLifeHours: .init(min: 1, max: 1), halfLifeNote: "~1 hour",
                       durationHours: .init(min: 3, max: 5)),
        InsulinProfile(id: "short-regular", category: "Short-acting (regular human)",
                       brandNames: ["Humulin R", "Novolin R"], delivery: .injectionOrPump,
                       halfLifeHours: nil, halfLifeNote: "~5–6 min IV; absorption-limited SC",
                       durationHours: .init(min: 6, max: 8)),
        InsulinProfile(id: "intermediate-nph", category: "Intermediate-acting (NPH)",
                       brandNames: ["Humulin N", "Novolin N"], delivery: .injection,
                       halfLifeHours: nil, halfLifeNote: "Absorption-limited",
                       durationHours: .init(min: 12, max: 16)),
        InsulinProfile(id: "long-glargine-u100", category: "Long-acting (glargine U-100)",
                       brandNames: ["Lantus", "Basaglar", "Semglee", "Rezvoglar"], delivery: .injection,
                       halfLifeHours: .init(min: 12, max: 12), halfLifeNote: "~12 hours",
                       durationHours: .init(min: 24, max: 24)),
        InsulinProfile(id: "long-glargine-u300", category: "Long-acting (glargine U-300)",
                       brandNames: ["Toujeo"], delivery: .injection,
                       halfLifeHours: .init(min: 19, max: 19), halfLifeNote: "~19 hours",
                       durationHours: .init(min: 24, max: nil)),
        InsulinProfile(id: "long-detemir", category: "Long-acting (detemir)",
                       brandNames: ["Levemir (discontinued in the US)"], delivery: .injection,
                       halfLifeHours: .init(min: 5, max: 7), halfLifeNote: "~5–7 hours (dose-dependent)",
                       durationHours: .init(min: 6, max: 24)),
        InsulinProfile(id: "ultra-long-degludec", category: "Ultra-long-acting (degludec)",
                       brandNames: ["Tresiba"], delivery: .injection,
                       halfLifeHours: .init(min: 25, max: 25), halfLifeNote: "~25 hours",
                       durationHours: .init(min: 42, max: nil)),
        InsulinProfile(id: "inhaled-rapid", category: "Inhaled rapid-acting",
                       brandNames: ["Afrezza"], delivery: .inhaled,
                       halfLifeHours: .init(min: 1, max: 1), halfLifeNote: "~1 hour",
                       durationHours: .init(min: 3, max: 5)),
    ]

    static func profile(forBrand brand: String) -> InsulinProfile? {
        all.first { $0.brandNames.contains { $0.lowercased().hasPrefix(brand.lowercased()) } }
    }
}
