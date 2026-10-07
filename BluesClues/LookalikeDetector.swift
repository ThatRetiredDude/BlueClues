//
//  LookalikeDetector.swift
//  BluesClues
//
//  Phones, watches and earbuds change their Bluetooth address every few
//  minutes, so a person following you shows up as a string of "new" devices.
//  This groups sightings by a coarse advertisement signature instead of by
//  address and flags a signature that keeps turning up wherever you go.
//  It is weaker evidence than a tracker match: many devices share a signature.
//

import Foundation

// MARK: - Advertisement Signature
struct AdvertisementSignature: Hashable {
    /// Bluetooth SIG company ID from the first two bytes of manufacturer data.
    let companyID: UInt16?
    /// Apple Continuity message type, when the company is Apple.
    let appleMessageType: UInt8?
    /// Advertised service UUIDs, uppercased and sorted.
    let services: [String]
    let hasLocalName: Bool
    let txPower: Int?

    static let appleCompanyID: UInt16 = 0x004C

    /// Builds a signature from the stable parts of an advertisement. RSSI and
    /// the rotating payload bytes are left out on purpose. Returns nil when the
    /// advertisement carries nothing distinctive.
    static func make(manufacturerData: Data?,
                     serviceUUIDs: [String],
                     hasLocalName: Bool,
                     txPower: Int?) -> AdvertisementSignature? {
        var companyID: UInt16?
        var appleMessageType: UInt8?
        if let manufacturerData, manufacturerData.count >= 2 {
            let bytes = [UInt8](manufacturerData)
            companyID = UInt16(bytes[0]) | (UInt16(bytes[1]) << 8)
            if companyID == appleCompanyID, bytes.count >= 3 {
                appleMessageType = bytes[2]
            }
        }
        let services = Set(serviceUUIDs.map { $0.uppercased() }).sorted()
        guard companyID != nil || !services.isEmpty else { return nil }
        return AdvertisementSignature(companyID: companyID,
                                      appleMessageType: appleMessageType,
                                      services: services,
                                      hasLocalName: hasLocalName,
                                      txPower: txPower)
    }

    var key: String {
        [
            companyID.map { String(format: "c%04X", $0) } ?? "c-",
            appleMessageType.map { String(format: "t%02X", $0) } ?? "t-",
            "s" + services.joined(separator: "+"),
            hasLocalName ? "n1" : "n0",
            txPower.map { "p\($0)" } ?? "p-"
        ].joined(separator: "|")
    }

    var displayName: String {
        if companyID == Self.appleCompanyID {
            let kind = appleMessageType.flatMap { Self.appleMessageNames[$0] }
            return kind.map { "Apple device (\($0))" } ?? "Apple device"
        }
        if let companyID {
            return Self.companyNames[companyID].map { "\($0) device" } ?? String(format: "Device from company 0x%04X", companyID)
        }
        return "Device advertising \(services.joined(separator: ", "))"
    }

    private static let companyNames: [UInt16: String] = [
        0x0006: "Microsoft", 0x0075: "Samsung", 0x00E0: "Google", 0x0087: "Garmin",
        0x0157: "Huami", 0x038F: "Xiaomi", 0x027D: "Huawei", 0x0059: "Nordic"
    ]

    private static let appleMessageNames: [UInt8: String] = [
        0x05: "AirDrop", 0x07: "AirPods", 0x09: "AirPlay", 0x0C: "Handoff",
        0x0F: "Nearby Action", 0x10: "Nearby Info", 0x12: "Find My"
    ]
}

// MARK: - Lookalike Configuration
struct LookalikeConfig {
    var minDistinctPlaces = 3
    var placeRadiusMeters: Double = 250
    var minDuration: TimeInterval = 10 * 60
    var lookback: TimeInterval = 6 * 60 * 60
    /// More than this many different addresses with one signature inside
    /// `crowdWindow` means the signature is crowd noise (a café full of iPhones).
    var crowdMaxPeripherals = 5
    var crowdWindow: TimeInterval = 60
    /// One stored observation per signature per this interval.
    var recordInterval: TimeInterval = 15
}

// MARK: - Lookalike Tracker
struct LookalikeTracker {
    struct Observation: Equatable {
        let peripheralID: String
        let time: Date
        let latitude: Double?
        let longitude: Double?
    }

    var config = LookalikeConfig()
    private(set) var observations: [String: [Observation]] = [:]
    /// Recent sightings (unthrottled peripheral IDs) for crowd detection.
    private var recentPeripherals: [String: [String: Date]] = [:]
    /// Signatures found to be crowd noise stay ignored until this time.
    private var crowdedUntil: [String: Date] = [:]

    init(config: LookalikeConfig = LookalikeConfig()) {
        self.config = config
    }

    /// Returns true when a new observation was stored (at most one per
    /// `recordInterval`), i.e. when the signature is worth reassessing.
    @discardableResult
    mutating func record(signature: String, peripheralID: String, time: Date, latitude: Double?, longitude: Double?) -> Bool {
        var recent = recentPeripherals[signature, default: [:]]
        recent[peripheralID] = time
        recent = recent.filter { time.timeIntervalSince($0.value) <= config.crowdWindow }
        recentPeripherals[signature] = recent
        if recent.count > config.crowdMaxPeripherals {
            crowdedUntil[signature] = time.addingTimeInterval(config.lookback)
        }

        let list = observations[signature, default: []]
        if let last = list.last, time.timeIntervalSince(last.time) < config.recordInterval { return false }
        observations[signature, default: []].append(
            Observation(peripheralID: peripheralID, time: time, latitude: latitude, longitude: longitude))
        return true
    }

    func isCrowd(_ signature: String, now: Date) -> Bool {
        guard let until = crowdedUntil[signature] else { return false }
        return now < until
    }

    /// - Parameter isTrusted: whether a peripheral is labeled Mine or Friendly.
    ///   Signatures seen only from trusted peripherals are skipped.
    func assess(_ signature: String, now: Date, isTrusted: (String) -> Bool = { _ in false }) -> FollowAssessment {
        let recent = (observations[signature] ?? []).filter { now.timeIntervalSince($0.time) <= config.lookback }
        guard let first = recent.first, let last = recent.last else {
            return FollowAssessment(isSuspicious: false, score: 0, reason: "Not seen recently")
        }
        let places = FollowDetector.distinctPlaces(
            recent.map { Sighting(time: $0.time, latitude: $0.latitude, longitude: $0.longitude, rssi: 0) },
            radius: config.placeRadiusMeters)
        let span = last.time.timeIntervalSince(first.time)
        let reason = "A device with the same signature showed up at \(places) of your locations over \(Int(span / 60)) min"

        let allTrusted = Set(recent.map(\.peripheralID)).allSatisfy(isTrusted)
        if isCrowd(signature, now: now) || allTrusted {
            return FollowAssessment(isSuspicious: false, score: 0, reason: reason)
        }
        let placeScore = min(1, Double(places) / Double(max(1, config.minDistinctPlaces)))
        let timeScore = min(1, span / max(1, config.minDuration))
        let suspicious = places >= config.minDistinctPlaces && span >= config.minDuration
        return FollowAssessment(isSuspicious: suspicious, score: placeScore * timeScore, reason: reason)
    }

    mutating func prune(now: Date) {
        for key in observations.keys {
            observations[key]?.removeAll { now.timeIntervalSince($0.time) > config.lookback }
        }
        observations = observations.filter { !$0.value.isEmpty }
        recentPeripherals = recentPeripherals.filter { entry in
            entry.value.values.contains { now.timeIntervalSince($0) <= config.crowdWindow }
        }
        crowdedUntil = crowdedUntil.filter { $0.value > now }
    }

    mutating func reset() {
        observations.removeAll()
        recentPeripherals.removeAll()
        crowdedUntil.removeAll()
    }
}
