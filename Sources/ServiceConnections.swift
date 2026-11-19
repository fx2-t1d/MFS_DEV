import Foundation

/// How a service authenticates. Secret values never live here; they are stored in the Keychain under the connection's id.
enum ServiceAuthMethod: String, Codable, CaseIterable, Identifiable {
    case none, sharedSecretHeader, bearerToken, mutualTLS

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none: return "None"
        case .sharedSecretHeader: return "Shared secret (header)"
        case .bearerToken: return "Bearer token"
        case .mutualTLS: return "Client certificate (mTLS)"
        }
    }
}

struct ServiceConnection: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var baseURL: String
    var auth: ServiceAuthMethod = .none
    /// Header carrying the shared secret, e.g. "api-secret" for Nightscout.
    var headerName = ""
    /// Send the SHA-1 hex digest of the secret instead of the secret itself (Nightscout API secrets).
    var hashSecretSHA1 = false
    /// Keychain label of the imported client identity for mutual TLS.
    var identityLabel: String?
    var enabled = true

    static func nightscout() -> ServiceConnection {
        ServiceConnection(name: "Nightscout", baseURL: "https://", auth: .sharedSecretHeader, headerName: "api-secret", hashSecretSHA1: true)
    }

    static func mutualTLSService() -> ServiceConnection {
        ServiceConnection(name: "", baseURL: "https://", auth: .mutualTLS)
    }

    var issues: [String] {
        var found: [String] = []
        if name.trimmingCharacters(in: .whitespaces).isEmpty { found.append("Enter a name.") }
        let trimmed = baseURL.trimmingCharacters(in: .whitespaces)
        if let url = URL(string: trimmed), url.scheme == "https", let host = url.host, !host.isEmpty {
        } else {
            found.append("Enter a full https:// address.")
        }
        if auth == .sharedSecretHeader, headerName.trimmingCharacters(in: .whitespaces).isEmpty { found.append("Enter the header name.") }
        if auth == .mutualTLS, identityLabel == nil { found.append("Import a client certificate (.p12).") }
        return found
    }
}

/// Apple Health data the app may read. Authorization is requested per type; iOS does not reveal whether read access was granted.
enum HealthDataKind: String, Codable, CaseIterable, Identifiable {
    case heartRate, sleep, heartRateVariability

    var id: String { rawValue }

    var label: String {
        switch self {
        case .heartRate: return "Pulse rate (heart rate)"
        case .sleep: return "Sleep"
        case .heartRateVariability: return "Heart rate variability"
        }
    }
}

final class ServiceConnectionStore: ObservableObject {
    private struct Saved: Codable {
        var connections: [ServiceConnection]
        var healthKinds: [HealthDataKind]
        var healthRequested: Bool
    }

    @Published private(set) var connections: [ServiceConnection] = []
    @Published var healthKinds: Set<HealthDataKind> = Set(HealthDataKind.allCases) { didSet { persist() } }
    /// True once the Apple Health permission sheet has been shown for the chosen kinds.
    @Published private(set) var healthRequested = false

    private let defaults: UserDefaults
    private let key = "MFS.ServiceConnections"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key), let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            connections = saved.connections
            healthKinds = Set(saved.healthKinds)
            healthRequested = saved.healthRequested
        }
    }

    func save(_ connection: ServiceConnection) {
        if let index = connections.firstIndex(where: { $0.id == connection.id }) {
            connections[index] = connection
        } else {
            connections.append(connection)
        }
        persist()
    }

    func delete(_ id: UUID) {
        connections.removeAll { $0.id == id }
        persist()
    }

    func markHealthRequested() {
        healthRequested = true
        persist()
    }

    private func persist() {
        let saved = Saved(connections: connections, healthKinds: Array(healthKinds), healthRequested: healthRequested)
        defaults.set(try? JSONEncoder().encode(saved), forKey: key)
    }
}
