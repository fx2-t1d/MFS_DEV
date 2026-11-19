import Foundation
import LoopKit
import G7SensorKit

/// Hosts a `G7CGMManager` and exposes its glucose readings. Read-only.
final class G7GlucoseHost: CGMHostBase, ObservableObject, G7StateObserver {
    enum Pairing: Equatable {
        case notPaired
        case searching
        case paired(name: String, lifecycle: G7SensorLifecycleState)
    }

    @Published private(set) var sensorStatus: CGMManagerStatus?
    @Published private(set) var pairing: Pairing = .notPaired
    @Published private(set) var isConnected = false
    @Published private(set) var sensorExpiresAt: Date?

    private let store: DeviceStateStore
    private(set) var manager: G7CGMManager

    init(feed: GlucoseFeed, store: DeviceStateStore = DeviceStateStore(key: "MFS.G7CGMManager.rawState")) {
        self.store = store
        if let rawState = store.load(), let restored = G7CGMManager(rawState: rawState) {
            manager = restored
        } else {
            manager = G7CGMManager()
        }
        super.init(feed: feed, queueLabel: "MFS.G7GlucoseHost")
        manager.cgmManagerDelegate = self
        manager.delegateQueue = queue
        store.save(manager.rawState)
        manager.addStateObserver(self, queue: .main)
        refreshPairing()
    }

    /// G7 pairs by listening for a sensor that was just started; no code is entered.
    func startPairing() {
        manager.scanForNewSensor()
        store.save(manager.rawState)
        refreshPairing()
    }

    func refreshPairing() {
        let manager = manager
        if let name = manager.sensorName {
            pairing = .paired(name: name, lifecycle: manager.lifecycleState)
        } else {
            pairing = manager.isScanning ? .searching : .notPaired
        }
        isConnected = manager.isConnected
        sensorExpiresAt = manager.sensorExpiresAt
    }

    func g7StateDidUpdate(_ state: G7CGMManagerState?) { refreshPairing() }

    func g7ConnectionStatusDidChange() { refreshPairing() }

    func fetchNewData() {
        manager.fetchNewDataIfNeeded { [weak self] result in
            self?.handle(result)
        }
    }

    override var credentialPrefix: String { "MFS.G7" }

    override func handle(_ result: CGMReadingResult) {
        super.handle(result)
        store.save(manager.rawState)
    }

    override func stateDidChange(_ manager: CGMManager) {
        store.save(manager.rawState)
    }

    override func statusDidChange(_ status: CGMManagerStatus) {
        DispatchQueue.main.async { self.sensorStatus = status }
    }

    override func wantsDeletion(_ manager: CGMManager) {
        store.clear()
    }
}
