import Foundation

/// Shared flow for every device in Connect devices: nothing connects until the user asks,
/// and any existing connection is dropped before a new one starts.
protocol DeviceConnection: AnyObject {
    var hasConnectedDevice: Bool { get }
    func disconnect()
    func beginPairing()
}

extension DeviceConnection {
    func connectNew() {
        if hasConnectedDevice { disconnect() }
        beginPairing()
    }
}

extension G7GlucoseHost: DeviceConnection {}
extension OmnipodHistoryReader: DeviceConnection {}
