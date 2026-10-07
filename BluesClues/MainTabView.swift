//
//  MainTabView.swift
//  BluesClues
//
//  Created by Jared Maxwell on 8/31/25.
//

import SwiftUI
import CoreData
import Combine

struct MainTabView: View {
    var body: some View {
        TabView {
            StatusView()
                .tabItem {
                    Label("Status", systemImage: "shield.lefthalf.filled")
                }

            DevicesView()
                .tabItem {
                    Label("Devices", systemImage: "antenna.radiowaves.left.and.right")
                }

            DeviceTrackerView()
                .tabItem {
                    Label("Locate", systemImage: "location.viewfinder")
                }

            CalendarView()
                .tabItem {
                    Label("Calendar", systemImage: "calendar")
                }

            LogsView()
                .tabItem {
                    Label("Logs", systemImage: "doc.text")
                }
        }
    }
}

// MARK: - Devices View
struct DevicesView: View {
    @EnvironmentObject var deviceService: DeviceService
    @FetchRequest(sortDescriptors: [NSSortDescriptor(key: "lastSeen", ascending: false)])
    private var devices: FetchedResults<BluetoothDevice>
    @State private var selectedDevice: BluetoothDevice?
    @State private var showTrackersOnly = true

    var body: some View {
        NavigationStack {
            Group {
                if filteredDevices.isEmpty {
                    VStack(spacing: 20) {
                        Image(systemName: "antenna.radiowaves.left.and.right.slash")
                            .font(.system(size: 60))
                            .foregroundColor(.secondary)
                        Text(showTrackersOnly ? "No trackers found yet" : "No devices found yet")
                            .font(.title2)
                            .foregroundColor(.secondary)
                        Text("Devices appear here as BlueClues hears them.")
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        let favorites = filteredDevices.filter(\.isFavorite)
                        if !favorites.isEmpty {
                            Section(header: Text("Favorites")) {
                                ForEach(favorites, id: \.objectID) { device in
                                    deviceRow(device)
                                }
                            }
                        }
                        Section(header: Text(showTrackersOnly ? "Trackers" : "All Devices")) {
                            ForEach(filteredDevices, id: \.objectID) { device in
                                deviceRow(device)
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Devices")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Picker("Show", selection: $showTrackersOnly) {
                        Text("Trackers").tag(true)
                        Text("All").tag(false)
                    }
                    .pickerStyle(.segmented)
                }
            }
            .sheet(item: $selectedDevice) { device in
                DeviceDetailView(device: device, deviceService: deviceService)
            }
        }
    }

    private var filteredDevices: [BluetoothDevice] {
        showTrackersOnly ? devices.filter { $0.trackerKind != nil } : Array(devices)
    }

    private func deviceRow(_ device: BluetoothDevice) -> some View {
        DeviceRow(device: device, live: device.uuid.flatMap { deviceService.liveDevice(id: $0) })
            .contentShape(Rectangle())
            .onTapGesture { selectedDevice = device }
    }
}

// MARK: - Device Row
struct DeviceRow: View {
    @ObservedObject var device: BluetoothDevice
    let live: LiveDevice?

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(device.name ?? device.trackerKind ?? "Unknown Device")
                        .font(.headline)
                    if device.isFavorite {
                        Image(systemName: "star.fill")
                            .foregroundColor(.yellow)
                            .font(.caption)
                    }
                    if device.isIgnored {
                        Image(systemName: "person.crop.circle.badge.checkmark")
                            .foregroundColor(.secondary)
                            .font(.caption)
                    }
                }
                HStack(spacing: 12) {
                    Text(device.deviceType ?? "Unknown")
                    if let lastSeen = device.lastSeen {
                        Text("Last seen \(lastSeen, style: .relative) ago")
                    }
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }

            Spacer()

            if let live, live.isSuspicious {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.red)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Device Detail View
struct DeviceDetailView: View {
    @ObservedObject var device: BluetoothDevice
    @ObservedObject var deviceService: DeviceService
    @Environment(\.presentationMode) var presentationMode
    @State private var showingEditNotes = false
    @State private var notes = ""

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Device header
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(device.name ?? "Unknown Device")
                                .font(.title)
                                .fontWeight(.bold)

                            Spacer()

                            Button(action: {
                                deviceService.updateDeviceFavoriteStatus(uuid: device.uuid ?? "", isFavorite: !device.isFavorite)
                            }) {
                                Image(systemName: device.isFavorite ? "star.fill" : "star")
                                    .foregroundColor(device.isFavorite ? .yellow : .gray)
                                    .font(.title2)
                            }
                        }

                        Text(device.uuid ?? "")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .padding()
                    .background(Color.gray.opacity(0.1))
                    .cornerRadius(12)

                    // Known / ignore
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("This is mine (never alert)", isOn: Binding(
                            get: { device.isIgnored },
                            set: { deviceService.setIgnored(uuid: device.uuid ?? "", ignored: $0) }
                        ))
                        Text("Use this for your own and your household's devices.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding()
                    .background(Color.gray.opacity(0.1))
                    .cornerRadius(12)

                    // Statistics
                    let stats = deviceService.getDeviceStatistics(forDevice: device)
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Statistics")
                            .font(.headline)

                        InfoRow(label: "Type", value: device.deviceType ?? "Unknown")
                        if let live = deviceService.liveDevice(id: device.uuid ?? "") {
                            InfoRow(label: "Assessment", value: live.assessment.reason)
                        }
                        InfoRow(label: "Total Detections", value: "\(stats.totalDetections)")
                        InfoRow(label: "Average RSSI", value: "\(stats.averageRSSI) dBm")
                        InfoRow(label: "Days Active", value: "\(stats.daysActive)")
                    }
                    .padding()
                    .background(Color.gray.opacity(0.1))
                    .cornerRadius(12)

                    // Notes
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Text("Notes")
                                .font(.headline)
                            Spacer()
                            Button("Edit") {
                                notes = device.customNotes ?? ""
                                showingEditNotes = true
                            }
                        }

                        if let notes = device.customNotes, !notes.isEmpty {
                            Text(notes)
                                .font(.body)
                        } else {
                            Text("No notes")
                                .foregroundColor(.secondary)
                                .italic()
                        }
                    }
                    .padding()
                    .background(Color.gray.opacity(0.1))
                    .cornerRadius(12)
                }
                .padding()
            }
            .navigationBarItems(trailing: Button("Done") {
                presentationMode.wrappedValue.dismiss()
            })
            .navigationTitle("Device Details")
            .sheet(isPresented: $showingEditNotes) {
                EditNotesView(device: device, notes: $notes, deviceService: deviceService)
            }
        }
    }
}

// MARK: - Edit Notes View
struct EditNotesView: View {
    let device: BluetoothDevice
    @Binding var notes: String
    let deviceService: DeviceService
    @Environment(\.presentationMode) var presentationMode

    var body: some View {
        NavigationView {
            VStack {
                TextEditor(text: $notes)
                    .padding()
                    .background(Color.gray.opacity(0.1))
                    .cornerRadius(8)
                    .padding()

                Spacer()
            }
            .navigationTitle("Edit Notes")
            .navigationBarItems(
                leading: Button("Cancel") {
                    presentationMode.wrappedValue.dismiss()
                },
                trailing: Button("Save") {
                    deviceService.updateDeviceNotes(uuid: device.uuid ?? "", notes: notes)
                    presentationMode.wrappedValue.dismiss()
                }
            )
        }
    }
}

// MARK: - Settings View
struct SettingsView: View {
    @EnvironmentObject var deviceService: DeviceService
    @Environment(\.dismiss) private var dismiss
    @State private var exportURL: URL?
    @State private var confirmingClear = false

    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("Detection"),
                        footer: Text("Off: only known tracker types (Tile, SmartTag, Find My, Google, Chipolo) raise alerts. On: any Bluetooth device can, which also catches a person carrying a phone but is noisier.")) {
                    Picker("Mode", selection: $deviceService.mode) {
                        ForEach(ScanMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    Toggle("Alert on any device", isOn: $deviceService.alertOnAllDevices)
                }

                Section(header: Text("Status")) {
                    HStack {
                        Text("Bluetooth")
                        Spacer()
                        Text(deviceService.getBluetoothState())
                            .foregroundColor(deviceService.bluetoothState == .poweredOn ? .green : .red)
                    }
                    HStack {
                        Text("Scanning")
                        Spacer()
                        Text(deviceService.isScanning ? "Active" : "Stopped")
                            .foregroundColor(deviceService.isScanning ? .green : .secondary)
                    }
                }

                Section(header: Text("Data")) {
                    if let exportURL {
                        ShareLink(item: exportURL) {
                            Label("Share Detections CSV", systemImage: "square.and.arrow.up")
                        }
                    } else {
                        Button("Export Detections") {
                            exportURL = deviceService.exportCSV()
                        }
                    }
                    Button("Clear All Data", role: .destructive) {
                        confirmingClear = true
                    }
                }

                Section(header: Text("About")) {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                            .foregroundColor(.secondary)
                    }
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog("Delete every saved device, detection and log?",
                                isPresented: $confirmingClear, titleVisibility: .visible) {
                Button("Delete All", role: .destructive) {
                    deviceService.clearAllData()
                    exportURL = nil
                }
            }
        }
    }
}
