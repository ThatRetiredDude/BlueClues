//
//  TrackerSignatures.swift
//  BluesClues
//
//  Recognizes known Bluetooth item trackers from their advertisement payloads,
//  which stay recognizable even when the tracker rotates its Bluetooth address.
//

import Foundation

// MARK: - Tracker Kind
enum TrackerKind: String, CaseIterable, Identifiable {
    case appleFindMy = "Apple Find My"
    case tile = "Tile"
    case samsungSmartTag = "Samsung SmartTag"
    case googleFindMyDevice = "Google Find My Device"
    case chipolo = "Chipolo"

    var id: String { rawValue }

    /// Whether this kind normally changes its Bluetooth address while in use,
    /// so sightings under a new identifier may belong to the same physical tag.
    var rotatesAddress: Bool {
        switch self {
        case .tile, .chipolo: return false
        case .appleFindMy, .samsungSmartTag, .googleFindMyDevice: return true
        }
    }
}

// MARK: - Tracker Match
struct TrackerMatch: Equatable {
    let kind: TrackerKind
    /// True when the payload says the tag is away from its owner, which is the
    /// state a tag planted on someone else is in.
    let separatedFromOwner: Bool
}

// MARK: - Tracker Signatures
enum TrackerSignatures {
    // 16-bit service UUIDs, uppercased the way CBUUID.uuidString prints them.
    static let tileServices: Set<String> = ["FEED", "FEEC"]
    static let smartTagService = "FD5A"
    static let googleEddystoneService = "FEAA"
    static let chipoloService = "FE33"
    static let findMyAccessoryService = "FD44"

    /// Service UUIDs worth scanning for while the app is in the background,
    /// where iOS only reports peripherals that advertise a requested service.
    static let backgroundScanServices: [String] = [
        "FEED", "FEEC", smartTagService, googleEddystoneService, chipoloService, findMyAccessoryService
    ]

    private static let appleCompanyID: UInt16 = 0x004C
    private static let findMyType: UInt8 = 0x12
    private static let findMySeparatedLength: UInt8 = 0x19
    private static let googleFMDNFrameTypes: Set<UInt8> = [0x40, 0x41]

    /// - Parameters:
    ///   - manufacturerData: raw CBAdvertisementDataManufacturerDataKey value
    ///     (little-endian company ID followed by the payload).
    ///   - serviceUUIDs: advertised service UUID strings.
    ///   - serviceData: service data keyed by service UUID string.
    static func classify(manufacturerData: Data?,
                         serviceUUIDs: [String],
                         serviceData: [String: Data]) -> TrackerMatch? {
        let services = Set(serviceUUIDs.map { $0.uppercased() })
            .union(serviceData.keys.map { $0.uppercased() })
        let upperServiceData = Dictionary(serviceData.map { ($0.key.uppercased(), $0.value) },
                                          uniquingKeysWith: { first, _ in first })

        if let match = classifyApple(manufacturerData) {
            return match
        }
        if services.contains(findMyAccessoryService) {
            return TrackerMatch(kind: .appleFindMy, separatedFromOwner: false)
        }
        if !services.isDisjoint(with: tileServices) {
            return TrackerMatch(kind: .tile, separatedFromOwner: false)
        }
        if services.contains(smartTagService) {
            return TrackerMatch(kind: .samsungSmartTag, separatedFromOwner: smartTagSeparated(upperServiceData[smartTagService]))
        }
        if let eddystone = upperServiceData[googleEddystoneService],
           let frameType = eddystone.first,
           googleFMDNFrameTypes.contains(frameType) {
            return TrackerMatch(kind: .googleFindMyDevice, separatedFromOwner: true)
        }
        if services.contains(chipoloService) {
            return TrackerMatch(kind: .chipolo, separatedFromOwner: false)
        }
        return nil
    }

    /// Apple Find My "offline finding" advertisements: company 0x004C, type 0x12.
    /// A 25-byte payload means the accessory is separated from its owner.
    private static func classifyApple(_ data: Data?) -> TrackerMatch? {
        guard let data, data.count >= 4 else { return nil }
        let bytes = [UInt8](data)
        let company = UInt16(bytes[0]) | (UInt16(bytes[1]) << 8)
        guard company == appleCompanyID, bytes[2] == findMyType else { return nil }
        return TrackerMatch(kind: .appleFindMy, separatedFromOwner: bytes[3] == findMySeparatedLength)
    }

    /// SmartTag service data byte 0 carries the tag state in its upper three bits.
    /// Best-effort reading from public research: 1 = premature offline,
    /// 2 = offline, 3 = overmature offline (away from its owner for hours).
    private static func smartTagSeparated(_ data: Data?) -> Bool {
        guard let first = data?.first else { return false }
        let state = (first >> 5) & 0x07
        return state == 2 || state == 3
    }
}
