//
//  ScanEngine.swift
//  BluesClues
//
//  The app's only CBCentralManager and CLLocationManager. Reports every
//  advertisement it hears, tagged with the latest location fix.
//

import Foundation
import CoreBluetooth
import CoreLocation
import UIKit

// MARK: - Advertisement
struct Advertisement {
    let peripheralID: String
    let name: String?
    let rssi: Int
    let time: Date
    let latitude: Double?
    let longitude: Double?
    let tracker: TrackerMatch?
    let signature: AdvertisementSignature?
    let fields: AdvertisementFields
    let summary: String
}

// MARK: - Scan Engine Delegate
protocol ScanEngineDelegate: AnyObject {
    func scanEngine(_ engine: ScanEngine, didReceive advertisement: Advertisement)
    func scanEngine(_ engine: ScanEngine, didUpdateBluetoothState state: CBManagerState)
    func scanEngine(_ engine: ScanEngine, didUpdateLocationAuthorization status: CLAuthorizationStatus)
}

// MARK: - Scan Engine
final class ScanEngine: NSObject, CBCentralManagerDelegate, CLLocationManagerDelegate {
    private var centralManager: CBCentralManager!
    private let locationManager = CLLocationManager()
    private var wantsScanning = false
    private var mode: ScanMode = .inMotion
    private var isInBackground = false

    weak var delegate: ScanEngineDelegate?

    private(set) var bluetoothState: CBManagerState = .unknown
    private(set) var lastLocation: CLLocation?
    var locationAuthorization: CLAuthorizationStatus { locationManager.authorizationStatus }

    override init() {
        super.init()
        // Delegate callbacks arrive on the main queue so DeviceService can touch
        // Core Data's viewContext and @Published state directly.
        centralManager = CBCentralManager(
            delegate: self,
            queue: nil,
            options: [CBCentralManagerOptionRestoreIdentifierKey: "BluesCluesCentral"]
        )
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        locationManager.distanceFilter = 50
        locationManager.pausesLocationUpdatesAutomatically = false

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(appDidEnterBackground),
                           name: UIApplication.didEnterBackgroundNotification, object: nil)
        center.addObserver(self, selector: #selector(appWillEnterForeground),
                           name: UIApplication.willEnterForegroundNotification, object: nil)
    }

    // MARK: Control
    func start(mode: ScanMode) {
        self.mode = mode
        wantsScanning = true
        startLocation()
        restartScan()
    }

    func stop() {
        wantsScanning = false
        if centralManager.isScanning { centralManager.stopScan() }
        locationManager.stopUpdatingLocation()
        locationManager.stopMonitoringSignificantLocationChanges()
    }

    func setMode(_ mode: ScanMode) {
        self.mode = mode
        if wantsScanning { startLocation() }
    }

    private func restartScan() {
        guard wantsScanning, centralManager.state == .poweredOn else { return }
        if centralManager.isScanning { centralManager.stopScan() }
        if isInBackground {
            // In the background iOS only delivers peripherals advertising a
            // requested service, and coalesces duplicates.
            let services = TrackerSignatures.backgroundScanServices.map { CBUUID(string: $0) }
            centralManager.scanForPeripherals(withServices: services, options: nil)
        } else {
            centralManager.scanForPeripherals(withServices: nil,
                                              options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        }
    }

    private func startLocation() {
        switch locationManager.authorizationStatus {
        case .notDetermined:
            locationManager.requestWhenInUseAuthorization()
            return
        case .authorizedWhenInUse where mode == .inMotion:
            // Ask for Always so in-motion keeps working with the screen off.
            locationManager.requestAlwaysAuthorization()
        case .denied, .restricted:
            return
        default:
            break
        }

        switch mode {
        case .inMotion:
            // Continuous updates keep the app running in the background while
            // moving, so Bluetooth sightings get a location attached.
            locationManager.allowsBackgroundLocationUpdates = true
            locationManager.showsBackgroundLocationIndicator = true
            locationManager.stopMonitoringSignificantLocationChanges()
            locationManager.startUpdatingLocation()
        case .stationary:
            locationManager.stopUpdatingLocation()
            locationManager.allowsBackgroundLocationUpdates = false
            locationManager.startMonitoringSignificantLocationChanges()
        }
    }

    @objc private func appDidEnterBackground() {
        isInBackground = true
        restartScan()
    }

    @objc private func appWillEnterForeground() {
        isInBackground = false
        restartScan()
    }

    // MARK: CBCentralManagerDelegate
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        bluetoothState = central.state
        delegate?.scanEngine(self, didUpdateBluetoothState: central.state)
        if central.state == .poweredOn { restartScan() }
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        // iOS relaunched us for a background Bluetooth event; resume scanning
        // once the manager reports poweredOn.
        wantsScanning = true
        isInBackground = true
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        let rssi = RSSI.intValue
        // 127 means "RSSI unavailable".
        guard rssi != 127 else { return }

        let manufacturerData = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data
        let serviceUUIDs = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? [])
            .map(\.uuidString)
        let serviceData = (advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data] ?? [:])
            .reduce(into: [String: Data]()) { $0[$1.key.uuidString] = $1.value }
        let tracker = TrackerSignatures.classify(manufacturerData: manufacturerData,
                                                 serviceUUIDs: serviceUUIDs,
                                                 serviceData: serviceData)

        let localName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let txPower = (advertisementData[CBAdvertisementDataTxPowerLevelKey] as? NSNumber)?.intValue
        let fields = AdvertisementFields(manufacturerData: manufacturerData,
                                         serviceUUIDs: serviceUUIDs.sorted(),
                                         serviceDataUUIDs: serviceData.keys.sorted(),
                                         localName: localName ?? peripheral.name,
                                         txPower: txPower)
        let signature = AdvertisementSignature.make(
            manufacturerData: manufacturerData,
            serviceUUIDs: serviceUUIDs,
            hasLocalName: !(localName ?? "").isEmpty,
            txPower: txPower)

        var summaryParts: [String] = []
        if let manufacturerData { summaryParts.append("mfr=\(manufacturerData.map { String(format: "%02X", $0) }.joined())") }
        if !serviceUUIDs.isEmpty { summaryParts.append("services=\(serviceUUIDs.joined(separator: ","))") }
        if !serviceData.isEmpty { summaryParts.append("serviceData=\(serviceData.keys.sorted().joined(separator: ","))") }

        let advertisement = Advertisement(
            peripheralID: peripheral.identifier.uuidString,
            name: peripheral.name ?? localName,
            rssi: rssi,
            time: Date(),
            latitude: lastLocation?.coordinate.latitude,
            longitude: lastLocation?.coordinate.longitude,
            tracker: tracker,
            signature: signature,
            fields: fields,
            summary: summaryParts.joined(separator: " ")
        )
        delegate?.scanEngine(self, didReceive: advertisement)
    }

    // MARK: CLLocationManagerDelegate
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last, location.horizontalAccuracy >= 0 else { return }
        lastLocation = location
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        delegate?.scanEngine(self, didUpdateLocationAuthorization: manager.authorizationStatus)
        if wantsScanning { startLocation() }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("ScanEngine: location error: \(error.localizedDescription)")
    }
}
