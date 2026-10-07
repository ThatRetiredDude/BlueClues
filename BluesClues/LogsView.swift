//
//  LogsView.swift
//  BluesClues
//
//  Created by Jared Maxwell on 8/31/25.
//

import SwiftUI
import CoreData

struct LogsView: View {
    @Environment(\.managedObjectContext) private var viewContext
    @EnvironmentObject private var deviceService: DeviceService
    @State private var selectedDevice: BluetoothDevice?
    @State private var selectedEventType: String?
    @State private var searchText = ""
    @State private var startDate = Calendar.current.date(byAdding: .day, value: -7, to: Date())!
    @State private var endDate = Date()
    @State private var showingFilters = false
    @State private var logs: [DeviceLog] = []

    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .medium
        return formatter
    }()

    private let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .medium
        return formatter
    }()

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Search and filter bar
                HStack {
                    HStack {
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(.secondary)
                        TextField("Search logs...", text: $searchText)
                            .textFieldStyle(.plain)
                    }
                    .padding(8)
                    .background(Color.gray.opacity(0.1))
                    .cornerRadius(8)

                    Button(action: {
                        showingFilters.toggle()
                    }) {
                        Image(systemName: "line.horizontal.3.decrease.circle")
                            .foregroundColor(showingFilters ? .blue : .secondary)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)

                // Filters
                if showingFilters {
                    FiltersView(
                        selectedDevice: $selectedDevice,
                        selectedEventType: $selectedEventType,
                        startDate: $startDate,
                        endDate: $endDate,
                        deviceService: deviceService
                    )
                    .transition(.slide)
                }

                // Logs list
                if logs.isEmpty {
                    VStack {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.largeTitle)
                            .foregroundColor(.secondary)
                        Text("No logs found")
                            .font(.headline)
                            .foregroundColor(.secondary)
                        Text("Try adjusting your filters or search terms")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(groupedLogs(), id: \.key) { date, dateLogs in
                            Section(header: Text(formatDate(date))) {
                                ForEach(dateLogs) { log in
                                    LogRowView(log: log, deviceService: deviceService)
                                        .swipeActions {
                                            Button(role: .destructive) {
                                                deleteLog(log)
                                            } label: {
                                                Label("Delete", systemImage: "trash")
                                            }
                                        }
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Device Logs")
            .navigationBarTitleDisplayMode(.inline)
        }
        .onAppear {
            loadLogs()
        }
        .onChange(of: selectedDevice) { _ in
            loadLogs()
        }
        .onChange(of: selectedEventType) { _ in
            loadLogs()
        }
        .onChange(of: searchText) { _ in
            loadLogs()
        }
        .onChange(of: startDate) { _ in
            loadLogs()
        }
        .onChange(of: endDate) { _ in
            loadLogs()
        }
    }

    private func loadLogs() {
        let context = viewContext
        let fetchRequest: NSFetchRequest<DeviceLog> = DeviceLog.fetchRequest()

        // Build predicates
        var predicates: [NSPredicate] = []

        // Date range
        predicates.append(NSPredicate(format: "timestamp >= %@ AND timestamp <= %@", startDate as NSDate, endDate as NSDate))

        // Device filter
        if let device = selectedDevice {
            predicates.append(NSPredicate(format: "device == %@", device))
        }

        // Event type filter
        if let eventType = selectedEventType {
            predicates.append(NSPredicate(format: "eventType == %@", eventType))
        }

        // Search text
        if !searchText.isEmpty {
            let searchPredicates = [
                NSPredicate(format: "eventType CONTAINS[cd] %@", searchText),
                NSPredicate(format: "metadata CONTAINS[cd] %@", searchText),
                NSPredicate(format: "device.name CONTAINS[cd] %@", searchText)
            ]
            predicates.append(NSCompoundPredicate(orPredicateWithSubpredicates: searchPredicates))
        }

        fetchRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
        fetchRequest.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: false)]
        fetchRequest.fetchLimit = 1000 // Limit for performance

        do {
            logs = try context.fetch(fetchRequest)
        } catch {
            print("Error fetching logs: \(error.localizedDescription)")
            logs = []
        }
    }

    private func groupedLogs() -> [(key: Date, value: [DeviceLog])] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: logs) { log in
            if let timestamp = log.timestamp {
                return calendar.startOfDay(for: timestamp)
            } else {
                return Date.distantPast
            }
        }

        return grouped.sorted { $0.key > $1.key }
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none

        if calendar.isDateInToday(date) {
            return "Today"
        } else if calendar.isDateInYesterday(date) {
            return "Yesterday"
        } else {
            return formatter.string(from: date)
        }
    }

    private func deleteLog(_ log: DeviceLog) {
        viewContext.delete(log)
        do {
            try viewContext.save()
            loadLogs() // Refresh the list
        } catch {
            print("Error deleting log: \(error.localizedDescription)")
        }
    }

    private var calendar: Calendar {
        Calendar.current
    }
}

// MARK: - Filters View
struct FiltersView: View {
    @Binding var selectedDevice: BluetoothDevice?
    @Binding var selectedEventType: String?
    @Binding var startDate: Date
    @Binding var endDate: Date
    @ObservedObject var deviceService: DeviceService

    private let eventTypes = ["discovered", "arrived", "departed", "suspicious"]

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text("Filters")
                    .font(.headline)
                Spacer()
                Button("Clear All") {
                    selectedDevice = nil
                    selectedEventType = nil
                    startDate = Calendar.current.date(byAdding: .day, value: -7, to: Date())!
                    endDate = Date()
                }
                .foregroundColor(.blue)
            }

            // Device picker
            VStack(alignment: .leading) {
                Text("Device")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Menu {
                    Button("All Devices") {
                        selectedDevice = nil
                    }
                    ForEach(deviceService.getAllDevices(), id: \.self) { device in
                        Button(device.name ?? "Unknown Device") {
                            selectedDevice = device
                        }
                    }
                } label: {
                    HStack {
                        Text(selectedDevice?.name ?? "All Devices")
                        Spacer()
                        Image(systemName: "chevron.down")
                    }
                    .padding()
                    .background(Color.gray.opacity(0.1))
                    .cornerRadius(8)
                }
            }

            // Event type picker
            VStack(alignment: .leading) {
                Text("Event Type")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Menu {
                    Button("All Events") {
                        selectedEventType = nil
                    }
                    ForEach(eventTypes, id: \.self) { eventType in
                        Button(eventType.capitalized) {
                            selectedEventType = eventType
                        }
                    }
                } label: {
                    HStack {
                        Text(selectedEventType?.capitalized ?? "All Events")
                        Spacer()
                        Image(systemName: "chevron.down")
                    }
                    .padding()
                    .background(Color.gray.opacity(0.1))
                    .cornerRadius(8)
                }
            }

            // Date range
            VStack(alignment: .leading) {
                Text("Date Range")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                HStack {
                    DatePicker("From", selection: $startDate, displayedComponents: .date)
                        .labelsHidden()
                    DatePicker("To", selection: $endDate, displayedComponents: .date)
                        .labelsHidden()
                }
            }
        }
        .padding()
        .background(Color.gray.opacity(0.05))
    }
}

// MARK: - Log Row View
struct LogRowView: View {
    let log: DeviceLog
    let deviceService: DeviceService
    @State private var showingDetails = false

    private let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .medium
        return formatter
    }()

    var body: some View {
        Button(action: {
            showingDetails.toggle()
        }) {
            HStack {
                // Event indicator
                Circle()
                    .fill(eventColor(for: log.eventType))
                    .frame(width: 12, height: 12)

                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(log.eventType?.capitalized ?? "Unknown")
                            .font(.headline)
                        Spacer()
                        if let timestamp = log.timestamp {
                            Text(timeFormatter.string(from: timestamp))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        } else {
                            Text("--:--")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    if let deviceName = log.device?.name {
                        Text(deviceName)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }

                    HStack {
                        if log.rssi != 0 {
                            Text("RSSI: \(log.rssi)dB")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .sheet(isPresented: $showingDetails) {
            LogDetailView(log: log)
        }
    }

    private func eventColor(for eventType: String?) -> Color {
        switch eventType {
        case "discovered":
            return .blue
        case "arrived":
            return .green
        case "departed":
            return .red
        case "suspicious":
            return .orange
        default:
            return .gray
        }
    }
}

// MARK: - Log Detail View
struct LogDetailView: View {
    let log: DeviceLog
    @Environment(\.presentationMode) var presentationMode

    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .medium
        return formatter
    }()

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Header
                    VStack(alignment: .leading, spacing: 8) {
                        Text(log.eventType?.capitalized ?? "Unknown Event")
                            .font(.title)
                            .fontWeight(.bold)

                        if let timestamp = log.timestamp {
                            Text(dateFormatter.string(from: timestamp))
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        } else {
                            Text("Unknown time")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                    }

                    // Device info
                    if let device = log.device {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Device Information")
                                .font(.headline)

                            InfoRow(label: "Name", value: device.name ?? "Unknown")
                            InfoRow(label: "UUID", value: device.uuid ?? "Unknown")
                            InfoRow(label: "Type", value: device.deviceType ?? "Unknown")
                            InfoRow(label: "First Seen", value: device.firstSeen.map { formatDate($0) } ?? "Never")
                            InfoRow(label: "Last Seen", value: device.lastSeen.map { formatDate($0) } ?? "Never")
                        }
                        .padding()
                        .background(Color.gray.opacity(0.1))
                        .cornerRadius(8)
                    }

                    // Log details
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Event Details")
                            .font(.headline)

                        if log.rssi != 0 {
                            InfoRow(label: "Signal Strength", value: "\(log.rssi)dB")
                        }

                        if let metadata = log.metadata, !metadata.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Additional Data")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                                Text(metadata)
                                    .font(.body)
                                    .padding()
                                    .background(Color.gray.opacity(0.1))
                                    .cornerRadius(8)
                            }
                        }
                    }
                    .padding()
                    .background(Color.gray.opacity(0.1))
                    .cornerRadius(8)
                }
                .padding()
            }
            .navigationBarItems(trailing: Button("Done") {
                presentationMode.wrappedValue.dismiss()
            })
            .navigationTitle("Log Details")
        }
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

// MARK: - Info Row
struct InfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .frame(width: 100, alignment: .leading)
            Text(value)
                .font(.body)
        }
    }
}

struct LogsView_Previews: PreviewProvider {
    static var previews: some View {
        LogsView()
            .environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
            .environmentObject(DeviceService(persistenceController: .preview, autoStart: false))
    }
}
