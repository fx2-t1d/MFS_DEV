import Foundation

/// One time frame of a profile. It runs from `startMinute` until the next segment starts;
/// the last segment of the day wraps around to the first.
struct ProfileSegment: Identifiable, Codable, Equatable {
    var id = UUID()
    /// Minutes after midnight, 0...1439.
    var startMinute: Int
    /// Units per hour.
    var basalUnitsPerHour: Double
    /// How far one unit drops glucose, in mg/dL.
    var sensitivityMgdlPerUnit: Double
}

struct InsulinProfile: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var isMain = false
    var segments: [ProfileSegment]

    var sortedSegments: [ProfileSegment] { segments.sorted { $0.startMinute < $1.startMinute } }

    func segment(atMinute minute: Int) -> ProfileSegment? {
        let sorted = sortedSegments
        return sorted.last { $0.startMinute <= minute } ?? sorted.last
    }

    /// Minute at which the segment ends (the next start, wrapping past midnight).
    func endMinute(of segment: ProfileSegment) -> Int {
        let sorted = sortedSegments
        guard let index = sorted.firstIndex(where: { $0.id == segment.id }) else { return segment.startMinute }
        return sorted[(index + 1) % sorted.count].startMinute
    }

    var issues: [String] {
        var found: [String] = []
        if name.trimmingCharacters(in: .whitespaces).isEmpty { found.append("Enter a profile name.") }
        if segments.isEmpty { found.append("Add at least one time frame.") }
        if Set(segments.map(\.startMinute)).count != segments.count { found.append("Two time frames start at the same time.") }
        for segment in segments {
            if !(0..<1440).contains(segment.startMinute) { found.append("A start time is out of range.") }
            if !segment.basalUnitsPerHour.isFinite || segment.basalUnitsPerHour < 0 { found.append("Basal must be 0 or more units/hour.") }
            if !segment.sensitivityMgdlPerUnit.isFinite || segment.sensitivityMgdlPerUnit <= 0 { found.append("Sensitivity must be more than 0 mg/dL per unit.") }
        }
        return Array(Set(found)).sorted()
    }

    static func minuteOfDay(_ date: Date, calendar: Calendar = .current) -> Int {
        calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date)
    }
}

/// Automation hook: something that can ask for a profile to be used (illness detection, exercise, a schedule).
/// No hooks exist yet; the store only consults whatever is registered.
enum ProfileSwitchDecision: Equatable {
    case noOpinion
    case useMain
    case use(UUID)
}

struct ProfileSwitchContext {
    var date: Date
    var glucose: Double?
}

protocol ProfileSwitchHook {
    var name: String { get }
    func decision(in context: ProfileSwitchContext, profiles: [InsulinProfile]) -> ProfileSwitchDecision
}

enum ProfileActivationSource: String, Codable { case manual, automatic }

final class InsulinProfileStore: ObservableObject {
    private struct Saved: Codable {
        var profiles: [InsulinProfile]
        var activeID: UUID?
        var source: ProfileActivationSource?
    }

    /// Always holds exactly one main profile, first in the list.
    @Published private(set) var profiles: [InsulinProfile]
    /// The event profile in effect; nil means the main profile.
    @Published private(set) var activeEventID: UUID?
    @Published private(set) var activationSource: ProfileActivationSource?
    var hooks: [ProfileSwitchHook] = []

    private let defaults: UserDefaults
    private let key = "MFS.InsulinProfiles"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key), let saved = try? JSONDecoder().decode(Saved.self, from: data),
           saved.profiles.first?.isMain == true {
            profiles = saved.profiles
            activeEventID = saved.activeID
            activationSource = saved.source
        } else {
            profiles = [InsulinProfile(name: "Main", isMain: true, segments: [])]
        }
    }

    var main: InsulinProfile { profiles[0] }
    var alternatives: [InsulinProfile] { Array(profiles.dropFirst()) }
    var active: InsulinProfile { profiles.first { $0.id == activeEventID && !$0.isMain } ?? main }

    func segment(at date: Date) -> ProfileSegment? {
        active.segment(atMinute: InsulinProfile.minuteOfDay(date))
    }

    /// Adds or replaces. The main profile can be edited but never removed or renamed away from main.
    func save(_ profile: InsulinProfile) {
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            var updated = profile
            updated.isMain = profiles[index].isMain
            profiles[index] = updated
        } else {
            var added = profile
            added.isMain = false
            profiles.append(added)
        }
        persist()
    }

    func delete(_ id: UUID) {
        guard let profile = profiles.first(where: { $0.id == id }), !profile.isMain else { return }
        profiles.removeAll { $0.id == id }
        if activeEventID == id { activeEventID = nil; activationSource = nil }
        persist()
    }

    /// Manual choice; nil returns to the main profile. A manual choice is not overridden by hooks.
    func activate(_ id: UUID?, source: ProfileActivationSource = .manual) {
        if let id, profiles.contains(where: { $0.id == id && !$0.isMain }) {
            activeEventID = id
            activationSource = source
        } else {
            activeEventID = nil
            activationSource = nil
        }
        persist()
    }

    /// Asks the registered hooks, in order, and applies the first opinion. Does nothing while a manual choice is in effect.
    func evaluateHooks(_ context: ProfileSwitchContext) {
        guard activationSource != .manual else { return }
        for hook in hooks {
            switch hook.decision(in: context, profiles: profiles) {
            case .noOpinion: continue
            case .useMain: activate(nil, source: .automatic); return
            case .use(let id): activate(id, source: .automatic); return
            }
        }
    }

    private func persist() {
        defaults.set(try? JSONEncoder().encode(Saved(profiles: profiles, activeID: activeEventID, source: activationSource)), forKey: key)
    }
}
