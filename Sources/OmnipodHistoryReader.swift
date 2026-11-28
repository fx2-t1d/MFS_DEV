import Foundation
import LoopKit
import LoopKitUI
import OmnipodKit

/// Restores a previously paired Omnipod DASH manager and records its reservoir and history callbacks.
/// This type never issues delivery commands (enforced by scripts/check_no_delivery_commands.sh);
/// pod activation runs only through OmnipodKit's own setup screens (see OmnipodPairing.swift).
final class OmnipodHistoryReader: NSObject, ObservableObject, PumpManagerDelegate, PumpManagerOnboardingDelegate {
    struct PodSummary: Equatable {
        let status: String
        let expiresAt: Date?
    }

    struct HistoryEvent: Hashable, Codable {
        let date: Date
        let title: String
        /// From the pump kit's dose: "bolus", "tempBasal", "basal", "suspend" or "resume"; nil for events without a dose.
        var doseKind: String? = nil
        /// Bolus units delivered.
        var units: Double? = nil
        /// Basal rate in units per hour, running until `endDate`.
        var unitsPerHour: Double? = nil
        var endDate: Date? = nil
    }

    struct ReservoirReading: ReservoirValue, Equatable {
        let startDate: Date
        let unitVolume: Double
    }

    @Published private(set) var reservoir: ReservoirReading?
    @Published private(set) var history: [HistoryEvent]
    private let historyStore = HistoryStore<HistoryEvent>(filename: "pump-history.json")
    @Published private(set) var lastError: String?
    /// nil when no pod is paired.
    @Published private(set) var podSummary: PodSummary?

    private let store: DeviceStateStore
    @Published private(set) var manager: OmniPumpManager?

    /// Without saved state there is no manager until a pod is paired through `OmnipodFlowView`.
    init(store: DeviceStateStore = DeviceStateStore(key: "MFS.OmniPumpManager.rawState")) {
        self.store = store
        history = historyStore.load()
        super.init()
        if let rawState = store.load(), let restored = OmniPumpManager(rawState: rawState) {
            restored.pumpManagerDelegate = self
            manager = restored
        }
        refreshSummary()
    }

    var hasConnectedDevice: Bool { manager != nil }

    /// Drops a stale manager (one with no active pod) so setup starts from a clean state.
    func disconnect() {
        manager?.pumpManagerDelegate = nil
        manager = nil
        store.clear()
        podSummary = nil
    }

    func beginPairing() {}

    /// Takes over a manager created by OmnipodKit's setup flow.
    func adopt(_ newManager: OmniPumpManager) {
        newManager.pumpManagerDelegate = self
        store.save(newManager.rawState)
        DispatchQueue.main.async {
            self.manager = newManager
            self.refreshSummary()
        }
    }

    func refreshSummary() {
        guard let manager, let pod = manager.state.podState else {
            podSummary = nil
            return
        }
        let status = manager.isOnboarded ? "Active" : "Setting up"
        podSummary = PodSummary(status: status, expiresAt: pod.expiresAt)
    }

    // MARK: PumpManagerOnboardingDelegate

    @MainActor func pumpManagerOnboarding(didCreatePumpManager pumpManager: PumpManagerUI) {
        DiagnosticsLog.shared.record("Omnipod", "Pump manager created")
        if let created = pumpManager as? OmniPumpManager { adopt(created) }
    }

    @MainActor func pumpManagerOnboarding(didOnboardPumpManager pumpManager: PumpManagerUI) {
        DiagnosticsLog.shared.record("Omnipod", "Pump manager onboarded")
        if let created = pumpManager as? OmniPumpManager { adopt(created) }
    }

    @MainActor func pumpManagerOnboarding(didPauseOnboarding pumpManager: PumpManagerUI) {}

    // MARK: PumpManagerDelegate

    func pumpManager(_ pumpManager: PumpManager, hasNewPumpEvents events: [NewPumpEvent], lastReconciliation: Date?, replacePendingEvents: Bool) async throws {
        let new = events.map { HistoryEvent($0) }
        await MainActor.run {
            // Same moment and title is the same event; the newer record carries the dose amounts.
            var byKey: [String: HistoryEvent] = [:]
            for event in self.history + new { byKey["\(event.date.timeIntervalSince1970)|\(event.title)"] = event }
            self.history = byKey.values.sorted { $0.date < $1.date }
            self.historyStore.save(self.history)
        }
    }

    func pumpManager(_ pumpManager: PumpManager, didReadReservoirValue units: Double, at date: Date) async throws -> (newValue: ReservoirValue, lastValue: ReservoirValue?, areStoredValuesContinuous: Bool) {
        let value = ReservoirReading(startDate: date, unitVolume: units)
        let previous = await MainActor.run { () -> ReservoirReading? in
            let previous = self.reservoir
            self.reservoir = value
            return previous
        }
        return (newValue: value, lastValue: previous, areStoredValuesContinuous: true)
    }

    func pumpManager(_ pumpManager: PumpManager, didError error: PumpManagerError) async {
        DiagnosticsLog.shared.record("Omnipod", "Pump error: \(error)")
        await MainActor.run { self.lastError = error.localizedDescription }
    }

    func pumpManagerDidUpdateState(_ pumpManager: PumpManager) async {
        DiagnosticsLog.shared.record("Omnipod", "State updated")
        store.save(pumpManager.rawState)
        await MainActor.run { self.refreshSummary() }
    }

    func pumpManagerWantsDeletion(_ pumpManager: PumpManager) async {
        store.clear()
        await MainActor.run {
            self.manager = nil
            self.refreshSummary()
        }
    }

    func startDateToFilterNewPumpEvents(for manager: PumpManager) async -> Date {
        Date().addingTimeInterval(-24 * 60 * 60)
    }

    // MARK: Unused callbacks and fixed answers

    var detectedSystemTimeOffset: TimeInterval { 0 }

    @MainActor var automaticDosingEnabled: Bool { false }

    @MainActor var automatedTreatmentState: AutomatedTreatmentState? { nil }

    func pumpManagerBLEHeartbeatDidFire(_ pumpManager: PumpManager) async {}

    func pumpManagerMustProvideBLEHeartbeat(_ pumpManager: PumpManager) async -> Bool { false }

    func pumpManagerPumpWasReplaced(_ pumpManager: PumpManager) async {}

    func pumpManager(_ pumpManager: PumpManager, didUpdatePumpRecordsBasalProfileStartEvents pumpRecordsBasalProfileStartEvents: Bool) async {}

    func pumpManager(_ pumpManager: PumpManager, didAdjustPumpClockBy adjustment: TimeInterval) async {}

    func pumpManager(_ pumpManager: PumpManager, didUpdate status: PumpManagerStatus, oldStatus: PumpManagerStatus) {}

    func pumpManager(_ pumpManager: PumpManager, didRequestBasalRateScheduleChange basalRateSchedule: BasalRateSchedule) async throws {
        throw NSError(domain: "MFS.OmnipodHistoryReader", code: 1, userInfo: [NSLocalizedDescriptionKey: "MFS is read-only and does not change pump settings."])
    }

    // MARK: DeviceManagerDelegate

    func deviceManager(_ manager: DeviceManager, logEventForDeviceIdentifier deviceIdentifier: String?, type: DeviceLogEntryType, message: String, completion: ((Error?) -> Void)?) {
        DiagnosticsLog.shared.record("Omnipod", "Pod log (\(type)): \(message)")
        completion?(nil)
    }

    @MainActor func issueAlert(_ alert: Alert) async {
        let content = alert.foregroundContent ?? alert.backgroundContent
        DiagnosticsLog.shared.record("Omnipod", "Alert issued \(alert.identifier.alertIdentifier): \(content.title) - \(content.body)")
    }

    @MainActor func retractAlert(identifier: Alert.Identifier) async {
        DiagnosticsLog.shared.record("Omnipod", "Alert retracted \(identifier.alertIdentifier)")
    }

    func doesIssuedAlertExist(identifier: Alert.Identifier) async throws -> Bool { false }

    func lookupAllUnretracted(managerIdentifier: String) async throws -> [PersistedAlert] { [] }

    func lookupAllUnacknowledgedUnretracted(managerIdentifier: String) async throws -> [PersistedAlert] { [] }

    func recordRetractedAlert(_ alert: Alert, at date: Date) async throws {}
}
