//
//  DeviceService.swift
//  BluesClues
//
//  Created by Jared Maxwell on 8/31/25.
//

import Foundation
import CoreData
import CoreLocation
import Combine
import CoreBluetooth

// MARK: - Scan Interval Unit
enum ScanIntervalUnit: String, CaseIterable, Identifiable {
    case seconds = "Seconds"
    case minutes = "Minutes"
    case hours = "Hours"

    var id: String { self.rawValue }

    var multiplier: TimeInterval {
        switch self {
        case .seconds: return 1
        case .minutes: return 60
        case .hours: return 3600
        }
    }

    var shortName: String {
        switch self {
        case .seconds: return "sec"
        case .minutes: return "min"
        case .hours: return "hrs"
        }
    }
}

// MARK: - Device Service
class DeviceService: BluetoothManagerDelegate, ObservableObject {
    // MARK: - Properties
    private let persistenceController: PersistenceController
    private let bluetoothManager: BluetoothManager
    private var cancellables = Set<AnyCancellable>()

    // Scan interval settings
    @Published var scanInterval: TimeInterval = 30 // Default 30 seconds
    @Published var scanIntervalUnit: ScanIntervalUnit = .seconds
    @Published var isScanning = false
    private var scanTimer: Timer?

    // UserDefaults keys for persistence
    private let scanIntervalKey = "scanInterval"
    private let scanIntervalUnitKey = "scanIntervalUnit"

    // Publishers for UI updates
    let devicesUpdated = PassthroughSubject<Void, Never>()
    let detectionsUpdated = PassthroughSubject<Void, Never>()

    // In-memory cache for quick access
    private var deviceCache: [String: BluetoothDevice] = [:]
    private var lastDetectionTimes: [String: Date] = [:]

    // Pattern of life tracking
    private let presenceThreshold: TimeInterval = 300 // 5 minutes
    private let departureThreshold: TimeInterval = 600 // 10 minutes

    // MARK: - Initialization
    init(persistenceController: PersistenceController = .shared) {
        self.persistenceController = persistenceController
        self.bluetoothManager = BluetoothManager()
        self.bluetoothManager.delegate = self

        loadDeviceCache()
        loadScanSettings()
    }

    private func loadScanSettings() {
        let defaults = UserDefaults.standard
        scanInterval = defaults.double(forKey: scanIntervalKey)
        if scanInterval <= 0 {
            scanInterval = 30 // Default to 30 seconds
        }

        if let unitString = defaults.string(forKey: scanIntervalUnitKey),
           let unit = ScanIntervalUnit(rawValue: unitString) {
            scanIntervalUnit = unit
        }
    }

    private func saveScanSettings() {
        let defaults = UserDefaults.standard
        defaults.set(scanInterval, forKey: scanIntervalKey)
        defaults.set(scanIntervalUnit.rawValue, forKey: scanIntervalUnitKey)
        defaults.synchronize()
    }

    // MARK: - Public Methods

    // MARK: - Device Management
    func startDeviceDiscovery() {
        guard !isScanning else {
            print("DeviceService: Already scanning")
            return
        }

        print("DeviceService: Starting device discovery")
        isScanning = true
        bluetoothManager.startScanning()
        startScanTimer()
    }

    func stopDeviceDiscovery() {
        guard isScanning else {
            print("DeviceService: Not scanning")
            return
        }

        print("DeviceService: Stopping device discovery")
        isScanning = false
        bluetoothManager.stopScanning()
        stopScanTimer()
    }

    func scanNow() {
        print("DeviceService: Performing immediate scan")

        // Perform an immediate scan
        bluetoothManager.startScanning()

        // Stop scanning after a brief period (e.g., 10 seconds) if not in continuous mode
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
            if !self.isScanning { // Only stop if not in continuous scanning mode
                print("DeviceService: Stopping manual scan after 10 seconds")
                self.bluetoothManager.stopScanning()
            }
        }
    }

    func getBluetoothState() -> String {
        let state = bluetoothManager.bluetoothState
        switch state {
        case .poweredOn: return "Powered On"
        case .poweredOff: return "Powered Off"
        case .unauthorized: return "Unauthorized"
        case .unsupported: return "Unsupported"
        case .resetting: return "Resetting"
        case .unknown: return "Unknown"
        @unknown default: return "Unknown (\(state.rawValue))"
        }
    }

    func updateScanInterval(_ interval: TimeInterval, unit: ScanIntervalUnit) {
        scanInterval = interval
        scanIntervalUnit = unit
        saveScanSettings()

        // Restart scanning with new interval if currently scanning
        if isScanning {
            stopScanTimer()
            startScanTimer()
        }
    }

    private func startScanTimer() {
        stopScanTimer() // Ensure no existing timer

        let interval = scanInterval * scanIntervalUnit.multiplier
        scanTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.performPeriodicScan()
        }
    }

    private func stopScanTimer() {
        scanTimer?.invalidate()
        scanTimer = nil
    }

    private func performPeriodicScan() {
        bluetoothManager.startScanning()
    }

    func getAllDevices() -> [BluetoothDevice] {
        let context = persistenceController.container.viewContext
        let fetchRequest: NSFetchRequest<BluetoothDevice> = BluetoothDevice.fetchRequest()
        fetchRequest.sortDescriptors = [NSSortDescriptor(key: "lastSeen", ascending: false)]

        do {
            return try context.fetch(fetchRequest)
        } catch {
            print("Error fetching devices: \(error.localizedDescription)")
            return []
        }
    }

    func getFavoriteDevices() -> [BluetoothDevice] {
        let context = persistenceController.container.viewContext
        let fetchRequest: NSFetchRequest<BluetoothDevice> = BluetoothDevice.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "isFavorite == YES")
        fetchRequest.sortDescriptors = [NSSortDescriptor(key: "lastSeen", ascending: false)]

        do {
            return try context.fetch(fetchRequest)
        } catch {
            print("Error fetching favorite devices: \(error.localizedDescription)")
            return []
        }
    }

    func getDevice(byUUID uuid: String) -> BluetoothDevice? {
        // Check cache first
        if let cachedDevice = deviceCache[uuid] {
            return cachedDevice
        }

        let context = persistenceController.container.viewContext
        let fetchRequest: NSFetchRequest<BluetoothDevice> = BluetoothDevice.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "uuid == %@", uuid)
        fetchRequest.fetchLimit = 1

        do {
            let devices = try context.fetch(fetchRequest)
            if let device = devices.first {
                deviceCache[uuid] = device
                return device
            }
        } catch {
            print("Error fetching device by UUID: \(error.localizedDescription)")
        }

        return nil
    }

    func updateDeviceFavoriteStatus(uuid: String, isFavorite: Bool) {
        let context = persistenceController.container.viewContext

        context.perform {
            if let device = self.getDevice(byUUID: uuid) {
                device.isFavorite = isFavorite
                do {
                    try context.save()
                    self.devicesUpdated.send()
                } catch {
                    print("Error updating device favorite status: \(error.localizedDescription)")
                }
            }
        }
    }

    func updateDeviceNotes(uuid: String, notes: String) {
        let context = persistenceController.container.viewContext

        context.perform {
            if let device = self.getDevice(byUUID: uuid) {
                device.customNotes = notes
                do {
                    try context.save()
                    self.devicesUpdated.send()
                } catch {
                    print("Error updating device notes: \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - Detection History
    func getDetectionHistory(forDevice device: BluetoothDevice, limit: Int = 100) -> [DeviceDetection] {
        let context = persistenceController.container.viewContext
        let fetchRequest: NSFetchRequest<DeviceDetection> = DeviceDetection.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "device == %@", device)
        fetchRequest.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: false)]
        fetchRequest.fetchLimit = limit

        do {
            return try context.fetch(fetchRequest)
        } catch {
            print("Error fetching detection history: \(error.localizedDescription)")
            return []
        }
    }

    func getDeviceLogs(forDevice device: BluetoothDevice, limit: Int = 50) -> [DeviceLog] {
        let context = persistenceController.container.viewContext
        let fetchRequest: NSFetchRequest<DeviceLog> = DeviceLog.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "device == %@", device)
        fetchRequest.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: false)]
        fetchRequest.fetchLimit = limit

        do {
            return try context.fetch(fetchRequest)
        } catch {
            print("Error fetching device logs: \(error.localizedDescription)")
            return []
        }
    }

    // MARK: - Pattern of Life Analysis
    func getDevicePresencePattern(forDevice device: BluetoothDevice, days: Int = 7) -> [Date: Bool] {
        let context = persistenceController.container.viewContext
        let endDate = Date()
        let startDate = Calendar.current.date(byAdding: .day, value: -days, to: endDate)!

        let fetchRequest: NSFetchRequest<DeviceDetection> = DeviceDetection.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "device == %@ AND timestamp >= %@ AND timestamp <= %@", device, startDate as NSDate, endDate as NSDate)
        fetchRequest.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: true)]

        do {
            let detections = try context.fetch(fetchRequest)
            return analyzePresencePattern(from: detections, startDate: startDate, endDate: endDate)
        } catch {
            print("Error fetching presence pattern: \(error.localizedDescription)")
            return [:]
        }
    }

    func getDeviceArrivalDepartureTimes(forDevice device: BluetoothDevice, date: Date) -> [(type: String, time: Date)] {
        let context = persistenceController.container.viewContext
        let startOfDay = Calendar.current.startOfDay(for: date)
        let endOfDay = Calendar.current.date(byAdding: .day, value: 1, to: startOfDay)!

        let fetchRequest: NSFetchRequest<DeviceDetection> = DeviceDetection.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "device == %@ AND timestamp >= %@ AND timestamp <= %@", device, startOfDay as NSDate, endOfDay as NSDate)
        fetchRequest.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: true)]

        do {
            let detections = try context.fetch(fetchRequest)
            return analyzeArrivalDepartureTimes(from: detections)
        } catch {
            print("Error fetching arrival/departure times: \(error.localizedDescription)")
            return []
        }
    }

    // MARK: - Statistics
    func getDeviceStatistics(forDevice device: BluetoothDevice) -> DeviceStatistics {
        let context = persistenceController.container.viewContext

        // Total detections
        let detectionCount = getDetectionHistory(forDevice: device, limit: 1000).count

        // Average RSSI
        let detections = getDetectionHistory(forDevice: device, limit: 100)
        let averageRSSI = detections.isEmpty ? 0 : detections.reduce(0) { $0 + Int($1.rssi) } / detections.count

        // Last seen
        let lastSeen = device.lastSeen

        // Days since first seen
        let daysActive = device.firstSeen.map { Calendar.current.dateComponents([.day], from: $0, to: Date()).day ?? 0 } ?? 0

        return DeviceStatistics(
            totalDetections: detectionCount,
            averageRSSI: averageRSSI,
            lastSeen: lastSeen ?? Date.distantPast,
            daysActive: daysActive
        )
    }

    // MARK: - Private Methods
    private func loadDeviceCache() {
        let devices = getAllDevices()
        for device in devices {
            deviceCache[device.uuid!] = device
            lastDetectionTimes[device.uuid!] = device.lastSeen
        }
    }

    private func processDeviceDiscovery(_ deviceInfo: BluetoothDeviceInfo) {
        let context = persistenceController.container.newBackgroundContext()

        context.perform {
            // Check if device already exists
            let existingDevice = self.getDevice(byUUID: deviceInfo.uuid)

            if let device = existingDevice {
                // Update existing device
                self.updateExistingDevice(device, with: deviceInfo, in: context)
            } else {
                // Create new device
                self.createNewDevice(from: deviceInfo, in: context)
            }

            // Create detection record
            self.createDetectionRecord(for: deviceInfo, in: context)

            // Check for pattern of life events
            self.checkForPresenceEvents(deviceInfo)

            do {
                try context.save()
                DispatchQueue.main.async {
                    self.devicesUpdated.send()
                    self.detectionsUpdated.send()
                }
            } catch {
                print("Error saving device data: \(error.localizedDescription)")
            }
        }
    }

    private func createNewDevice(from deviceInfo: BluetoothDeviceInfo, in context: NSManagedObjectContext) {
        let device = BluetoothDevice(context: context)
        device.uuid = deviceInfo.uuid
        device.name = deviceInfo.name
        device.deviceType = self.inferDeviceType(from: deviceInfo)
        device.firstSeen = deviceInfo.timestamp
        device.lastSeen = deviceInfo.timestamp
        device.isFavorite = false

        // Add to cache
        deviceCache[deviceInfo.uuid] = device
        lastDetectionTimes[deviceInfo.uuid] = deviceInfo.timestamp

        // Log device discovery
        createLogEntry(for: device, eventType: "discovered", rssi: deviceInfo.rssi, metadata: deviceInfo.advertisementData.description, in: context)
    }

    private func updateExistingDevice(_ device: BluetoothDevice, with deviceInfo: BluetoothDeviceInfo, in context: NSManagedObjectContext) {
        device.lastSeen = deviceInfo.timestamp

        // Update name if it changed and wasn't manually set
        if device.name == nil || device.name!.isEmpty {
            device.name = deviceInfo.name
        }

        // Update cache
        lastDetectionTimes[deviceInfo.uuid] = deviceInfo.timestamp
    }

    private func createDetectionRecord(for deviceInfo: BluetoothDeviceInfo, in context: NSManagedObjectContext) {
        guard let device = getDevice(byUUID: deviceInfo.uuid) else { return }

        let detection = DeviceDetection(context: context)
        detection.timestamp = deviceInfo.timestamp
        detection.rssi = Int16(deviceInfo.rssi)
        detection.isConnected = false // We don't track connections in this simple version
        detection.device = device

        // Add location if available
        // Note: In a real app, you'd get location from CLLocationManager
        // detection.latitude = location.latitude
        // detection.longitude = location.longitude
    }

    private func createLogEntry(for device: BluetoothDevice, eventType: String, rssi: Int, metadata: String? = nil, in context: NSManagedObjectContext) {
        let log = DeviceLog(context: context)
        log.timestamp = Date()
        log.eventType = eventType
        log.rssi = Int16(rssi)
        log.metadata = metadata
        log.device = device
    }

    private func checkForPresenceEvents(_ deviceInfo: BluetoothDeviceInfo) {
        let uuid = deviceInfo.uuid

        if let lastDetectionTime = lastDetectionTimes[uuid] {
            let timeSinceLastDetection = deviceInfo.timestamp.timeIntervalSince(lastDetectionTime)

            // Check for arrival (device was gone for more than departure threshold)
            if timeSinceLastDetection > departureThreshold {
                print("Device \(deviceInfo.name ?? "Unknown") arrived")
                if let device = getDevice(byUUID: uuid) {
                    let context = persistenceController.container.newBackgroundContext()
                    context.perform {
                        self.createLogEntry(for: device, eventType: "arrived", rssi: deviceInfo.rssi, metadata: "Time since last detection: \(timeSinceLastDetection)s", in: context)
                        try? context.save()
                    }
                }
            }
        }
    }

    private func inferDeviceType(from deviceInfo: BluetoothDeviceInfo) -> String {
        let name = deviceInfo.name?.lowercased() ?? ""
        let advertisementData = deviceInfo.advertisementData

        // Check for common device types based on name and advertisement data
        if name.contains("airpods") || name.contains("earbuds") {
            return "Headphones"
        } else if name.contains("watch") || name.contains("iwatch") {
            return "Smart Watch"
        } else if name.contains("phone") || name.contains("iphone") || name.contains("android") {
            return "Phone"
        } else if name.contains("mac") || name.contains("laptop") || name.contains("computer") {
            return "Computer"
        } else if name.contains("speaker") || name.contains("sound") {
            return "Speaker"
        } else if name.contains("keyboard") {
            return "Keyboard"
        } else if name.contains("mouse") {
            return "Mouse"
        } else if name.contains("trackpad") {
            return "Trackpad"
        } else if let serviceUUIDs = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] {
            // Check service UUIDs for device type hints
            for uuid in serviceUUIDs {
                if uuid.uuidString.contains("180F") { return "Battery Device" }
                if uuid.uuidString.contains("1805") { return "Time Device" }
                if uuid.uuidString.contains("180A") { return "Device Information" }
            }
        }

        return "Unknown"
    }

    private func analyzePresencePattern(from detections: [DeviceDetection], startDate: Date, endDate: Date) -> [Date: Bool] {
        var pattern: [Date: Bool] = [:]
        let calendar = Calendar.current

        // Group detections by day
        var detectionsByDay: [Date: [DeviceDetection]] = [:]
        for detection in detections {
            if let timestamp = detection.timestamp {
                let day = calendar.startOfDay(for: timestamp)
                detectionsByDay[day, default: []].append(detection)
            }
        }

        // Fill in the pattern for each day
        var currentDate = startDate
        while currentDate <= endDate {
            let day = calendar.startOfDay(for: currentDate)
            let dayDetections = detectionsByDay[day] ?? []
            pattern[day] = !dayDetections.isEmpty
            currentDate = calendar.date(byAdding: .day, value: 1, to: currentDate)!
        }

        return pattern
    }

    private func analyzeArrivalDepartureTimes(from detections: [DeviceDetection]) -> [(type: String, time: Date)] {
        guard !detections.isEmpty else { return [] }

        var events: [(type: String, time: Date)] = []
        var lastDetectionTime: Date?

        for detection in detections {
            if let timestamp = detection.timestamp {
                if let lastTime = lastDetectionTime {
                    let timeGap = timestamp.timeIntervalSince(lastTime)

                    // If gap is greater than departure threshold, record departure and arrival
                    if timeGap > departureThreshold {
                        events.append(("departed", lastTime))
                        events.append(("arrived", timestamp))
                    }
                } else {
                    // First detection of the day
                    events.append(("arrived", timestamp))
                }

                lastDetectionTime = timestamp
            }
        }

        return events.sorted { $0.time < $1.time }
    }

    // MARK: - BluetoothManagerDelegate
    func bluetoothManager(_ manager: BluetoothManager, didDiscover device: BluetoothDeviceInfo) {
        processDeviceDiscovery(device)
    }

    func bluetoothManager(_ manager: BluetoothManager, didUpdateState state: CBManagerState) {
        print("DeviceService: Bluetooth state changed to \(state.rawValue)")

        switch state {
        case .poweredOn:
            print("✅ Bluetooth is ready - can start scanning")
            // Auto-start scanning if we were waiting for Bluetooth to be ready
            if isScanning && !bluetoothManager.isScanning {
                print("DeviceService: Auto-restarting scan after Bluetooth became ready")
                bluetoothManager.startScanning()
            }
        case .poweredOff:
            print("❌ Bluetooth is powered off")
            if isScanning {
                print("DeviceService: Stopping scan due to Bluetooth being powered off")
                stopDeviceDiscovery()
            }
        case .unauthorized:
            print("❌ Bluetooth access denied - user needs to grant permissions in Settings")
        case .unsupported:
            print("❌ Bluetooth not supported on this device")
        default:
            print("⚠️ Bluetooth state: \(state.rawValue)")
        }
    }

    func bluetoothManager(_ manager: BluetoothManager, didFailWithError error: Error) {
        print("DeviceService: Bluetooth error: \(error.localizedDescription)")
    }
}

// MARK: - Supporting Types
struct DeviceStatistics {
    let totalDetections: Int
    let averageRSSI: Int
    let lastSeen: Date
    let daysActive: Int
}
