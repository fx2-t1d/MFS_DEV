import SwiftUI
import UIKit
import CoreBluetooth
import LoopKit
import LoopKitUI
import OmnipodKit

/// Pod activation is the one place MFS lets OmnipodKit command the pump (pair, prime, insert cannula).
/// It runs only through OmnipodKit's own setup screens; MFS never calls a delivery command itself
/// (see scripts/check_no_delivery_commands.sh). The pod then delivers the basal entered below on its own.

/// Therapy values the pod is programmed with. No defaults: the user must enter their own.
struct PodSetupValues {
    var basalRate = ""
    var maxBasalRate = ""
    var maxBolus = ""
    var confirmed = false

    private func supported(_ text: String, in values: [Double]) -> Double? {
        guard let value = Double(text.replacingOccurrences(of: ",", with: ".")),
              let nearest = values.min(by: { abs($0 - value) < abs($1 - value) }),
              abs(nearest - value) < 1e-6 else { return nil }
        return value
    }

    var basal: Double? { supported(basalRate, in: OmniPumpManager.onboardingSupportedBasalRates) }
    var maxBasal: Double? { supported(maxBasalRate, in: OmniPumpManager.onboardingSupportedBasalRates) }
    var maxBolusUnits: Double? { supported(maxBolus, in: OmniPumpManager.onboardingSupportedMaximumBolusVolumes) }

    var problem: String? {
        guard let basal, let maxBasal, maxBolusUnits != nil else {
            return "Enter basal, maximum basal and maximum bolus as multiples of 0.05 U."
        }
        if basal > maxBasal { return "Basal cannot be higher than the maximum basal." }
        return nil
    }

    var setupSettings: PumpManagerSetupSettings? {
        guard problem == nil, confirmed, let basal, let maxBasal, let maxBolusUnits,
              let schedule = BasalRateSchedule(
                dailyItems: [RepeatingScheduleValue(startTime: 0, value: basal)],
                timeZone: .current)
        else { return nil }
        return PumpManagerSetupSettings(maxBasalRateUnitsPerHour: maxBasal, maxBolusUnits: maxBolusUnits, basalSchedule: schedule)
    }
}

final class MFSBluetoothProvider: NSObject, BluetoothProvider, CBCentralManagerDelegate {
    private var central: CBCentralManager?
    private var observers: [(BluetoothObserver, DispatchQueue)] = []
    private var authorizationCompletions: [(BluetoothAuthorization) -> Void] = []

    var bluetoothAuthorization: BluetoothAuthorization {
        switch CBCentralManager.authorization {
        case .allowedAlways: return .authorized
        case .denied: return .denied
        case .restricted: return .restricted
        default: return .notDetermined
        }
    }

    var bluetoothState: BluetoothState {
        guard bluetoothAuthorization == .authorized, let central else { return .unknown }
        switch central.state {
        case .resetting: return .resetting
        case .unsupported: return .unsupported
        case .unauthorized: return .unauthorized
        case .poweredOff: return .poweredOff
        case .poweredOn: return .poweredOn
        default: return .unknown
        }
    }

    func authorizeBluetooth(_ completion: @escaping (BluetoothAuthorization) -> Void) {
        authorizationCompletions.append(completion)
        if central == nil { central = CBCentralManager(delegate: self, queue: .main) }
    }

    func addBluetoothObserver(_ observer: BluetoothObserver, queue: DispatchQueue) {
        observers.append((observer, queue))
        if central == nil, bluetoothAuthorization == .authorized {
            central = CBCentralManager(delegate: self, queue: .main)
        }
    }

    func removeBluetoothObserver(_ observer: BluetoothObserver) {
        observers.removeAll { $0.0 === observer }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let authorization = bluetoothAuthorization
        let state = bluetoothState
        authorizationCompletions.forEach { $0(authorization) }
        authorizationCompletions.removeAll()
        observers.forEach { observer, queue in queue.async { observer.bluetoothDidUpdateState(state) } }
    }
}

enum OmnipodSetup {
    static let bluetooth = MFSBluetoothProvider()

    static let palette = LoopUIColorPalette(
        guidanceColors: GuidanceColors(acceptable: .green, warning: .orange, critical: .red),
        carbTintColor: .green,
        glucoseTintColor: .blue,
        insulinTintColor: .orange,
        loopStatusColorPalette: StateColorPalette(unknown: .gray, normal: .green, warning: .orange, error: .red),
        chartColorPalette: ChartColorPalette(axisLine: .gray, axisLabel: .darkGray, grid: .lightGray, glucoseTint: .blue, insulinTint: .orange, carbTint: .green)
    )

    static let insulinTypes: [InsulinType] = [.novolog, .humalog, .apidra, .fiasp, .lyumjev]
}

/// Hosts OmnipodKit's own setup or settings screens.
struct OmnipodFlowView: UIViewControllerRepresentable {
    enum Mode {
        case setup(PumpManagerSetupSettings)
        case settings(OmniPumpManager)
    }

    let mode: Mode
    @ObservedObject var reader: OmnipodHistoryReader
    let onFinish: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    func makeUIViewController(context: Context) -> UIViewController {
        var flow: PumpManagerViewController
        switch mode {
        case .setup(let settings):
            let result = OmniPumpManager.setupViewController(
                initialSettings: settings,
                bluetoothProvider: OmnipodSetup.bluetooth,
                colorPalette: OmnipodSetup.palette,
                allowDebugFeatures: false,
                prefersToSkipUserInteraction: false,
                allowedInsulinTypes: OmnipodSetup.insulinTypes)
            switch result {
            case .userInteractionRequired(let vc):
                flow = vc
            case .createdAndOnboarded(let created):
                if let manager = created as? OmniPumpManager { reader.adopt(manager) }
                DispatchQueue.main.async(execute: onFinish)
                return UIViewController()
            }
        case .settings(let manager):
            flow = manager.settingsViewController(
                bluetoothProvider: OmnipodSetup.bluetooth,
                colorPalette: OmnipodSetup.palette,
                allowDebugFeatures: false,
                allowedInsulinTypes: OmnipodSetup.insulinTypes)
        }
        var onboarding = flow
        onboarding.pumpManagerOnboardingDelegate = reader
        flow.completionDelegate = context.coordinator
        return flow
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}

    final class Coordinator: NSObject, CompletionDelegate {
        let onFinish: () -> Void
        init(onFinish: @escaping () -> Void) { self.onFinish = onFinish }

        func completionNotifyingDidComplete(_ object: CompletionNotifying) {
            DispatchQueue.main.async(execute: onFinish)
        }
    }
}

struct OmnipodSection: View {
    @ObservedObject var reader: OmnipodHistoryReader
    @State private var values = PodSetupValues()
    @State private var showForm = false
    @State private var flow: OmnipodFlowView.Mode?

    var body: some View {
        Section("Omnipod DASH") {
            if let summary = reader.podSummary {
                LabeledContent("Status", value: summary.status)
                if let expires = summary.expiresAt {
                    LabeledContent("Pod expires", value: expires.formatted(date: .abbreviated, time: .shortened))
                }
                if let units = reader.reservoir?.unitVolume {
                    LabeledContent("Reservoir", value: "\(units.formatted(.number.precision(.fractionLength(0...1)))) U")
                }
                if let manager = reader.manager {
                    Button("Pod settings and deactivation") { flow = .settings(manager) }
                }
            } else {
                LabeledContent("Status", value: "No pod")
                Text("Pairing activates a new pod from this app: pair, prime, then insert the cannula. The pod then answers only to MFS, not to the Omnipod app or Loop, and it starts delivering the basal you enter. Have a new pod and your insulin ready.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("Pair a new pod") { showForm = true }
            }
            if let error = reader.lastError {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
        }
        .sheet(isPresented: $showForm) {
            PodSetupForm(values: $values) { settings in
                showForm = false
                reader.connectNew()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { flow = .setup(settings) }
            }
        }
        .fullScreenCover(isPresented: Binding(get: { flow != nil }, set: { if !$0 { flow = nil } })) {
            if let mode = flow {
                OmnipodFlowView(mode: mode, reader: reader) { flow = nil }
                    .ignoresSafeArea()
            }
        }
    }
}

private struct PodSetupForm: View {
    @Binding var values: PodSetupValues
    let start: (PumpManagerSetupSettings) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    field("Basal rate (U/h)", text: $values.basalRate)
                    field("Maximum basal rate (U/h)", text: $values.maxBasalRate)
                    field("Maximum bolus (U)", text: $values.maxBolus)
                } header: {
                    Text("Pod settings")
                } footer: {
                    Text("Enter your own values; there are no defaults. MFS supports one flat basal rate across all 24 hours. If your basal changes during the day, do not pair here.")
                }
                if let problem = values.problem, !values.basalRate.isEmpty || !values.maxBasalRate.isEmpty || !values.maxBolus.isEmpty {
                    Text(problem).font(.footnote).foregroundStyle(.red)
                }
                Section {
                    Toggle("These match my prescribed therapy settings", isOn: $values.confirmed)
                    Button("Continue to pod setup") {
                        if let settings = values.setupSettings { start(settings) }
                    }
                    .disabled(values.setupSettings == nil)
                }
            }
            .navigationTitle("Pair a new pod")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }

    private func field(_ title: String, text: Binding<String>) -> some View {
        LabeledContent(title) {
            TextField("Required", text: text)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
        }
    }
}
