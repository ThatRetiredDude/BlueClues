//
//  StatusView.swift
//  BluesClues
//
//  Home screen: pick a mode, start or stop scanning, and see at a glance
//  whether anything looks like it is following you.
//

import SwiftUI
import CoreBluetooth
import CoreLocation

struct StatusView: View {
    @EnvironmentObject var deviceService: DeviceService
    @State private var selectedDeviceID: String?
    @State private var showingSettings = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Mode", selection: $deviceService.mode) {
                        ForEach(ScanMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    Text(deviceService.mode.summary)
                        .font(.footnote)
                        .foregroundColor(.secondary)

                    Button {
                        if deviceService.isScanning {
                            deviceService.stopDeviceDiscovery()
                        } else {
                            deviceService.startDeviceDiscovery()
                        }
                    } label: {
                        Label(deviceService.isScanning ? "Stop Scanning" : "Start Scanning",
                              systemImage: deviceService.isScanning ? "stop.circle.fill" : "play.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(deviceService.isScanning ? .red : .blue)
                }

                if let warning = setupWarning {
                    Section {
                        Label(warning, systemImage: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                            .font(.subheadline)
                        Button("Open Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        }
                    }
                }

                Section {
                    StatusCard(suspiciousCount: deviceService.suspiciousDevices.count,
                               isScanning: deviceService.isScanning,
                               mode: deviceService.mode)
                }

                if !deviceService.suspiciousDevices.isEmpty {
                    Section(header: Text("Needs attention")) {
                        ForEach(deviceService.suspiciousDevices) { device in
                            LiveDeviceRow(device: device, showReason: true)
                                .contentShape(Rectangle())
                                .onTapGesture { selectedDeviceID = device.id }
                        }
                    }
                }

                Section(header: Text("Trackers nearby"),
                        footer: Text("iPhone also warns you on its own about unknown AirTags and other Find My accessories. Keep Tracking Notifications on in the Find My app.")) {
                    if deviceService.nearbyTrackers.isEmpty {
                        Text(deviceService.isScanning ? "No trackers in range" : "Start scanning to look for trackers")
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(deviceService.nearbyTrackers) { device in
                            LiveDeviceRow(device: device, showReason: false)
                                .contentShape(Rectangle())
                                .onTapGesture { selectedDeviceID = device.id }
                        }
                    }
                }

                Section(header: Text("Nearby devices")) {
                    if deviceService.nearbyOthers.isEmpty {
                        Text(deviceService.isScanning ? "No other devices in range" : "Start scanning to see nearby devices")
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(deviceService.nearbyOthers) { device in
                            LiveDeviceRow(device: device, showReason: false)
                                .contentShape(Rectangle())
                                .onTapGesture { selectedDeviceID = device.id }
                        }
                    }
                }
            }
            .navigationTitle("BlueClues")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showingSettings = true } label: { Image(systemName: "gear") }
                }
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView()
            }
            .sheet(item: Binding(get: { selectedDeviceID.map(IdentifiedString.init) },
                                 set: { selectedDeviceID = $0?.id })) { selection in
                if let device = deviceService.getDevice(byUUID: selection.id) {
                    DeviceDetailView(device: device, deviceService: deviceService)
                } else {
                    Text("This device hasn't been saved yet. Try again in a few seconds.")
                        .padding()
                }
            }
        }
    }

    private var setupWarning: String? {
        switch deviceService.bluetoothState {
        case .poweredOff: return "Bluetooth is off. Turn it on to scan."
        case .unauthorized: return "BlueClues doesn't have Bluetooth permission."
        case .unsupported: return "This device doesn't support Bluetooth LE."
        default: break
        }
        switch deviceService.locationAuthorization {
        case .denied, .restricted:
            return "Location is off for BlueClues, so in-motion mode can't tell where devices were seen."
        case .authorizedWhenInUse where deviceService.mode == .inMotion:
            return "Set Location to \"Always\" so in-motion mode keeps working with the screen off."
        default:
            return nil
        }
    }
}

private struct IdentifiedString: Identifiable {
    let id: String
}

// MARK: - Status Card
struct StatusCard: View {
    let suspiciousCount: Int
    let isScanning: Bool
    let mode: ScanMode

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 40))
                .foregroundColor(color)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 8)
    }

    private var icon: String {
        if !isScanning { return "pause.circle" }
        return suspiciousCount > 0 ? "exclamationmark.shield.fill" : "checkmark.shield.fill"
    }

    private var color: Color {
        if !isScanning { return .gray }
        return suspiciousCount > 0 ? .red : .green
    }

    private var title: String {
        if !isScanning { return "Not scanning" }
        if suspiciousCount == 0 { return "Nothing suspicious" }
        return "\(suspiciousCount) device\(suspiciousCount == 1 ? "" : "s") to check"
    }

    private var subtitle: String {
        if !isScanning { return "Tap Start Scanning to begin." }
        switch mode {
        case .inMotion: return "Watching for devices that move with you."
        case .stationary: return "Watching for unfamiliar devices that stay nearby."
        }
    }
}

// MARK: - Live Device Row
struct LiveDeviceRow: View {
    let device: LiveDevice
    let showReason: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(device.displayName)
                        .font(.headline)
                    if device.tracker?.separatedFromOwner == true {
                        Text("Away from owner")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.2))
                            .cornerRadius(4)
                    }
                }
                Text(showReason ? device.assessment.reason : (device.tracker?.kind.rawValue ?? "Bluetooth device"))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Text("\(device.rssi) dBm")
                .font(.caption)
                .monospacedDigit()
                .foregroundColor(.secondary)
        }
    }
}
