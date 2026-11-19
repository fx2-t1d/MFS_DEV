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

    struct HistoryEvent: Hashable {
        let date: Date
        let title: String
    }

    struct ReservoirReading: ReservoirValue, Equatable {
        let startDate: Date
        let unitVolume: Double
    }

    @Published private(set) var reservoir: ReservoirReading?
    @Published private(set) var history: [HistoryEvent] = []
    @Published private(set) var lastError: String?
    /// nil when no pod is paired.
    @Published private(set) var podSummary: PodSummary?

    private let store: DeviceStateStore
    private let queue = DispatchQueue(label: "MFS.OmnipodHistoryReader")
    @Published private(set) var manager: OmniPumpManager?

    /// Without saved state there is no manager until a pod is paired through `OmnipodFlowView`.
    init(store: DeviceStateStore = DeviceStateStore(key: "MFS.OmniPumpManager.rawState")) {
        self.store = store
        super.init()
        if let rawState = store.load(), let restored = OmniPumpManager(rawState: rawState) {
            restored.pumpManagerDelegate = self
            restored.delegateQueue = queue
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
        newManager.delegateQueue = queue
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

    func pumpManagerOnboarding(didCreatePumpManager pumpManager: PumpManagerUI) {
        if let created = pumpManager as? OmniPumpManager { adopt(created) }
    }

    func pumpManagerOnboarding(didOnboardPumpManager pumpManager: PumpManagerUI) {
        if let created = pumpManager as? OmniPumpManager { adopt(created) }
    }

    func pumpManagerOnboarding(didPauseOnboarding pumpManager: PumpManagerUI) {}

    // MARK: PumpManagerDelegate

    func pumpManager(_ pumpManager: PumpManager, hasNewPumpEvents events: [NewPumpEvent], lastReconciliation: Date?, replacePendingEvents: Bool, completion: @escaping (Error?) -> Void) {
        let new = events.map { HistoryEvent(date: $0.date, title: $0.title) }
        DispatchQueue.main.async {
            let known = Set(self.history)
            self.history = (self.history + new.filter { !known.contains($0) }).sorted { $0.date < $1.date }
        }
        completion(nil)
    }

    func pumpManager(_ pumpManager: PumpManager, didReadReservoirValue units: Double, at date: Date, completion: @escaping (Result<(newValue: ReservoirValue, lastValue: ReservoirValue?, areStoredValuesContinuous: Bool), Error>) -> Void) {
        let previous = reservoir
        let value = ReservoirReading(startDate: date, unitVolume: units)
        DispatchQueue.main.async { self.reservoir = value }
        completion(.success((newValue: value, lastValue: previous, areStoredValuesContinuous: true)))
    }

    func pumpManager(_ pumpManager: PumpManager, didError error: PumpManagerError) {
        DispatchQueue.main.async { self.lastError = error.localizedDescription }
    }

    func pumpManagerDidUpdateState(_ pumpManager: PumpManager) {
        store.save(pumpManager.rawState)
        DispatchQueue.main.async { self.refreshSummary() }
    }

    func pumpManagerWillDeactivate(_ pumpManager: PumpManager) {
        store.clear()
        DispatchQueue.main.async {
            self.manager = nil
            self.refreshSummary()
        }
    }

    func startDateToFilterNewPumpEvents(for manager: PumpManager) -> Date {
        Date().addingTimeInterval(-24 * 60 * 60)
    }

    // MARK: Unused callbacks and fixed answers

    var detectedSystemTimeOffset: TimeInterval { 0 }

    var automaticDosingEnabled: Bool { false }

    func pumpManagerBLEHeartbeatDidFire(_ pumpManager: PumpManager) {}

    func pumpManagerMustProvideBLEHeartbeat(_ pumpManager: PumpManager) -> Bool { false }

    func pumpManagerPumpWasReplaced(_ pumpManager: PumpManager) {}

    func pumpManager(_ pumpManager: PumpManager, didUpdatePumpRecordsBasalProfileStartEvents pumpRecordsBasalProfileStartEvents: Bool) {}

    func pumpManager(_ pumpManager: PumpManager, didAdjustPumpClockBy adjustment: TimeInterval) {}

    func pumpManager(_ pumpManager: PumpManager, didUpdate status: PumpManagerStatus, oldStatus: PumpManagerStatus) {}

    func pumpManager(_ pumpManager: PumpManager, didRequestBasalRateScheduleChange basalRateSchedule: BasalRateSchedule, completion: @escaping (Error?) -> Void) {
        completion(NSError(domain: "MFS.OmnipodHistoryReader", code: 1, userInfo: [NSLocalizedDescriptionKey: "MFS is read-only and does not change pump settings."]))
    }

    // MARK: DeviceManagerDelegate

    func deviceManager(_ manager: DeviceManager, logEventForDeviceIdentifier deviceIdentifier: String?, type: DeviceLogEntryType, message: String, completion: ((Error?) -> Void)?) {
        completion?(nil)
    }

    func issueAlert(_ alert: Alert) {}

    func retractAlert(identifier: Alert.Identifier) {}

    func doesIssuedAlertExist(identifier: Alert.Identifier, completion: @escaping (Swift.Result<Bool, Error>) -> Void) {
        completion(.success(false))
    }

    func lookupAllUnretracted(managerIdentifier: String, completion: @escaping (Swift.Result<[PersistedAlert], Error>) -> Void) {
        completion(.success([]))
    }

    func lookupAllUnacknowledgedUnretracted(managerIdentifier: String, completion: @escaping (Swift.Result<[PersistedAlert], Error>) -> Void) {
        completion(.success([]))
    }

    func recordRetractedAlert(_ alert: Alert, at date: Date) {}
}
