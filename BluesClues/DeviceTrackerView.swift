//
//  DeviceTrackerView.swift
//  BluesClues
//
//  Created by Jared Maxwell on 8/31/25.
//

import SwiftUI
import CoreData
import Combine

struct DeviceTrackerView: View {
    @EnvironmentObject private var deviceService: DeviceService
    @State private var selectedDevice: BluetoothDevice?
    @State private var isTracking = false
    @State private var currentRSSI: Int = 0
    @State private var signalHistory: [SignalPoint] = []
    @State private var directionHint: DirectionHint = .none
    @State private var showingDevicePicker = false
    @State private var trackingTimer: Timer?
    @State private var lastSampleTime: Date?

    private let maxHistoryPoints = 50

    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                // Device selector
                HStack {
                    Text("Tracking:")
                        .font(.headline)
                    Button(action: {
                        showingDevicePicker = true
                    }) {
                        HStack {
                            Text(selectedDevice?.name ?? "Select Device")
                                .foregroundColor(selectedDevice == nil ? .secondary : .primary)
                            Image(systemName: "chevron.down")
                        }
                    }
                    Spacer()
                }
                .padding(.horizontal)

                if selectedDevice != nil {
                    // Tracking interface
                    VStack(spacing: 30) {
                        // Signal strength meter
                        SignalStrengthMeter(rssi: currentRSSI, isActive: isTracking)

                        // Direction indicator
                        DirectionIndicator(hint: directionHint)

                        // Signal history chart
                        SignalHistoryChart(signalHistory: signalHistory)

                        // Control buttons
                        HStack(spacing: 20) {
                            Button(action: {
                                if isTracking {
                                    stopTracking()
                                } else {
                                    startTracking()
                                }
                            }) {
                                HStack {
                                    Image(systemName: isTracking ? "stop.circle.fill" : "play.circle.fill")
                                    Text(isTracking ? "Stop Tracking" : "Start Tracking")
                                }
                                .font(.headline)
                                .padding()
                                .background(isTracking ? Color.red : Color.green)
                                .foregroundColor(.white)
                                .cornerRadius(12)
                            }

                            Button(action: {
                                signalHistory.removeAll()
                                directionHint = .none
                            }) {
                                HStack {
                                    Image(systemName: "arrow.clockwise")
                                    Text("Reset")
                                }
                                .font(.headline)
                                .padding()
                                .background(Color.blue)
                                .foregroundColor(.white)
                                .cornerRadius(12)
                            }
                        }

                        // Tips
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Tracking Tips")
                                .font(.headline)
                            Text("• Move around to see signal strength changes")
                            Text("• Closer devices show stronger signals (-30dB to -50dB)")
                            Text("• Distant devices show weaker signals (-70dB to -90dB)")
                            Text("• Use the arrows to guide you toward the device")
                            Text("• Trackers that change address may drop out for a moment; keep walking")
                        }
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .padding()
                        .background(Color.gray.opacity(0.1))
                        .cornerRadius(8)
                    }
                    .padding(.horizontal)
                } else {
                    // No device selected
                    VStack(spacing: 20) {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .font(.system(size: 80))
                            .foregroundColor(.secondary)

                        Text("Select a device to start tracking")
                            .font(.title2)
                            .foregroundColor(.secondary)

                        Button("Choose Device") {
                            showingDevicePicker = true
                        }
                        .font(.headline)
                        .padding()
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(12)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                Spacer()
            }
            .navigationTitle("Locate Device")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showingDevicePicker) {
                DevicePickerView(selectedDevice: $selectedDevice, deviceService: deviceService)
            }
            .onDisappear {
                stopTracking()
            }
        }
    }

    private func startTracking() {
        guard !isTracking, let device = selectedDevice else { return }

        isTracking = true
        deviceService.startDeviceDiscovery()
        lastSampleTime = nil

        // Set up timer to update signal strength
        trackingTimer?.invalidate() // Cancel any existing timer
        trackingTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            updateSignalStrength(for: device)
        }
    }

    private func stopTracking() {
        isTracking = false
        trackingTimer?.invalidate()
        trackingTimer = nil
    }

    private func updateSignalStrength(for device: BluetoothDevice) {
        // Live signal straight from the scanner; skip if nothing new was heard.
        guard let uuid = device.uuid,
              let live = deviceService.liveDevice(id: uuid),
              live.lastSeen != lastSampleTime else { return }
        lastSampleTime = live.lastSeen

        currentRSSI = live.rssi
        signalHistory.append(SignalPoint(timestamp: live.lastSeen, rssi: live.rssi))
        if signalHistory.count > maxHistoryPoints {
            signalHistory.removeFirst()
        }
        updateDirectionHint()
    }

    private func updateDirectionHint() {
        guard signalHistory.count >= 3 else {
            directionHint = .none
            return
        }

        let recentPoints = signalHistory.suffix(3)
        let rssiValues = recentPoints.map { $0.rssi }

        // Calculate trend
        let trend = calculateTrend(from: rssiValues)

        // RSSI increases as you get closer (less negative)
        if trend > 2 { // Signal getting stronger
            directionHint = .gettingCloser
        } else if trend < -2 { // Signal getting weaker
            directionHint = .gettingFurther
        } else {
            directionHint = .stable
        }
    }

    private func calculateTrend(from values: [Int]) -> Int {
        guard values.count >= 2 else { return 0 }

        // Simple linear trend calculation
        let n = values.count
        var sumX = 0.0
        var sumY = 0.0
        var sumXY = 0.0
        var sumXX = 0.0

        for i in 0..<n {
            let x = Double(i)
            let y = Double(values[i])
            sumX += x
            sumY += y
            sumXY += x * y
            sumXX += x * x
        }

        let slope = (Double(n) * sumXY - sumX * sumY) / (Double(n) * sumXX - sumX * sumX)
        return Int(slope)
    }
}

// MARK: - Signal Strength Meter
struct SignalStrengthMeter: View {
    let rssi: Int
    let isActive: Bool

    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                // Background circles
                ForEach(0..<5) { level in
                    Circle()
                        .stroke(getSignalColor(for: level), lineWidth: 4)
                        .opacity(getOpacity(for: level))
                        .frame(width: CGFloat(60 + level * 20), height: CGFloat(60 + level * 20))
                }

                // Center signal strength
                VStack {
                    Image(systemName: getSignalIcon())
                        .font(.system(size: 40))
                        .foregroundColor(getSignalColor())
                    Text("\(rssi) dBm")
                        .font(.title)
                        .fontWeight(.bold)
                        .foregroundColor(getSignalColor())
                }
            }
            .frame(height: 180)

            // Signal quality text
            Text(getSignalQuality())
                .font(.headline)
                .foregroundColor(getSignalColor())
        }
    }

    private func getSignalLevel() -> Int {
        // Convert RSSI to signal level (0-4)
        // RSSI range: -30 (very close) to -90 (far away)
        let normalizedRSSI = max(-90, min(-30, rssi))
        let level = 4 - Int((abs(normalizedRSSI) - 30) / 15)
        return max(0, min(4, level))
    }

    private func getSignalColor(for level: Int? = nil) -> Color {
        let signalLevel = level ?? getSignalLevel()

        switch signalLevel {
        case 4: return .green
        case 3: return .yellow
        case 2: return .orange
        case 1: return .red
        default: return .gray
        }
    }

    private func getOpacity(for level: Int) -> Double {
        let signalLevel = getSignalLevel()
        return level <= signalLevel ? 1.0 : 0.3
    }

    private func getSignalIcon() -> String {
        let signalLevel = getSignalLevel()

        switch signalLevel {
        case 4: return "wifi"
        case 3: return "wifi"
        case 2: return "wifi"
        case 1: return "wifi.slash"
        default: return "wifi.slash"
        }
    }

    private func getSignalQuality() -> String {
        let signalLevel = getSignalLevel()

        switch signalLevel {
        case 4: return "Excellent Signal"
        case 3: return "Good Signal"
        case 2: return "Fair Signal"
        case 1: return "Poor Signal"
        default: return "No Signal"
        }
    }
}

// MARK: - Direction Indicator
struct DirectionIndicator: View {
    let hint: DirectionHint

    var body: some View {
        VStack(spacing: 16) {
            Text("Direction Guide")
                .font(.headline)

            ZStack {
                // Background circle
                Circle()
                    .stroke(Color.gray.opacity(0.3), lineWidth: 2)
                    .frame(width: 120, height: 120)

                // Direction arrows
                switch hint {
                case .gettingCloser:
                    VStack {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 30))
                            .foregroundColor(.green)
                        Text("Getting Closer!")
                            .font(.caption)
                            .foregroundColor(.green)
                    }
                case .gettingFurther:
                    VStack {
                        Image(systemName: "arrow.down")
                            .font(.system(size: 30))
                            .foregroundColor(.red)
                        Text("Moving Away")
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                case .stable:
                    VStack {
                        Image(systemName: "arrow.left.and.right")
                            .font(.system(size: 30))
                            .foregroundColor(.blue)
                        Text("Signal Stable")
                            .font(.caption)
                            .foregroundColor(.blue)
                    }
                case .none:
                    VStack {
                        Image(systemName: "questionmark")
                            .font(.system(size: 30))
                            .foregroundColor(.gray)
                        Text("No Direction")
                            .font(.caption)
                            .foregroundColor(.gray)
                    }
                }
            }
        }
    }
}

// MARK: - Signal History Chart
struct SignalHistoryChart: View {
    let signalHistory: [SignalPoint]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Signal History")
                .font(.headline)

            if signalHistory.isEmpty {
                Text("No signal data yet")
                    .foregroundColor(.secondary)
                    .frame(height: 100)
                    .frame(maxWidth: .infinity)
                    .background(Color.gray.opacity(0.1))
                    .cornerRadius(8)
            } else {
                GeometryReader { geometry in
                    ZStack {
                        // Grid lines
                        Path { path in
                            let stepY = geometry.size.height / 5
                            for i in 0...5 {
                                let y = stepY * CGFloat(i)
                                path.move(to: CGPoint(x: 0, y: y))
                                path.addLine(to: CGPoint(x: geometry.size.width, y: y))
                            }
                        }
                        .stroke(Color.gray.opacity(0.2), lineWidth: 1)

                        // Signal line
                        Path { path in
                            guard !signalHistory.isEmpty else { return }

                            let points = signalHistory.enumerated().map { index, point in
                                let x = geometry.size.width * CGFloat(index) / CGFloat(max(1, signalHistory.count - 1))
                                let y = geometry.size.height * (1 - CGFloat(point.normalizedRSSI))
                                return CGPoint(x: x, y: y)
                            }

                            if let firstPoint = points.first {
                                path.move(to: firstPoint)
                                points.dropFirst().forEach { point in
                                    path.addLine(to: point)
                                }
                            }
                        }
                        .stroke(Color.blue, lineWidth: 2)

                        // Current value indicator
                        if let lastPoint = signalHistory.last {
                            let x = geometry.size.width * CGFloat(signalHistory.count - 1) / CGFloat(max(1, signalHistory.count - 1))
                            let y = geometry.size.height * (1 - CGFloat(lastPoint.normalizedRSSI))
                            Circle()
                                .fill(Color.blue)
                                .frame(width: 8, height: 8)
                                .position(x: x, y: y)
                        }
                    }
                }
                .frame(height: 100)
                .background(Color.gray.opacity(0.1))
                .cornerRadius(8)

                // RSSI range labels
                HStack {
                    Text("-90dB")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("-30dB")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
    }
}

// MARK: - Supporting Types
struct SignalPoint {
    let timestamp: Date
    let rssi: Int

    var normalizedRSSI: Double {
        // Normalize RSSI from -90 to -30 range to 0-1
        let clamped = max(-90, min(-30, Double(rssi)))
        return (clamped + 90) / 60 // 0 = weak, 1 = strong
    }
}

enum DirectionHint {
    case gettingCloser, gettingFurther, stable, none
}



struct DeviceTrackerView_Previews: PreviewProvider {
    static var previews: some View {
        DeviceTrackerView()
            .environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
            .environmentObject(DeviceService(persistenceController: .preview, autoStart: false))
    }
}
