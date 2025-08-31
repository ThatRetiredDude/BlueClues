//
//  CalendarView.swift
//  BluesClues
//
//  Created by Jared Maxwell on 8/31/25.
//

import SwiftUI
import CoreData

struct CalendarView: View {
    @Environment(\.managedObjectContext) private var viewContext
    @StateObject private var deviceService = DeviceService()
    @State private var selectedDate = Date()
    @State private var selectedDevice: BluetoothDevice?
    @State private var showingDevicePicker = false
    @State private var calendarViewMode: CalendarViewMode = .month
    @State private var presenceData: [Date: Bool] = [:]

    enum CalendarViewMode {
        case month, week, day
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Header with device selector and view mode
                HStack {
                    Button(action: {
                        showingDevicePicker = true
                    }) {
                        HStack {
                            Text(selectedDevice?.name ?? "All Devices")
                                .font(.headline)
                            Image(systemName: "chevron.down")
                                .font(.caption)
                        }
                        .foregroundColor(.primary)
                    }

                    Spacer()

                    Picker("View", selection: $calendarViewMode) {
                        Text("Month").tag(CalendarViewMode.month)
                        Text("Week").tag(CalendarViewMode.week)
                        Text("Day").tag(CalendarViewMode.day)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 200)
                }
                .padding()

                // Calendar content
                switch calendarViewMode {
                case .month:
                    MonthCalendarView(selectedDate: $selectedDate, presenceData: presenceData)
                case .week:
                    WeekCalendarView(selectedDate: $selectedDate, presenceData: presenceData)
                case .day:
                    DayCalendarView(selectedDate: selectedDate, deviceService: deviceService, selectedDevice: selectedDevice)
                }

                Spacer()
            }
            .navigationTitle("Device Calendar")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showingDevicePicker) {
                DevicePickerView(selectedDevice: $selectedDevice, deviceService: deviceService)
            }
        }
        .onAppear {
            loadPresenceData()
        }
        .onChange(of: selectedDevice) { _ in
            loadPresenceData()
        }
    }

    private func loadPresenceData() {
        if let device = selectedDevice {
            presenceData = deviceService.getDevicePresencePattern(forDevice: device, days: 30)
        } else {
            // For all devices, show days when any device was present
            let devices = deviceService.getAllDevices()
            var combinedPresence: [Date: Bool] = [:]

            for device in devices {
                let devicePresence = deviceService.getDevicePresencePattern(forDevice: device, days: 30)
                for (date, present) in devicePresence {
                    if present {
                        combinedPresence[date] = true
                    }
                }
            }

            presenceData = combinedPresence
        }
    }
}

// MARK: - Month Calendar View
struct MonthCalendarView: View {
    @Binding var selectedDate: Date
    let presenceData: [Date: Bool]

    private let calendar = Calendar.current
    private let monthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM yyyy"
        return formatter
    }()

    private let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "d"
        return formatter
    }()

    var body: some View {
        VStack {
            // Month navigation
            HStack {
                Button(action: previousMonth) {
                    Image(systemName: "chevron.left")
                }

                Text(monthFormatter.string(from: selectedDate))
                    .font(.title2)
                    .fontWeight(.semibold)

                Button(action: nextMonth) {
                    Image(systemName: "chevron.right")
                }
            }
            .padding(.vertical)

            // Day headers
            HStack {
                ForEach(["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"], id: \.self) { day in
                    Text(day)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal)

            // Calendar grid
            let days = generateMonthDays()
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 7), spacing: 8) {
                ForEach(days, id: \.self) { date in
                    if let date = date {
                        DayCell(date: date, isSelected: calendar.isDate(date, inSameDayAs: selectedDate), isPresent: presenceData[calendar.startOfDay(for: date)] ?? false)
                            .onTapGesture {
                                selectedDate = date
                            }
                    } else {
                        Color.clear
                            .frame(height: 40)
                    }
                }
            }
            .padding(.horizontal)
        }
    }

    private func generateMonthDays() -> [Date?] {
        let startOfMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: selectedDate))!
        let startOfCalendar = calendar.date(byAdding: .day, value: -(calendar.component(.weekday, from: startOfMonth) - 1), to: startOfMonth)!

        var days: [Date?] = []
        var currentDate = startOfCalendar

        for _ in 0..<42 { // 6 weeks * 7 days
            days.append(currentDate)
            currentDate = calendar.date(byAdding: .day, value: 1, to: currentDate)!
        }

        return days
    }

    private func previousMonth() {
        selectedDate = calendar.date(byAdding: .month, value: -1, to: selectedDate)!
    }

    private func nextMonth() {
        selectedDate = calendar.date(byAdding: .month, value: 1, to: selectedDate)!
    }
}

// MARK: - Week Calendar View
struct WeekCalendarView: View {
    @Binding var selectedDate: Date
    let presenceData: [Date: Bool]

    private let calendar = Calendar.current
    private let weekFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter
    }()

    var body: some View {
        VStack {
            // Week navigation
            HStack {
                Button(action: previousWeek) {
                    Image(systemName: "chevron.left")
                }

                let weekRange = getWeekRange()
                Text("\(weekFormatter.string(from: weekRange.start)) - \(weekFormatter.string(from: weekRange.end))")
                    .font(.title2)
                    .fontWeight(.semibold)

                Button(action: nextWeek) {
                    Image(systemName: "chevron.right")
                }
            }
            .padding(.vertical)

            // Time slots and days
            ScrollView {
                HStack(alignment: .top, spacing: 0) {
                    // Time column
                    VStack(spacing: 0) {
                        ForEach(0..<24) { hour in
                            Text(String(format: "%02d:00", hour))
                                .font(.caption)
                                .frame(height: 60, alignment: .top)
                                .padding(.trailing, 8)
                        }
                    }
                    .frame(width: 60)

                    // Day columns
                    let weekDays = getWeekDays()
                    ForEach(weekDays, id: \.self) { date in
                        VStack(spacing: 0) {
                            // Day header
                            Text(getDayHeader(for: date))
                                .font(.caption)
                                .fontWeight(.semibold)
                                .frame(height: 40)
                                .padding(.bottom, 8)

                            // Time slots
                            ForEach(0..<24) { hour in
                                let isPresent = presenceData[calendar.startOfDay(for: date)] ?? false
                                Rectangle()
                                    .fill(isPresent ? Color.blue.opacity(0.3) : Color.gray.opacity(0.1))
                                    .frame(height: 60)
                                    .border(Color.gray.opacity(0.2), width: 0.5)
                            }
                        }
                        .frame(width: 60)
                    }
                }
            }
        }
    }

    private func getWeekRange() -> (start: Date, end: Date) {
        let startOfWeek = calendar.date(from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: selectedDate))!
        let endOfWeek = calendar.date(byAdding: .day, value: 6, to: startOfWeek)!
        return (startOfWeek, endOfWeek)
    }

    private func getWeekDays() -> [Date] {
        let startOfWeek = calendar.date(from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: selectedDate))!
        return (0..<7).map { calendar.date(byAdding: .day, value: $0, to: startOfWeek)! }
    }

    private func getDayHeader(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE\nd"
        return formatter.string(from: date)
    }

    private func previousWeek() {
        selectedDate = calendar.date(byAdding: .weekOfYear, value: -1, to: selectedDate)!
    }

    private func nextWeek() {
        selectedDate = calendar.date(byAdding: .weekOfYear, value: 1, to: selectedDate)!
    }
}

// MARK: - Day Calendar View
struct DayCalendarView: View {
    let selectedDate: Date
    let deviceService: DeviceService
    let selectedDevice: BluetoothDevice?

    private let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(getDateString())
                    .font(.title)
                    .fontWeight(.bold)
                    .padding(.horizontal)

                if let device = selectedDevice {
                    let events = deviceService.getDeviceArrivalDepartureTimes(forDevice: device, date: selectedDate)

                    if events.isEmpty {
                        Text("No device activity recorded for this day")
                            .foregroundColor(.secondary)
                            .padding()
                    } else {
                        ForEach(events, id: \.time) { event in
                            HStack {
                                Circle()
                                    .fill(event.type == "arrived" ? Color.green : Color.red)
                                    .frame(width: 12, height: 12)

                                VStack(alignment: .leading) {
                                    Text(event.type.capitalized)
                                        .font(.headline)
                                    Text(timeFormatter.string(from: event.time))
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)
                                }

                                Spacer()
                            }
                            .padding()
                            .background(Color.gray.opacity(0.1))
                            .cornerRadius(8)
                            .padding(.horizontal)
                        }
                    }
                } else {
                    Text("Select a device to view daily activity")
                        .foregroundColor(.secondary)
                        .padding()
                }
            }
        }
    }

    private func getDateString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, MMMM d, yyyy"
        return formatter.string(from: selectedDate)
    }
}

// MARK: - Day Cell
struct DayCell: View {
    let date: Date
    let isSelected: Bool
    let isPresent: Bool

    private let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "d"
        return formatter
    }()

    var body: some View {
        ZStack {
            Circle()
                .fill(isPresent ? Color.blue : Color.clear)
                .opacity(isPresent ? 0.3 : 0)

            if isSelected {
                Circle()
                    .stroke(Color.blue, lineWidth: 2)
            }

            Text(dayFormatter.string(from: date))
                .font(.system(size: 16))
                .foregroundColor(isPresent ? .white : .primary)
                .fontWeight(isSelected ? .bold : .regular)
        }
        .frame(width: 40, height: 40)
    }
}

// MARK: - Device Picker View
struct DevicePickerView: View {
    @Binding var selectedDevice: BluetoothDevice?
    @ObservedObject var deviceService: DeviceService
    @Environment(\.presentationMode) var presentationMode

    var body: some View {
        NavigationView {
            List {
                Button(action: {
                    selectedDevice = nil
                    presentationMode.wrappedValue.dismiss()
                }) {
                    HStack {
                        Text("All Devices")
                        Spacer()
                        if selectedDevice == nil {
                            Image(systemName: "checkmark")
                        }
                    }
                }

                ForEach(deviceService.getAllDevices(), id: \.self) { device in
                    Button(action: {
                        selectedDevice = device
                        presentationMode.wrappedValue.dismiss()
                    }) {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(device.name ?? "Unknown Device")
                                    .font(.headline)
                                Text(device.uuid ?? "")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            if selectedDevice == device {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }
            .navigationTitle("Select Device")
            .navigationBarItems(trailing: Button("Cancel") {
                presentationMode.wrappedValue.dismiss()
            })
        }
    }
}

struct CalendarView_Previews: PreviewProvider {
    static var previews: some View {
        CalendarView()
            .environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
    }
}
