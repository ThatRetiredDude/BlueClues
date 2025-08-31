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
    @Environment(\.managedObjectContext) private var viewContext
    @StateObject private var deviceService = DeviceService()

    var body: some View {
        TabView {
            // Devices Tab
            DevicesView()
                .tabItem {
                    Label("Devices", systemImage: "antenna.radiowaves.left.and.right")
                }
                .environmentObject(deviceService)

            // Calendar Tab
            CalendarView()
                .tabItem {
                    Label("Calendar", systemImage: "calendar")
                }
                .environmentObject(deviceService)

            // Logs Tab
            LogsView()
                .tabItem {
                    Label("Logs", systemImage: "doc.text")
                }
                .environmentObject(deviceService)

            // Tracker Tab
            DeviceTrackerView()
                .tabItem {
                    Label("Tracker", systemImage: "location.viewfinder")
                }
                .environmentObject(deviceService)

            // Settings Tab
            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gear")
                }
                .environmentObject(deviceService)
        }
        .accentColor(.blue)
        .onAppear {
            // Auto-start scanning when app launches
            print("App launched - starting device discovery")
            deviceService.startDeviceDiscovery()
        }
    }
}

// MARK: - Devices View
struct DevicesView: View {
    @EnvironmentObject var deviceService: DeviceService
    @State private var selectedDevice: BluetoothDevice?
    @State private var showingDeviceDetail = false

    var body: some View {
        NavigationView {
            VStack {
                // Scanning status and controls
                HStack {
                    Circle()
                        .fill(deviceService.isScanning ? Color.green : Color.gray)
                        .frame(width: 8, height: 8)
                    Text(deviceService.isScanning ? "Scanning for devices..." : "Scanning stopped")
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    Spacer()

                    // Scan Now button
                    Button(action: {
                        deviceService.scanNow()
                    }) {
                        HStack {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                            Text("Scan Now")
                        }
                        .font(.subheadline)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.blue.opacity(0.1))
                        .foregroundColor(.blue)
                        .cornerRadius(8)
                    }
                }
                .padding(.horizontal)

                if deviceService.getAllDevices().isEmpty {
                    // Empty state
                    VStack(spacing: 20) {
                        Image(systemName: "antenna.radiowaves.left.and.right.slash")
                            .font(.system(size: 60))
                            .foregroundColor(.secondary)

                        Text("No devices found yet")
                            .font(.title2)
                            .foregroundColor(.secondary)

                        Text("Devices will appear here as they are discovered")
                            .font(.body)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        Section(header: Text("All Devices")) {
                            ForEach(deviceService.getAllDevices(), id: \.self) { device in
                                DeviceRow(device: device, deviceService: deviceService)
                                    .onTapGesture {
                                        selectedDevice = device
                                        showingDeviceDetail = true
                                    }
                            }
                        }

                        if !deviceService.getFavoriteDevices().isEmpty {
                            Section(header: Text("Favorites")) {
                                ForEach(deviceService.getFavoriteDevices(), id: \.self) { device in
                                    DeviceRow(device: device, deviceService: deviceService)
                                        .onTapGesture {
                                            selectedDevice = device
                                            showingDeviceDetail = true
                                        }
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Devices")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showingDeviceDetail) {
                if let device = selectedDevice {
                    DeviceDetailView(device: device, deviceService: deviceService)
                }
            }
        }
    }
}

// MARK: - Device Row
struct DeviceRow: View {
    let device: BluetoothDevice
    let deviceService: DeviceService

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(device.name ?? "Unknown Device")
                        .font(.headline)
                    if device.isFavorite {
                        Image(systemName: "star.fill")
                            .foregroundColor(.yellow)
                            .font(.caption)
                    }
                }

                Text(device.uuid ?? "")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)

                HStack(spacing: 12) {
                    Text(device.deviceType ?? "Unknown")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    if let lastSeen = device.lastSeen {
                        Text("Last seen: \(formatRelativeDate(lastSeen))")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        Text("Last seen: Never")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                let stats = deviceService.getDeviceStatistics(forDevice: device)
                Text("\(stats.totalDetections)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("detections")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func formatRelativeDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Device Detail View
struct DeviceDetailView: View {
    let device: BluetoothDevice
    let deviceService: DeviceService
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
                                deviceService.updateDeviceFavoriteStatus(uuid: device.uuid!, isFavorite: !device.isFavorite)
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

                    // Statistics
                    let stats = deviceService.getDeviceStatistics(forDevice: device)
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Statistics")
                            .font(.headline)

                        InfoRow(label: "Total Detections", value: "\(stats.totalDetections)")
                        InfoRow(label: "Average RSSI", value: "\(stats.averageRSSI)dB")
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
                    deviceService.updateDeviceNotes(uuid: device.uuid!, notes: notes)
                    presentationMode.wrappedValue.dismiss()
                }
            )
        }
    }
}

// MARK: - Settings View
struct SettingsView: View {
    @EnvironmentObject var deviceService: DeviceService
    @State private var isScanning = true
    @State private var scanIntervalValue: Double = 30
    @State private var selectedUnit: ScanIntervalUnit = .seconds
    @State private var bluetoothState: String = "Checking..."

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Scanning")) {
                    Toggle("Enable Device Scanning", isOn: $isScanning)
                        .onChange(of: isScanning) { newValue in
                            if newValue {
                                deviceService.startDeviceDiscovery()
                            } else {
                                deviceService.stopDeviceDiscovery()
                            }
                        }

                    // Scan Interval Settings
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Scan Interval")
                            .font(.headline)

                        HStack {
                            Text("Every")
                                .foregroundColor(.secondary)

                            TextField("Interval", value: $scanIntervalValue, format: .number)
                                .keyboardType(.decimalPad)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 80)

                            Picker("Unit", selection: $selectedUnit) {
                                ForEach(ScanIntervalUnit.allCases) { unit in
                                    Text(unit.rawValue).tag(unit)
                                }
                            }
                            .pickerStyle(.menu)
                            .frame(width: 100)
                        }

                        Text("Current: \(Int(scanIntervalValue)) \(selectedUnit.shortName)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .onChange(of: scanIntervalValue) { _ in
                        updateScanInterval()
                    }
                    .onChange(of: selectedUnit) { _ in
                        updateScanInterval()
                    }
                    .onAppear {
                        // Load current settings
                        scanIntervalValue = deviceService.scanInterval
                        selectedUnit = deviceService.scanIntervalUnit
                        isScanning = deviceService.isScanning
                        bluetoothState = deviceService.getBluetoothState()
                    }
                }

                Section(header: Text("Bluetooth Status")) {
                    HStack {
                        Text("Bluetooth State")
                        Spacer()
                        Text(bluetoothState)
                            .foregroundColor(bluetoothState == "Powered On" ? .green : .red)
                    }

                    HStack {
                        Text("Scanning Status")
                        Spacer()
                        Text(deviceService.isScanning ? "Active" : "Inactive")
                            .foregroundColor(deviceService.isScanning ? .green : .secondary)
                    }

                    if bluetoothState != "Powered On" {
                        Text("⚠️ Enable Bluetooth in Settings to scan for devices")
                            .font(.caption)
                            .foregroundColor(.orange)
                    }

                    if bluetoothState == "Unauthorized" {
                        Text("⚠️ Grant Bluetooth permission in Settings > Privacy & Security > Bluetooth")
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                }

                Section(header: Text("Data")) {
                    Button("Clear All Data") {
                        // Implement data clearing
                        print("Clear all data functionality would be implemented here")
                    }
                    .foregroundColor(.red)
                }

                Section(header: Text("Debug")) {
                    Button("Test Bluetooth Scan") {
                        print("🔍 Testing Bluetooth scan...")
                        deviceService.scanNow()
                    }

                    Button("Refresh Bluetooth Status") {
                        bluetoothState = deviceService.getBluetoothState()
                        print("🔄 Bluetooth state: \(bluetoothState)")
                    }
                }

                Section(header: Text("About")) {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text("1.0.0")
                            .foregroundColor(.secondary)
                    }

                    HStack {
                        Text("Devices Found")
                        Spacer()
                        Text("\(deviceService.getAllDevices().count)")
                            .foregroundColor(.secondary)
                    }
                }
            }
            .navigationTitle("Settings")
        }
    }

    private func updateScanInterval() {
        deviceService.updateScanInterval(scanIntervalValue, unit: selectedUnit)
    }
}


