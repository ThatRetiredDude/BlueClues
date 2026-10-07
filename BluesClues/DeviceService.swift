//
//  DeviceService.swift
//  BluesClues
//
//  Created by Jared Maxwell on 8/31/25.
//
//  The single app-wide service: turns advertisements from ScanEngine into
//  entities, keeps live state for the UI, scores each entity for following or
//  lingering, raises alerts, and records throttled history in Core Data.
//  Everything here runs on the main queue.
//

import Foundation
import CoreData
import CoreLocation
import CoreBluetooth
import Combine
import UserNotifications

// MARK: - Live Device
struct LiveDevice: Identifiable, Equatable {
    let id: String
    var name: String?
    var tracker: TrackerMatch?
    var rssi: Int
    var firstSeen: Date
    var lastSeen: Date
    var assessment: FollowAssessment
    var trust: TrustLevel
    var identity: DeviceIdentity = .unknown

    var displayName: String {
        if let name, !name.isEmpty { return name }
        if let tracker { return tracker.kind.rawValue }
        return identity.label
    }

    var isSuspicious: Bool { assessment.isSuspicious && trust.canAlert }
}

// MARK: - Possible Follower
/// A signature (not a single address) that keeps showing up where you go.
struct PossibleFollower: Identifiable, Equatable {
    let id: String
    let displayName: String
    var rssi: Int
    var lastSeen: Date
    var assessment: FollowAssessment
}

// MARK: - Device Service
final class DeviceService: ScanEngineDelegate, ObservableObject {
    // MARK: Published state
    @Published private(set) var isScanning = false
    /// Snapshot of `liveStore`, published at most twice a second so busy
    /// places don't redraw the UI on every advertisement.
    @Published private(set) var liveDevices: [String: LiveDevice] = [:]
    /// Address-rotating devices whose signature looks like it is following you.
    @Published private(set) var possibleFollowers: [PossibleFollower] = []
    @Published private(set) var bluetoothState: CBManagerState = .unknown
    @Published private(set) var locationAuthorization: CLAuthorizationStatus = .notDetermined
    @Published var mode: ScanMode {
        didSet {
            UserDefaults.standard.set(mode.rawValue, forKey: Keys.mode)
            engine.setMode(mode)
            reassessAll()
        }
    }
    @Published var alertScope: AlertScope {
        didSet { UserDefaults.standard.set(alertScope.rawValue, forKey: Keys.alertScope) }
    }

    let devicesUpdated = PassthroughSubject<Void, Never>()
    let detectionsUpdated = PassthroughSubject<Void, Never>()

    // MARK: Private state
    private enum Keys {
        static let mode = "scanMode"
        static let scanningEnabled = "scanningEnabled"
        static let alertScope = "alertScope"
    }

    private let persistenceController: PersistenceController
    private let engine: ScanEngine
    private var linker = EntityLinker()
    private var liveStore: [String: LiveDevice] = [:] {
        didSet { scheduleLiveFlush() }
    }
    private var liveFlushScheduled = false
    private var sightings: [String: [Sighting]] = [:]
    /// Advertisement contents per entity, merged across packets.
    private var adFields: [String: AdvertisementFields] = [:]
    private var lastPersisted: [String: Date] = [:]
    private var lastAlerted: [String: Date] = [:]
    private var departed: Set<String> = []
    private var housekeepingTimer: Timer?
    private var config = DetectorConfig()
    private var lookalikes = LookalikeTracker()
    private var lookalikeStore: [String: PossibleFollower] = [:] {
        didSet { scheduleLiveFlush() }
    }

    /// One stored detection per entity per this interval.
    private let persistInterval: TimeInterval = 15
    /// Gap after which a device counts as having left.
    private let departureThreshold: TimeInterval = 10 * 60
    /// Don't re-alert on the same device within this window.
    private let realertInterval: TimeInterval = 30 * 60
    /// Drop live entries not seen for this long. Matches the stationary
    /// lookback so repeat visits across a day are still counted.
    private let liveRetention: TimeInterval = 24 * 60 * 60
    /// Stored detections older than this are deleted.
    private let historyRetentionDays = 60

    private var viewContext: NSManagedObjectContext { persistenceController.container.viewContext }

    // MARK: Init
    init(persistenceController: PersistenceController = .shared, autoStart: Bool = true) {
        self.persistenceController = persistenceController
        self.engine = ScanEngine()
        let defaults = UserDefaults.standard
        self.mode = ScanMode(rawValue: defaults.string(forKey: Keys.mode) ?? "") ?? .inMotion
        self.alertScope = AlertScope(rawValue: defaults.string(forKey: Keys.alertScope) ?? "") ?? .allUnknown
        self.engine.delegate = self
        self.locationAuthorization = engine.locationAuthorization

        let enabled = defaults.object(forKey: Keys.scanningEnabled) as? Bool ?? true
        if autoStart && enabled {
            startDeviceDiscovery()
        }
        pruneHistory()
    }

    // MARK: Scanning control
    func startDeviceDiscovery() {
        guard !isScanning else { return }
        isScanning = true
        UserDefaults.standard.set(true, forKey: Keys.scanningEnabled)
        requestNotificationPermission()
        engine.start(mode: mode)
        housekeepingTimer?.invalidate()
        housekeepingTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.housekeeping()
        }
    }

    func stopDeviceDiscovery() {
        guard isScanning else { return }
        isScanning = false
        UserDefaults.standard.set(false, forKey: Keys.scanningEnabled)
        engine.stop()
        housekeepingTimer?.invalidate()
        housekeepingTimer = nil
    }

    func scanNow() {
        startDeviceDiscovery()
    }

    func getBluetoothState() -> String {
        switch bluetoothState {
        case .poweredOn: return "Powered On"
        case .poweredOff: return "Powered Off"
        case .unauthorized: return "Unauthorized"
        case .unsupported: return "Unsupported"
        case .resetting: return "Resetting"
        case .unknown: return "Unknown"
        @unknown default: return "Unknown"
        }
    }

    // MARK: Live views
    /// Devices that pass the detector rules, plus questionable devices that are
    /// nearby right now.
    var suspiciousDevices: [LiveDevice] {
        liveDevices.values
            .filter { device in
                isAlertEligible(device) && (device.isSuspicious
                    || (device.trust == .questionable && Date().timeIntervalSince(device.lastSeen) < 120))
            }
            .sorted { $0.assessment.score > $1.assessment.score }
    }

    func isAlertEligible(_ device: LiveDevice) -> Bool {
        AlertPolicy.isEligible(trust: device.trust, isTracker: device.tracker != nil, scope: alertScope)
    }

    var nearbyTrackers: [LiveDevice] {
        liveDevices.values
            .filter { $0.tracker != nil && Date().timeIntervalSince($0.lastSeen) < 120 }
            .sorted { $0.rssi > $1.rssi }
    }

    var nearbyOthers: [LiveDevice] {
        liveDevices.values
            .filter { $0.tracker == nil && Date().timeIntervalSince($0.lastSeen) < 120 }
            .sorted { $0.rssi > $1.rssi }
    }

    func liveDevice(id: String) -> LiveDevice? { liveStore[id] }

    // MARK: ScanEngineDelegate
    func scanEngine(_ engine: ScanEngine, didReceive advertisement: Advertisement) {
        let id = linker.entityID(forPeripheral: advertisement.peripheralID,
                                 kind: advertisement.tracker?.kind,
                                 rssi: advertisement.rssi,
                                 at: advertisement.time)
        let previousSeen = liveStore[id]?.lastSeen
        let stored = previousSeen == nil ? getDevice(byUUID: id) : nil

        var entry = liveStore[id] ?? LiveDevice(
            id: id,
            name: advertisement.name,
            tracker: advertisement.tracker,
            rssi: advertisement.rssi,
            firstSeen: advertisement.time,
            lastSeen: advertisement.time,
            assessment: FollowAssessment(isSuspicious: false, score: 0, reason: "Just seen"),
            trust: stored?.trust ?? .unknown,
            identity: stored?.storedIdentity ?? .unknown
        )
        entry.rssi = advertisement.rssi
        entry.lastSeen = advertisement.time
        if entry.name == nil { entry.name = advertisement.name }
        if let tracker = advertisement.tracker { entry.tracker = tracker }

        // Re-identify only when the advertisement shows something new, and
        // never over an identity the user confirmed.
        let previousFields = adFields[id]
        let fields = previousFields.map { $0.merged(with: advertisement.fields) } ?? advertisement.fields
        if fields != previousFields {
            adFields[id] = fields
            if entry.identity.confidence != .confirmed {
                entry.identity = DeviceIdentifier.identify(fields, tracker: entry.tracker?.kind)
            }
        }

        // Throttle: keep one sighting and one stored detection per interval.
        let lastStored = lastPersisted[id]
        if lastStored == nil || advertisement.time.timeIntervalSince(lastStored!) >= persistInterval {
            lastPersisted[id] = advertisement.time
            sightings[id, default: []].append(Sighting(time: advertisement.time,
                                                       latitude: advertisement.latitude,
                                                       longitude: advertisement.longitude,
                                                       rssi: advertisement.rssi))
            entry.assessment = FollowDetector.assess(sightings[id] ?? [], mode: mode, config: config, now: advertisement.time)
            persist(advertisement, entityID: id, entry: entry, previousSeen: previousSeen)
        }

        liveStore[id] = entry
        trackLookalike(advertisement, entityID: id)
        guard isAlertEligible(entry) else { return }
        if entry.isSuspicious {
            raiseAlertIfNeeded(for: entry)
        } else if entry.trust == .questionable {
            // Questionable devices alert on every new arrival.
            let lastKnown = previousSeen ?? stored?.lastSeen
            if lastKnown == nil || advertisement.time.timeIntervalSince(lastKnown!) > departureThreshold {
                raiseAlertIfNeeded(for: entry, reason: "Questionable device arrived")
            }
        }
    }

    func scanEngine(_ engine: ScanEngine, didUpdateBluetoothState state: CBManagerState) {
        bluetoothState = state
    }

    func scanEngine(_ engine: ScanEngine, didUpdateLocationAuthorization status: CLAuthorizationStatus) {
        locationAuthorization = status
    }

    // MARK: Persistence
    private func persist(_ advertisement: Advertisement, entityID: String, entry: LiveDevice, previousSeen: Date?) {
        let device: BluetoothDevice
        var isNew = false
        if let existing = getDevice(byUUID: entityID) {
            device = existing
        } else {
            device = BluetoothDevice(context: viewContext)
            device.uuid = entityID
            device.firstSeen = advertisement.time
            device.isFavorite = false
            device.trust = entry.trust
            isNew = true
        }

        // An arrival is a sighting after a long silence; check before updating lastSeen.
        let lastKnown = previousSeen ?? device.lastSeen
        if !isNew, let lastKnown, advertisement.time.timeIntervalSince(lastKnown) > departureThreshold {
            createLogEntry(for: device, eventType: "arrived", rssi: advertisement.rssi,
                           metadata: "Away for \(Int(advertisement.time.timeIntervalSince(lastKnown) / 60)) min")
        }
        departed.remove(entityID)

        device.lastSeen = advertisement.time
        if (device.name ?? "").isEmpty, let name = advertisement.name { device.name = name }
        device.deviceType = entry.tracker?.kind.rawValue ?? device.deviceType ?? "Other"
        if let kind = entry.tracker?.kind { device.trackerKind = kind.rawValue }
        if let json = adFields[entityID]?.json, device.advertisementJSON != json { device.advertisementJSON = json }
        if let key = advertisement.signature?.key, device.signatureKey != key { device.signatureKey = key }
        if !device.manufacturerConfirmed { device.store(entry.identity, confirmed: false) }

        if isNew {
            createLogEntry(for: device, eventType: "discovered", rssi: advertisement.rssi, metadata: advertisement.summary)
        }

        let detection = DeviceDetection(context: viewContext)
        detection.timestamp = advertisement.time
        detection.rssi = Int16(clamping: advertisement.rssi)
        detection.isConnected = false
        if let lat = advertisement.latitude, let lon = advertisement.longitude {
            detection.latitude = lat
            detection.longitude = lon
        }
        detection.device = device

        save()
    }

    private func createLogEntry(for device: BluetoothDevice, eventType: String, rssi: Int, metadata: String? = nil) {
        let log = DeviceLog(context: viewContext)
        log.timestamp = Date()
        log.eventType = eventType
        log.rssi = Int16(clamping: rssi)
        log.metadata = metadata
        log.device = device
    }

    private func save() {
        guard viewContext.hasChanges else { return }
        do {
            try viewContext.save()
            devicesUpdated.send()
            detectionsUpdated.send()
        } catch {
            print("DeviceService: save failed: \(error.localizedDescription)")
            viewContext.rollback()
        }
    }

    // MARK: Lookalikes
    private func trackLookalike(_ advertisement: Advertisement, entityID: String) {
        guard advertisement.tracker == nil, let signature = advertisement.signature else { return }
        let key = signature.key
        let stored = lookalikes.record(signature: key, peripheralID: entityID, time: advertisement.time,
                                       latitude: advertisement.latitude, longitude: advertisement.longitude)
        var follower = lookalikeStore[key] ?? PossibleFollower(
            id: key, displayName: signature.displayName, rssi: advertisement.rssi,
            lastSeen: advertisement.time,
            assessment: FollowAssessment(isSuspicious: false, score: 0, reason: "Just seen"))
        follower.rssi = advertisement.rssi
        follower.lastSeen = advertisement.time
        guard stored else {
            lookalikeStore[key] = follower
            return
        }
        follower.assessment = assessLookalike(key, now: advertisement.time)
        lookalikeStore[key] = follower
        if follower.assessment.isSuspicious && lookalikeAlertsEnabled {
            raiseLookalikeAlertIfNeeded(for: follower)
        }
    }

    private func assessLookalike(_ key: String, now: Date) -> FollowAssessment {
        lookalikes.assess(key, now: now) { [weak self] peripheral in
            guard let self else { return false }
            let trust = self.liveStore[peripheral]?.trust ?? .unknown
            return trust == .mine || trust == .friendly
        }
    }

    /// Only in-motion mode, and only when alerting on all unknown devices.
    private var lookalikeAlertsEnabled: Bool {
        mode == .inMotion && alertScope == .allUnknown
    }

    var activePossibleFollowers: [PossibleFollower] {
        guard lookalikeAlertsEnabled else { return [] }
        return possibleFollowers
            .filter { $0.assessment.isSuspicious && Date().timeIntervalSince($0.lastSeen) < departureThreshold }
            .sorted { $0.assessment.score > $1.assessment.score }
    }

    private func raiseLookalikeAlertIfNeeded(for follower: PossibleFollower) {
        let alertKey = "lookalike-\(follower.id)"
        let now = Date()
        if let last = lastAlerted[alertKey], now.timeIntervalSince(last) < realertInterval { return }
        lastAlerted[alertKey] = now

        let content = UNMutableNotificationContent()
        content.title = "Possible follower nearby"
        content.body = "\(follower.displayName): \(follower.assessment.reason). This is weaker evidence than a tracker match."
        content.sound = .default
        let request = UNNotificationRequest(identifier: alertKey, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: Alerts
    private func raiseAlertIfNeeded(for device: LiveDevice, reason: String? = nil) {
        let reason = reason ?? device.assessment.reason
        let now = Date()
        if let last = lastAlerted[device.id], now.timeIntervalSince(last) < realertInterval { return }
        lastAlerted[device.id] = now

        if let stored = getDevice(byUUID: device.id) {
            createLogEntry(for: stored, eventType: "suspicious", rssi: device.rssi, metadata: reason)
            save()
        }

        let content = UNMutableNotificationContent()
        if device.trust == .questionable && !device.isSuspicious {
            content.title = "Questionable device nearby"
        } else {
            content.title = mode == .inMotion ? "Possible tracker following you" : "Unfamiliar device staying nearby"
        }
        content.body = "\(device.displayName): \(reason)."
        content.sound = .default
        let request = UNNotificationRequest(identifier: "suspicious-\(device.id)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    private func scheduleLiveFlush() {
        guard !liveFlushScheduled else { return }
        liveFlushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            self.liveFlushScheduled = false
            self.liveDevices = self.liveStore
            self.possibleFollowers = Array(self.lookalikeStore.values)
        }
    }

    // MARK: Housekeeping
    private func housekeeping() {
        let now = Date()
        for (id, device) in liveStore where !departed.contains(id) && now.timeIntervalSince(device.lastSeen) > departureThreshold {
            departed.insert(id)
            if let stored = getDevice(byUUID: id) {
                createLogEntry(for: stored, eventType: "departed", rssi: device.rssi,
                               metadata: "Last seen \(Int(now.timeIntervalSince(device.lastSeen) / 60)) min ago")
            }
        }
        save()

        linker.prune(olderThan: liveRetention, now: now)
        for (id, device) in liveStore where now.timeIntervalSince(device.lastSeen) > liveRetention {
            liveStore[id] = nil
            adFields[id] = nil
            sightings[id] = nil
            lastPersisted[id] = nil
        }
        for id in sightings.keys {
            sightings[id]?.removeAll { now.timeIntervalSince($0.time) > config.maxLookback }
        }
        lookalikes.prune(now: now)
        for (key, var follower) in lookalikeStore {
            if lookalikes.observations[key] == nil {
                lookalikeStore[key] = nil
            } else {
                follower.assessment = assessLookalike(key, now: now)
                lookalikeStore[key] = follower
            }
        }
        reassessAll(now: now)
    }

    private func reassessAll(now: Date = Date()) {
        for (id, var device) in liveStore {
            device.assessment = FollowDetector.assess(sightings[id] ?? [], mode: mode, config: config, now: now)
            liveStore[id] = device
        }
    }

    private func pruneHistory() {
        guard let cutoff = Calendar.current.date(byAdding: .day, value: -historyRetentionDays, to: Date()) else { return }
        let request: NSFetchRequest<NSFetchRequestResult> = DeviceDetection.fetchRequest()
        request.predicate = NSPredicate(format: "timestamp < %@", cutoff as NSDate)
        let delete = NSBatchDeleteRequest(fetchRequest: request)
        _ = try? viewContext.execute(delete)
        viewContext.reset()
    }

    // MARK: Device management
    func getAllDevices() -> [BluetoothDevice] {
        let request: NSFetchRequest<BluetoothDevice> = BluetoothDevice.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(key: "lastSeen", ascending: false)]
        return (try? viewContext.fetch(request)) ?? []
    }

    func getFavoriteDevices() -> [BluetoothDevice] {
        let request: NSFetchRequest<BluetoothDevice> = BluetoothDevice.fetchRequest()
        request.predicate = NSPredicate(format: "isFavorite == YES")
        request.sortDescriptors = [NSSortDescriptor(key: "lastSeen", ascending: false)]
        return (try? viewContext.fetch(request)) ?? []
    }

    func getDevice(byUUID uuid: String) -> BluetoothDevice? {
        let request: NSFetchRequest<BluetoothDevice> = BluetoothDevice.fetchRequest()
        request.predicate = NSPredicate(format: "uuid == %@", uuid)
        request.fetchLimit = 1
        return (try? viewContext.fetch(request))?.first
    }

    func updateDeviceFavoriteStatus(uuid: String, isFavorite: Bool) {
        guard let device = getDevice(byUUID: uuid) else { return }
        device.isFavorite = isFavorite
        save()
    }

    func updateDeviceNotes(uuid: String, notes: String) {
        guard let device = getDevice(byUUID: uuid) else { return }
        device.customNotes = notes
        save()
    }

    /// Labels a device. Mine and friendly devices never raise alerts;
    /// questionable ones alert every time they arrive.
    func setTrust(uuid: String, level: TrustLevel) {
        if let device = getDevice(byUUID: uuid) {
            device.trust = level
            createLogEntry(for: device, eventType: "labeled", rssi: liveStore[uuid]?.rssi ?? 0, metadata: level.title)
            save()
        }
        liveStore[uuid]?.trust = level
        devicesUpdated.send()
    }

    // MARK: Identification
    /// Ranked guesses for the detail screen, from the stored advertisement.
    func manufacturerCandidates(for device: BluetoothDevice) -> [ManufacturerCandidate] {
        guard let fields = adFields[device.uuid ?? ""] ?? device.advertisementFields else { return [] }
        return DeviceIdentifier.candidates(for: fields, tracker: device.trackerKind.flatMap(TrackerKind.init(rawValue:)))
    }

    /// The user's answer to "who made this?". It overrides automatic guesses.
    func confirmIdentity(uuid: String, manufacturer: String?, category: DeviceCategory, model: String?) {
        let identity = DeviceIdentity(manufacturer: manufacturer, category: category, model: model,
                                      confidence: .confirmed, evidence: ["Confirmed by you"])
        if let device = getDevice(byUUID: uuid) {
            device.store(identity, confirmed: true)
            createLogEntry(for: device, eventType: "identified", rssi: liveStore[uuid]?.rssi ?? 0, metadata: identity.label)
            save()
        }
        liveStore[uuid]?.identity = identity
        devicesUpdated.send()
    }

    /// Drops a confirmation and goes back to the automatic guess.
    func clearConfirmedIdentity(uuid: String) {
        guard let device = getDevice(byUUID: uuid) else { return }
        let fields = adFields[uuid] ?? device.advertisementFields ?? AdvertisementFields()
        let identity = DeviceIdentifier.identify(fields, tracker: device.trackerKind.flatMap(TrackerKind.init(rawValue:)))
        device.store(identity, confirmed: false)
        save()
        liveStore[uuid]?.identity = identity
        devicesUpdated.send()
    }

    /// Other saved devices that advertise the same coarse signature, e.g. the
    /// same phone after it changed its Bluetooth address.
    func devicesSharingSignature(with device: BluetoothDevice) -> [BluetoothDevice] {
        guard let key = device.signatureKey, let uuid = device.uuid else { return [] }
        let request: NSFetchRequest<BluetoothDevice> = BluetoothDevice.fetchRequest()
        request.predicate = NSPredicate(format: "signatureKey == %@ AND uuid != %@ AND manufacturerConfirmed != YES", key, uuid)
        return (try? viewContext.fetch(request)) ?? []
    }

    func applyConfirmedIdentity(from device: BluetoothDevice, to others: [BluetoothDevice]) {
        let identity = device.storedIdentity
        guard identity.confidence == .confirmed else { return }
        for other in others {
            guard let uuid = other.uuid else { continue }
            confirmIdentity(uuid: uuid, manufacturer: identity.manufacturer, category: identity.category, model: identity.model)
        }
    }

    func trust(forUUID uuid: String) -> TrustLevel {
        liveStore[uuid]?.trust ?? getDevice(byUUID: uuid)?.trust ?? .unknown
    }

    func clearAllData() {
        for entity in ["DeviceDetection", "DeviceLog", "BluetoothDevice"] {
            let request = NSFetchRequest<NSFetchRequestResult>(entityName: entity)
            _ = try? viewContext.execute(NSBatchDeleteRequest(fetchRequest: request))
        }
        viewContext.reset()
        liveStore.removeAll()
        sightings.removeAll()
        lastPersisted.removeAll()
        lastAlerted.removeAll()
        departed.removeAll()
        linker = EntityLinker()
        lookalikes.reset()
        adFields.removeAll()
        lookalikeStore.removeAll()
        devicesUpdated.send()
        detectionsUpdated.send()
    }

    /// Writes all stored detections to a CSV file and returns its URL.
    func exportCSV() -> URL? {
        let request: NSFetchRequest<DeviceDetection> = DeviceDetection.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: true)]
        guard let detections = try? viewContext.fetch(request) else { return nil }

        let iso = ISO8601DateFormatter()
        func quoted(_ value: String?) -> String {
            "\"" + (value ?? "").replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        var csv = "timestamp,device_id,name,type,rssi,latitude,longitude,"
            + "manufacturer,identified_type,model,identity_confidence,identity_confirmed,identity_evidence,"
            + "trust,signature,raw_advertisement\n"
        for detection in detections {
            let device = detection.device
            let identity = device?.storedIdentity
            let hasFix = detection.latitude != 0 || detection.longitude != 0
            csv += [
                detection.timestamp.map { iso.string(from: $0) } ?? "",
                device?.uuid ?? "",
                quoted(device?.name),
                quoted(device?.deviceType),
                "\(detection.rssi)",
                hasFix ? "\(detection.latitude)" : "",
                hasFix ? "\(detection.longitude)" : "",
                quoted(identity?.manufacturer),
                quoted(identity.map { $0.category == .unknown ? "" : $0.category.rawValue }),
                quoted(identity?.model),
                quoted(identity?.confidence.rawValue),
                device?.manufacturerConfirmed == true ? "yes" : "no",
                quoted(identity?.evidence.joined(separator: "; ")),
                device?.trust.rawValue ?? "",
                quoted(device?.signatureKey),
                quoted(device?.advertisementJSON)
            ].joined(separator: ",") + "\n"
        }

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("BlueClues-detections.csv")
        do {
            try csv.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            print("DeviceService: export failed: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: Detection history
    func getDetectionHistory(forDevice device: BluetoothDevice, limit: Int = 100) -> [DeviceDetection] {
        let request: NSFetchRequest<DeviceDetection> = DeviceDetection.fetchRequest()
        request.predicate = NSPredicate(format: "device == %@", device)
        request.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: false)]
        request.fetchLimit = limit
        return (try? viewContext.fetch(request)) ?? []
    }

    func getDeviceLogs(forDevice device: BluetoothDevice, limit: Int = 50) -> [DeviceLog] {
        let request: NSFetchRequest<DeviceLog> = DeviceLog.fetchRequest()
        request.predicate = NSPredicate(format: "device == %@", device)
        request.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: false)]
        request.fetchLimit = limit
        return (try? viewContext.fetch(request)) ?? []
    }

    // MARK: Pattern of life
    func getDevicePresencePattern(forDevice device: BluetoothDevice, days: Int = 7) -> [Date: Bool] {
        let endDate = Date()
        guard let startDate = Calendar.current.date(byAdding: .day, value: -days, to: endDate) else { return [:] }
        let request: NSFetchRequest<DeviceDetection> = DeviceDetection.fetchRequest()
        request.predicate = NSPredicate(format: "device == %@ AND timestamp >= %@ AND timestamp <= %@",
                                        device, startDate as NSDate, endDate as NSDate)
        request.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: true)]
        let detections = (try? viewContext.fetch(request)) ?? []

        let calendar = Calendar.current
        let presentDays = Set(detections.compactMap { $0.timestamp.map { calendar.startOfDay(for: $0) } })
        var pattern: [Date: Bool] = [:]
        var day = calendar.startOfDay(for: startDate)
        while day <= endDate {
            pattern[day] = presentDays.contains(day)
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return pattern
    }

    func getDeviceArrivalDepartureTimes(forDevice device: BluetoothDevice, date: Date) -> [(type: String, time: Date)] {
        let startOfDay = Calendar.current.startOfDay(for: date)
        guard let endOfDay = Calendar.current.date(byAdding: .day, value: 1, to: startOfDay) else { return [] }
        let request: NSFetchRequest<DeviceDetection> = DeviceDetection.fetchRequest()
        request.predicate = NSPredicate(format: "device == %@ AND timestamp >= %@ AND timestamp < %@",
                                        device, startOfDay as NSDate, endOfDay as NSDate)
        request.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: true)]
        let times = ((try? viewContext.fetch(request)) ?? []).compactMap(\.timestamp)

        var events: [(type: String, time: Date)] = []
        var previous: Date?
        for time in times {
            if let previous {
                if time.timeIntervalSince(previous) > departureThreshold {
                    events.append(("departed", previous))
                    events.append(("arrived", time))
                }
            } else {
                events.append(("arrived", time))
            }
            previous = time
        }
        return events
    }

    func getDeviceStatistics(forDevice device: BluetoothDevice) -> DeviceStatistics {
        let countRequest: NSFetchRequest<DeviceDetection> = DeviceDetection.fetchRequest()
        countRequest.predicate = NSPredicate(format: "device == %@", device)
        let total = (try? viewContext.count(for: countRequest)) ?? 0

        let recent = getDetectionHistory(forDevice: device, limit: 100)
        let averageRSSI = recent.isEmpty ? 0 : recent.reduce(0) { $0 + Int($1.rssi) } / recent.count
        let daysActive = device.firstSeen.map {
            Calendar.current.dateComponents([.day], from: $0, to: Date()).day ?? 0
        } ?? 0

        return DeviceStatistics(totalDetections: total,
                                averageRSSI: averageRSSI,
                                lastSeen: device.lastSeen ?? .distantPast,
                                daysActive: daysActive)
    }
}

// MARK: - Supporting Types
struct DeviceStatistics {
    let totalDetections: Int
    let averageRSSI: Int
    let lastSeen: Date
    let daysActive: Int
}
