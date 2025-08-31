//
//  BluetoothManager.swift
//  BluesClues
//
//  Created by Jared Maxwell on 8/31/25.
//

import Foundation
import CoreBluetooth
import CoreLocation
import Combine

// MARK: - Bluetooth Device Info
struct BluetoothDeviceInfo {
    let uuid: String
    let name: String?
    let rssi: Int
    let timestamp: Date
    let peripheral: CBPeripheral
    let advertisementData: [String: Any]
}

// MARK: - Bluetooth Manager Delegate
protocol BluetoothManagerDelegate: AnyObject {
    func bluetoothManager(_ manager: BluetoothManager, didDiscover device: BluetoothDeviceInfo)
    func bluetoothManager(_ manager: BluetoothManager, didUpdateState state: CBManagerState)
    func bluetoothManager(_ manager: BluetoothManager, didFailWithError error: Error)
}

// MARK: - Bluetooth Manager
class BluetoothManager: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    // MARK: - Properties
    private var centralManager: CBCentralManager!
    private var locationManager: CLLocationManager?
    private var discoveredDevices: [String: BluetoothDeviceInfo] = [:]
    private var scanningTimer: Timer?

    weak var delegate: BluetoothManagerDelegate?

    private(set) var isScanning = false
    private(set) var bluetoothState: CBManagerState = .unknown

    // Scanning configuration - simplified to let DeviceService control timing
    private let scanTimeout: TimeInterval = 60.0 // Maximum scan duration before auto-stop

    // MARK: - Initialization
    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: nil)

        // Initialize location manager for position data
        locationManager = CLLocationManager()
        locationManager?.requestWhenInUseAuthorization()
    }

    // MARK: - Public Methods
    func startScanning() {
        guard !isScanning else {
            print("Already scanning, ignoring start request")
            return
        }

        switch centralManager.state {
        case .poweredOn:
            isScanning = true
            discoveredDevices.removeAll()
            // Use CBCentralManagerScanOptionAllowDuplicatesKey to get continuous updates
            centralManager.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
            print("✅ Started Bluetooth scanning")
        case .poweredOff:
            print("❌ Bluetooth is powered off")
            delegate?.bluetoothManager(self, didFailWithError: NSError(domain: "BluetoothManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "Bluetooth is powered off"]))
        case .unauthorized:
            print("❌ Bluetooth access unauthorized - check app permissions")
            delegate?.bluetoothManager(self, didFailWithError: NSError(domain: "BluetoothManager", code: 2, userInfo: [NSLocalizedDescriptionKey: "Bluetooth access unauthorized"]))
        case .unsupported:
            print("❌ Bluetooth unsupported on this device")
            delegate?.bluetoothManager(self, didFailWithError: NSError(domain: "BluetoothManager", code: 3, userInfo: [NSLocalizedDescriptionKey: "Bluetooth unsupported on this device"]))
        default:
            print("⚠️ Bluetooth state: \(centralManager.state.rawValue)")
        }
    }

    func stopScanning() {
        guard isScanning else {
            print("Not scanning, ignoring stop request")
            return
        }

        isScanning = false
        centralManager.stopScan()
        print("🛑 Stopped Bluetooth scanning")
    }

    // MARK: - Private Methods

    private func getCurrentLocation() -> (latitude: Double, longitude: Double)? {
        guard let location = locationManager?.location else { return nil }
        return (location.coordinate.latitude, location.coordinate.longitude)
    }

    // MARK: - CBCentralManagerDelegate
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        bluetoothState = central.state
        delegate?.bluetoothManager(self, didUpdateState: central.state)

        switch central.state {
        case .poweredOn:
            print("Bluetooth is powered on")
        case .poweredOff:
            print("Bluetooth is powered off")
            stopScanning()
        case .resetting:
            print("Bluetooth is resetting")
        case .unauthorized:
            print("Bluetooth access unauthorized")
        case .unsupported:
            print("Bluetooth unsupported")
        case .unknown:
            print("Bluetooth state unknown")
        @unknown default:
            print("Unknown Bluetooth state")
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let uuid = peripheral.identifier.uuidString
        let deviceInfo = BluetoothDeviceInfo(
            uuid: uuid,
            name: peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String,
            rssi: RSSI.intValue,
            timestamp: Date(),
            peripheral: peripheral,
            advertisementData: advertisementData
        )

        // Update or add to discovered devices
        discoveredDevices[uuid] = deviceInfo

        // Notify delegate
        delegate?.bluetoothManager(self, didDiscover: deviceInfo)

        // Log discovery for debugging
        print("Discovered device: \(deviceInfo.name ?? "Unknown") (\(uuid)), RSSI: \(deviceInfo.rssi)")
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        print("Connected to peripheral: \(peripheral.name ?? "Unknown")")
        peripheral.delegate = self
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        if let error = error {
            print("Disconnected from peripheral with error: \(error.localizedDescription)")
        } else {
            print("Disconnected from peripheral: \(peripheral.name ?? "Unknown")")
        }
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        if let error = error {
            print("Failed to connect to peripheral with error: \(error.localizedDescription)")
        }
    }

    // MARK: - CBPeripheralDelegate
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error = error {
            print("Error discovering services: \(error.localizedDescription)")
            return
        }

        guard let services = peripheral.services else { return }

        for service in services {
            print("Discovered service: \(service.uuid)")
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error = error {
            print("Error discovering characteristics: \(error.localizedDescription)")
            return
        }

        guard let characteristics = service.characteristics else { return }

        for characteristic in characteristics {
            print("Discovered characteristic: \(characteristic.uuid)")
            // Read characteristic value if possible
            if characteristic.properties.contains(.read) {
                peripheral.readValue(for: characteristic)
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            print("Error reading characteristic value: \(error.localizedDescription)")
            return
        }

        if let value = characteristic.value {
            print("Characteristic \(characteristic.uuid) value: \(value)")
        }
    }
}
