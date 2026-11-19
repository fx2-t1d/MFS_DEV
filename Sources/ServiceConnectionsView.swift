import CryptoKit
import HealthKit
import SwiftUI
import UniformTypeIdentifiers

/// Secrets and client identities live in the Keychain, never in UserDefaults.
enum ServiceKeychain {
    private static let service = "MFS.ServiceSecrets"

    private static func query(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: id.uuidString]
    }

    static func hasSecret(for id: UUID) -> Bool {
        var q = query(id)
        q[kSecReturnData as String] = false
        return SecItemCopyMatching(q as CFDictionary, nil) == errSecSuccess
    }

    static func secret(for id: UUID) -> String? {
        var q = query(id)
        q[kSecReturnData as String] = true
        var result: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func setSecret(_ value: String, for id: UUID) {
        SecItemDelete(query(id) as CFDictionary)
        var q = query(id)
        q[kSecValueData as String] = Data(value.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(q as CFDictionary, nil)
    }

    static func deleteSecret(for id: UUID) { SecItemDelete(query(id) as CFDictionary) }

    /// Value to send in the header: the secret, or its SHA-1 hex digest for Nightscout-style API secrets.
    static func headerValue(for connection: ServiceConnection) -> String? {
        guard let secret = secret(for: connection.id) else { return nil }
        guard connection.hashSecretSHA1 else { return secret }
        return Insecure.SHA1.hash(data: Data(secret.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func importIdentity(p12: Data, password: String, label: String) throws {
        var items: CFArray?
        let status = SecPKCS12Import(p12 as CFData, [kSecImportExportPassphrase as String: password] as CFDictionary, &items)
        guard status == errSecSuccess,
              let first = (items as? [[String: Any]])?.first,
              let identity = first[kSecImportItemIdentity as String] else {
            throw ServiceKeychainError.importFailed(status)
        }
        deleteIdentity(label: label)
        let add = SecItemAdd([kSecValueRef as String: identity, kSecAttrLabel as String: label] as CFDictionary, nil)
        guard add == errSecSuccess else { throw ServiceKeychainError.importFailed(add) }
    }

    static func deleteIdentity(label: String) {
        SecItemDelete([kSecClass as String: kSecClassIdentity, kSecAttrLabel as String: label] as CFDictionary)
    }
}

enum ServiceKeychainError: LocalizedError {
    case importFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .importFailed(let status): return "Could not import the certificate. Check the file and password (code \(status))."
        }
    }
}

struct ServiceConnectionsView: View {
    @EnvironmentObject private var store: ServiceConnectionStore
    @Environment(\.dismiss) private var dismiss
    @State private var editing: ServiceConnection?
    @State private var healthMessage: String?

    var body: some View {
        NavigationStack {
            List {
                Section("Services") {
                    ForEach(store.connections) { connection in
                        Button { editing = connection } label: {
                            VStack(alignment: .leading) {
                                Text(connection.name).foregroundStyle(.primary)
                                Text("\(connection.baseURL) · \(connection.auth.label)").font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .onDelete { offsets in
                        for index in offsets {
                            let connection = store.connections[index]
                            ServiceKeychain.deleteSecret(for: connection.id)
                            if let label = connection.identityLabel { ServiceKeychain.deleteIdentity(label: label) }
                            store.delete(connection.id)
                        }
                    }
                    Menu {
                        Button("Nightscout (shared secret)") { editing = .nightscout() }
                        Button("Client certificate (mTLS)") { editing = .mutualTLSService() }
                        Button("Other") { editing = ServiceConnection(name: "", baseURL: "https://") }
                    } label: {
                        Label("Add service", systemImage: "plus")
                    }
                }

                Section {
                    ForEach(HealthDataKind.allCases) { kind in
                        Toggle(kind.label, isOn: Binding(
                            get: { store.healthKinds.contains(kind) },
                            set: { on in if on { store.healthKinds.insert(kind) } else { store.healthKinds.remove(kind) } }))
                    }
                    Button(store.healthRequested ? "Review Apple Health access" : "Connect Apple Health", systemImage: "heart.text.square") {
                        Task { await requestHealth() }
                    }
                    .disabled(store.healthKinds.isEmpty)
                    if let healthMessage { Text(healthMessage).font(.footnote).foregroundStyle(.secondary) }
                } header: {
                    Text("Apple Health")
                } footer: {
                    Text("Read only. iOS does not tell apps whether read access was granted; change it in Settings > Health > Data Access.")
                }
            }
            .navigationTitle("Service connections")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
            .sheet(item: $editing) { connection in
                ServiceConnectionForm(connection: connection)
            }
        }
    }

    private func requestHealth() async {
        guard HKHealthStore.isHealthDataAvailable() else { healthMessage = "Apple Health is not available on this device."; return }
        var types = Set<HKObjectType>()
        for kind in store.healthKinds {
            switch kind {
            case .heartRate: types.insert(HKQuantityType(.heartRate))
            case .sleep: types.insert(HKCategoryType(.sleepAnalysis))
            case .heartRateVariability: types.insert(HKQuantityType(.heartRateVariabilitySDNN))
            }
        }
        do {
            try await HKHealthStore().requestAuthorization(toShare: [], read: types)
            store.markHealthRequested()
            healthMessage = "Permission sheet completed."
        } catch {
            healthMessage = "Apple Health request failed: \(error.localizedDescription)"
        }
    }
}

private struct ServiceConnectionForm: View {
    @EnvironmentObject private var store: ServiceConnectionStore
    @Environment(\.dismiss) private var dismiss
    @State var connection: ServiceConnection
    @State private var secret = ""
    @State private var certificatePassword = ""
    @State private var showImporter = false
    @State private var importMessage: String?

    private var hasSavedSecret: Bool { ServiceKeychain.hasSecret(for: connection.id) }
    private var needsSecret: Bool { connection.auth == .sharedSecretHeader || connection.auth == .bearerToken }

    var body: some View {
        NavigationStack {
            Form {
                Section("Service") {
                    TextField("Name", text: $connection.name)
                    TextField("https://", text: $connection.baseURL)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Toggle("Enabled", isOn: $connection.enabled)
                }
                Section("Authentication") {
                    Picker("Method", selection: $connection.auth) {
                        ForEach(ServiceAuthMethod.allCases) { Text($0.label).tag($0) }
                    }
                    if connection.auth == .sharedSecretHeader {
                        TextField("Header name", text: $connection.headerName)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        Toggle("Send SHA-1 of the secret", isOn: $connection.hashSecretSHA1)
                    }
                    if needsSecret {
                        SecureField(hasSavedSecret ? "Secret saved; type to replace" : "Secret", text: $secret)
                    }
                    if connection.auth == .mutualTLS {
                        if let label = connection.identityLabel {
                            Label("Certificate imported", systemImage: "checkmark.seal").foregroundStyle(.secondary)
                            Text(label).font(.footnote).foregroundStyle(.secondary)
                        }
                        SecureField("Certificate file password", text: $certificatePassword)
                        Button(connection.identityLabel == nil ? "Import .p12 certificate" : "Replace certificate", systemImage: "doc.badge.plus") {
                            showImporter = true
                        }
                        if let importMessage { Text(importMessage).font(.footnote).foregroundStyle(.red) }
                    }
                }
                if !connection.issues.isEmpty {
                    Section { ForEach(connection.issues, id: \.self) { Text($0).font(.footnote).foregroundStyle(.red) } }
                }
            }
            .navigationTitle(connection.name.isEmpty ? "New service" : connection.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!connection.issues.isEmpty || (needsSecret && secret.isEmpty && !hasSavedSecret))
                }
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.pkcs12]) { result in
                importCertificate(result)
            }
        }
    }

    private func importCertificate(_ result: Result<URL, Error>) {
        guard case .success(let url) = result else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let label = connection.identityLabel ?? "MFS.mtls.\(connection.id.uuidString)"
            try ServiceKeychain.importIdentity(p12: try Data(contentsOf: url), password: certificatePassword, label: label)
            connection.identityLabel = label
            certificatePassword = ""
            importMessage = nil
        } catch {
            importMessage = error.localizedDescription
        }
    }

    private func save() {
        connection.name = connection.name.trimmingCharacters(in: .whitespaces)
        connection.baseURL = connection.baseURL.trimmingCharacters(in: .whitespaces)
        if needsSecret {
            if !secret.isEmpty { ServiceKeychain.setSecret(secret, for: connection.id) }
        } else {
            ServiceKeychain.deleteSecret(for: connection.id)
        }
        store.save(connection)
        dismiss()
    }
}
