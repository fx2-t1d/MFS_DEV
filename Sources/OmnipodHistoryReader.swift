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

    typealias HistoryEvent = PumpHistoryEvent

    struct ReservoirReading: ReservoirValue, Equatable {
        let startDate: Date
        let unitVolume: Double
    }

    @Published private(set) var reservoir: ReservoirReading?
    @Published private(set) var history: [HistoryEvent]
    @Published private(set) var lastError: String?
    /// nil when no pod is paired.
    @Published private(set) var podSummary: PodSummary?

    private let store: DeviceStateStore
    @Published private(set) var manager: OmniPumpManager?

    /// Without saved state there is no manager until a pod is paired through `OmnipodFlowView`.
    init(store: DeviceStateStore = DeviceStateStore(key: "MFS.OmniPumpManager.rawState")) {
        self.store = store
        history = HistoryDatabase.shared.pumpEvents()
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
        if let created = pumpManager as? OmniPumpManager { adopt(created) }
    }

    @MainActor func pumpManagerOnboarding(didOnboardPumpManager pumpManager: PumpManagerUI) {
        if let created = pumpManager as? OmniPumpManager { adopt(created) }
    }

    @MainActor func pumpManagerOnboarding(didPauseOnboarding pumpManager: PumpManagerUI) {}

    // MARK: PumpManagerDelegate

    func pumpManager(_ pumpManager: PumpManager, hasNewPumpEvents events: [NewPumpEvent], lastReconciliation: Date?, replacePendingEvents: Bool) async throws {
        let new = events.map { HistoryEvent(date: $0.date, title: $0.title) }
        await MainActor.run {
            let known = Set(self.history)
            let added = new.filter { !known.contains($0) }
            self.history = (self.history + added).sorted { $0.date < $1.date }
            HistoryDatabase.shared.addPumpEvents(added)
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
        await MainActor.run { self.lastError = error.localizedDescription }
    }

    func pumpManagerDidUpdateState(_ pumpManager: PumpManager) async {
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
        completion?(nil)
    }

    @MainActor func issueAlert(_ alert: Alert) async {}

    @MainActor func retractAlert(identifier: Alert.Identifier) async {}

    func doesIssuedAlertExist(identifier: Alert.Identifier) async throws -> Bool { false }

    func lookupAllUnretracted(managerIdentifier: String) async throws -> [PersistedAlert] { [] }

    func lookupAllUnacknowledgedUnretracted(managerIdentifier: String) async throws -> [PersistedAlert] { [] }

    func recordRetractedAlert(_ alert: Alert, at date: Date) async throws {}
}
