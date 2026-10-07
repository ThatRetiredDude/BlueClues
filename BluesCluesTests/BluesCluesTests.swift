//
//  BluesCluesTests.swift
//  BluesCluesTests
//
//  Created by Jared Maxwell on 8/31/25.
//

import XCTest
@testable import BluesClues

final class TrackerSignaturesTests: XCTestCase {
    func testAppleFindMySeparated() {
        // 0x004C little-endian, type 0x12, length 0x19 = separated from owner.
        var payload: [UInt8] = [0x4C, 0x00, 0x12, 0x19, 0x10]
        payload += Array(repeating: 0xAB, count: 24)
        let match = TrackerSignatures.classify(manufacturerData: Data(payload), serviceUUIDs: [], serviceData: [:])
        XCTAssertEqual(match, TrackerMatch(kind: .appleFindMy, separatedFromOwner: true))
    }

    func testAppleFindMyNearOwner() {
        let payload: [UInt8] = [0x4C, 0x00, 0x12, 0x02, 0x00, 0x01]
        let match = TrackerSignatures.classify(manufacturerData: Data(payload), serviceUUIDs: [], serviceData: [:])
        XCTAssertEqual(match, TrackerMatch(kind: .appleFindMy, separatedFromOwner: false))
    }

    func testOtherAppleAdvertisementIsNotATracker() {
        // Type 0x10 is a Nearby Info message from an iPhone, not Find My.
        let payload: [UInt8] = [0x4C, 0x00, 0x10, 0x05, 0x01, 0x18]
        XCTAssertNil(TrackerSignatures.classify(manufacturerData: Data(payload), serviceUUIDs: [], serviceData: [:]))
    }

    func testTile() {
        XCTAssertEqual(TrackerSignatures.classify(manufacturerData: nil, serviceUUIDs: ["FEED"], serviceData: [:])?.kind, .tile)
        XCTAssertEqual(TrackerSignatures.classify(manufacturerData: nil, serviceUUIDs: [], serviceData: ["feec": Data([1])])?.kind, .tile)
    }

    func testSmartTagState() {
        let offline = TrackerSignatures.classify(manufacturerData: nil, serviceUUIDs: [], serviceData: ["FD5A": Data([0x40, 0x00])])
        XCTAssertEqual(offline, TrackerMatch(kind: .samsungSmartTag, separatedFromOwner: true))
        let connected = TrackerSignatures.classify(manufacturerData: nil, serviceUUIDs: [], serviceData: ["FD5A": Data([0x80, 0x00])])
        XCTAssertEqual(connected, TrackerMatch(kind: .samsungSmartTag, separatedFromOwner: false))
    }

    func testGoogleFindMyDeviceOnlyForFMDNFrames() {
        XCTAssertEqual(TrackerSignatures.classify(manufacturerData: nil, serviceUUIDs: [], serviceData: ["FEAA": Data([0x41, 0x00])])?.kind,
                       .googleFindMyDevice)
        // 0x10 is an ordinary Eddystone-URL beacon.
        XCTAssertNil(TrackerSignatures.classify(manufacturerData: nil, serviceUUIDs: [], serviceData: ["FEAA": Data([0x10, 0x00])]))
    }

    func testUnknownDevice() {
        XCTAssertNil(TrackerSignatures.classify(manufacturerData: Data([0x06, 0x00, 0x01]), serviceUUIDs: ["180F"], serviceData: [:]))
    }
}

final class FollowDetectorTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    private func sighting(_ minutes: Double, _ lat: Double?, _ lon: Double?) -> Sighting {
        Sighting(time: start.addingTimeInterval(minutes * 60), latitude: lat, longitude: lon, rssi: -70)
    }

    func testInMotionFlagsDeviceSeenAtThreePlaces() {
        // Roughly 1 km apart each.
        let sightings = [sighting(0, 40.000, -75.000), sighting(6, 40.009, -75.000), sighting(12, 40.018, -75.000)]
        let result = FollowDetector.assess(sightings, mode: .inMotion, now: start.addingTimeInterval(12 * 60))
        XCTAssertTrue(result.isSuspicious)
        XCTAssertEqual(result.score, 1, accuracy: 0.001)
    }

    func testInMotionIgnoresDeviceThatStaysInOnePlace() {
        let sightings = (0..<20).map { sighting(Double($0), 40.0, -75.0) }
        let result = FollowDetector.assess(sightings, mode: .inMotion, now: start.addingTimeInterval(20 * 60))
        XCTAssertFalse(result.isSuspicious)
    }

    func testInMotionNeedsEnoughTime() {
        let sightings = [sighting(0, 40.000, -75.000), sighting(1, 40.009, -75.000), sighting(2, 40.018, -75.000)]
        let result = FollowDetector.assess(sightings, mode: .inMotion, now: start.addingTimeInterval(2 * 60))
        XCTAssertFalse(result.isSuspicious)
    }

    func testStationaryFlagsLingeringDevice() {
        let sightings = stride(from: 0.0, through: 25.0, by: 1.0).map { sighting($0, nil, nil) }
        let result = FollowDetector.assess(sightings, mode: .stationary, now: start.addingTimeInterval(25 * 60))
        XCTAssertTrue(result.isSuspicious)
    }

    func testStationaryGapResetsPresence() {
        // Seen for 15 min, gone 10 min, back for 10 min: only the last run counts.
        let sightings = stride(from: 0.0, through: 15.0, by: 1.0).map { sighting($0, nil, nil) }
            + stride(from: 25.0, through: 35.0, by: 1.0).map { sighting($0, nil, nil) }
        let result = FollowDetector.assess(sightings, mode: .stationary, now: start.addingTimeInterval(35 * 60))
        XCTAssertFalse(result.isSuspicious)
        XCTAssertEqual(FollowDetector.currentPresence(sightings, maxGap: 300, now: start.addingTimeInterval(35 * 60)), 600, accuracy: 0.001)
    }

    func testStationaryNotNearbyAnymore() {
        let sightings = stride(from: 0.0, through: 30.0, by: 1.0).map { sighting($0, nil, nil) }
        let result = FollowDetector.assess(sightings, mode: .stationary, now: start.addingTimeInterval(60 * 60))
        XCTAssertFalse(result.isSuspicious)
    }

    func testInMotionFlagsDeviceSeenAtTwoPlaces() {
        // About 1 km apart, 6 minutes apart.
        let sightings = [sighting(0, 40.000, -75.000), sighting(6, 40.009, -75.000)]
        let result = FollowDetector.assess(sightings, mode: .inMotion, now: start.addingTimeInterval(6 * 60))
        XCTAssertTrue(result.isSuspicious)
    }

    func testInMotionOutAndBackIsNotSuspicious() {
        // Seen at home, then again at home 20 minutes later after a walk
        // where it wasn't heard: still one place.
        let sightings = [sighting(0, 40.0000, -75.000), sighting(20, 40.0010, -75.000)]
        let result = FollowDetector.assess(sightings, mode: .inMotion, now: start.addingTimeInterval(20 * 60))
        XCTAssertFalse(result.isSuspicious)
        XCTAssertEqual(FollowDetector.distinctPlaces(sightings, radius: 250), 1)
    }

    func testStationaryFlagsThreeSeparateVisits() {
        // Three short visits, each separated by more than 10 minutes.
        let sightings = [0.0, 1, 2, 15, 16, 30, 31, 32].map { sighting($0, nil, nil) }
        let result = FollowDetector.assess(sightings, mode: .stationary, now: start.addingTimeInterval(32 * 60))
        XCTAssertTrue(result.isSuspicious)
        XCTAssertEqual(FollowDetector.visitCount(sightings, gap: 600), 3)
        XCTAssertTrue(result.reason.hasPrefix("Came and went 3 times"))
    }

    func testStationaryTwoVisitsAreNotEnough() {
        let sightings = [0.0, 1, 2, 15, 16].map { sighting($0, nil, nil) }
        let result = FollowDetector.assess(sightings, mode: .stationary, now: start.addingTimeInterval(16 * 60))
        XCTAssertFalse(result.isSuspicious)
    }

    func testStationaryShortGapsAreOneVisit() {
        // Gaps of exactly 10 minutes don't start a new visit.
        let sightings = [0.0, 10, 20, 30].map { sighting($0, nil, nil) }
        XCTAssertEqual(FollowDetector.visitCount(sightings, gap: 600), 1)
    }

    func testStationaryVisitsOlderThanADayDontCount() {
        let sightings = [0.0, 20, 40].map { sighting($0, nil, nil) }
        let result = FollowDetector.assess(sightings, mode: .stationary, now: start.addingTimeInterval(25 * 60 * 60))
        XCTAssertFalse(result.isSuspicious)
    }

    func testDistance() {
        // One degree of latitude is about 111 km.
        XCTAssertEqual(FollowDetector.distanceMeters(lat1: 0, lon1: 0, lat2: 1, lon2: 0), 111_195, accuracy: 100)
    }
}

final class EntityLinkerTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    func testRotatedTrackerAddressLinksToSameEntity() {
        var linker = EntityLinker()
        let first = linker.entityID(forPeripheral: "A", kind: .samsungSmartTag, rssi: -60, at: start)
        let second = linker.entityID(forPeripheral: "B", kind: .samsungSmartTag, rssi: -63, at: start.addingTimeInterval(20))
        XCTAssertEqual(first, second)
    }

    func testDifferentKindsAreNotLinked() {
        var linker = EntityLinker()
        let first = linker.entityID(forPeripheral: "A", kind: .samsungSmartTag, rssi: -60, at: start)
        let second = linker.entityID(forPeripheral: "B", kind: .appleFindMy, rssi: -60, at: start.addingTimeInterval(20))
        XCTAssertNotEqual(first, second)
    }

    func testTwoTagsSeenAtOnceStaySeparate() {
        var linker = EntityLinker()
        let first = linker.entityID(forPeripheral: "A", kind: .appleFindMy, rssi: -60, at: start)
        // Second tag appears while the first is still advertising.
        let second = linker.entityID(forPeripheral: "B", kind: .appleFindMy, rssi: -61, at: start.addingTimeInterval(1))
        XCTAssertNotEqual(first, second)
    }

    func testLongGapStartsNewEntity() {
        var linker = EntityLinker()
        let first = linker.entityID(forPeripheral: "A", kind: .appleFindMy, rssi: -60, at: start)
        let second = linker.entityID(forPeripheral: "B", kind: .appleFindMy, rssi: -60, at: start.addingTimeInterval(600))
        XCTAssertNotEqual(first, second)
    }

    func testStaticAddressKindsAndUnknownDevicesAreNeverLinked() {
        var linker = EntityLinker()
        let tileA = linker.entityID(forPeripheral: "A", kind: .tile, rssi: -60, at: start)
        let tileB = linker.entityID(forPeripheral: "B", kind: .tile, rssi: -60, at: start.addingTimeInterval(20))
        XCTAssertNotEqual(tileA, tileB)
        let otherC = linker.entityID(forPeripheral: "C", kind: nil, rssi: -60, at: start)
        let otherD = linker.entityID(forPeripheral: "D", kind: nil, rssi: -60, at: start.addingTimeInterval(20))
        XCTAssertNotEqual(otherC, otherD)
    }

    func testSamePeripheralKeepsItsEntity() {
        var linker = EntityLinker()
        let first = linker.entityID(forPeripheral: "A", kind: nil, rssi: -60, at: start)
        let again = linker.entityID(forPeripheral: "A", kind: nil, rssi: -80, at: start.addingTimeInterval(5))
        XCTAssertEqual(first, again)
    }
}

final class AlertPolicyTests: XCTestCase {
    func testMineAndFriendlyNeverAlert() {
        for scope in AlertScope.allCases {
            XCTAssertFalse(AlertPolicy.isEligible(trust: .mine, isTracker: true, scope: scope))
            XCTAssertFalse(AlertPolicy.isEligible(trust: .friendly, isTracker: true, scope: scope))
        }
    }

    func testAllUnknownDevicesScope() {
        XCTAssertTrue(AlertPolicy.isEligible(trust: .unknown, isTracker: false, scope: .allUnknown))
        XCTAssertTrue(AlertPolicy.isEligible(trust: .questionable, isTracker: false, scope: .allUnknown))
    }

    func testTrackersOnlyScope() {
        XCTAssertFalse(AlertPolicy.isEligible(trust: .unknown, isTracker: false, scope: .trackersOnly))
        XCTAssertFalse(AlertPolicy.isEligible(trust: .questionable, isTracker: false, scope: .trackersOnly))
        XCTAssertTrue(AlertPolicy.isEligible(trust: .unknown, isTracker: true, scope: .trackersOnly))
    }
}

final class AdvertisementSignatureTests: XCTestCase {
    func testAppleSignatureIgnoresRotatingPayload() {
        let a = AdvertisementSignature.make(manufacturerData: Data([0x4C, 0x00, 0x10, 0x05, 0x01, 0x18, 0xAA]),
                                            serviceUUIDs: [], hasLocalName: false, txPower: 12)
        let b = AdvertisementSignature.make(manufacturerData: Data([0x4C, 0x00, 0x10, 0x05, 0x03, 0x1C, 0x42]),
                                            serviceUUIDs: [], hasLocalName: false, txPower: 12)
        XCTAssertNotNil(a)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a?.companyID, 0x004C)
        XCTAssertEqual(a?.appleMessageType, 0x10)
        XCTAssertEqual(a?.displayName, "Apple device (Nearby Info)")
    }

    func testDifferentAppleMessageTypesDiffer() {
        let nearby = AdvertisementSignature.make(manufacturerData: Data([0x4C, 0x00, 0x10, 0x05]), serviceUUIDs: [], hasLocalName: false, txPower: nil)
        let airpods = AdvertisementSignature.make(manufacturerData: Data([0x4C, 0x00, 0x07, 0x19]), serviceUUIDs: [], hasLocalName: false, txPower: nil)
        XCTAssertNotEqual(nearby?.key, airpods?.key)
    }

    func testServicesAreSortedAndUppercased() {
        let a = AdvertisementSignature.make(manufacturerData: nil, serviceUUIDs: ["fe9f", "180F"], hasLocalName: true, txPower: nil)
        let b = AdvertisementSignature.make(manufacturerData: nil, serviceUUIDs: ["180F", "FE9F"], hasLocalName: true, txPower: nil)
        XCTAssertEqual(a?.services, ["180F", "FE9F"])
        XCTAssertEqual(a?.key, b?.key)
    }

    func testNameAndTxPowerAreParts() {
        let base = AdvertisementSignature.make(manufacturerData: Data([0x06, 0x00, 0x01]), serviceUUIDs: [], hasLocalName: false, txPower: nil)
        let named = AdvertisementSignature.make(manufacturerData: Data([0x06, 0x00, 0x01]), serviceUUIDs: [], hasLocalName: true, txPower: nil)
        let powered = AdvertisementSignature.make(manufacturerData: Data([0x06, 0x00, 0x01]), serviceUUIDs: [], hasLocalName: false, txPower: 4)
        XCTAssertNotEqual(base?.key, named?.key)
        XCTAssertNotEqual(base?.key, powered?.key)
    }

    func testEmptyAdvertisementHasNoSignature() {
        XCTAssertNil(AdvertisementSignature.make(manufacturerData: nil, serviceUUIDs: [], hasLocalName: true, txPower: 8))
    }
}

final class LookalikeTrackerTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)
    private let sig = "c004C|t10|s|n0|p-"

    private func record(_ tracker: inout LookalikeTracker, _ minutes: Double, _ lat: Double, peripheral: String) {
        tracker.record(signature: sig, peripheralID: peripheral, time: start.addingTimeInterval(minutes * 60),
                       latitude: lat, longitude: -75.0)
    }

    func testRotatingAddressesAtThreePlacesAreFlagged() {
        var tracker = LookalikeTracker()
        record(&tracker, 0, 40.000, peripheral: "A")
        record(&tracker, 6, 40.009, peripheral: "B")
        record(&tracker, 12, 40.018, peripheral: "C")
        let result = tracker.assess(sig, now: start.addingTimeInterval(12 * 60))
        XCTAssertTrue(result.isSuspicious)
        XCTAssertTrue(result.reason.contains("3 of your locations over 12 min"))
    }

    func testTwoPlacesAreNotEnough() {
        var tracker = LookalikeTracker()
        record(&tracker, 0, 40.000, peripheral: "A")
        record(&tracker, 12, 40.009, peripheral: "B")
        XCTAssertFalse(tracker.assess(sig, now: start.addingTimeInterval(12 * 60)).isSuspicious)
    }

    func testThreePlacesTooQuicklyAreNotEnough() {
        var tracker = LookalikeTracker()
        record(&tracker, 0, 40.000, peripheral: "A")
        record(&tracker, 2, 40.009, peripheral: "B")
        record(&tracker, 4, 40.018, peripheral: "C")
        XCTAssertFalse(tracker.assess(sig, now: start.addingTimeInterval(4 * 60)).isSuspicious)
    }

    func testCrowdSignatureIsIgnored() {
        var tracker = LookalikeTracker()
        // Six different phones with the same signature within one minute.
        for i in 0..<6 {
            tracker.record(signature: sig, peripheralID: "crowd-\(i)", time: start.addingTimeInterval(Double(i) * 5),
                           latitude: 40.0, longitude: -75.0)
        }
        XCTAssertTrue(tracker.isCrowd(sig, now: start.addingTimeInterval(60)))
        record(&tracker, 6, 40.009, peripheral: "B")
        record(&tracker, 12, 40.018, peripheral: "C")
        XCTAssertFalse(tracker.assess(sig, now: start.addingTimeInterval(12 * 60)).isSuspicious)
    }

    func testFiveAtOnceIsNotACrowd() {
        var tracker = LookalikeTracker()
        for i in 0..<5 {
            tracker.record(signature: sig, peripheralID: "p-\(i)", time: start, latitude: 40.0, longitude: -75.0)
        }
        XCTAssertFalse(tracker.isCrowd(sig, now: start))
    }

    func testSignatureSeenOnlyFromTrustedDevicesIsSkipped() {
        var tracker = LookalikeTracker()
        record(&tracker, 0, 40.000, peripheral: "mine")
        record(&tracker, 6, 40.009, peripheral: "mine")
        record(&tracker, 12, 40.018, peripheral: "mine")
        let now = start.addingTimeInterval(12 * 60)
        XCTAssertFalse(tracker.assess(sig, now: now, isTrusted: { $0 == "mine" }).isSuspicious)
        XCTAssertTrue(tracker.assess(sig, now: now, isTrusted: { _ in false }).isSuspicious)
    }

    func testRecordIsThrottled() {
        var tracker = LookalikeTracker()
        XCTAssertTrue(tracker.record(signature: sig, peripheralID: "A", time: start, latitude: 40, longitude: -75))
        XCTAssertFalse(tracker.record(signature: sig, peripheralID: "A", time: start.addingTimeInterval(5), latitude: 40, longitude: -75))
        XCTAssertTrue(tracker.record(signature: sig, peripheralID: "A", time: start.addingTimeInterval(20), latitude: 40, longitude: -75))
    }

    func testPruneDropsOldObservations() {
        var tracker = LookalikeTracker()
        record(&tracker, 0, 40.0, peripheral: "A")
        tracker.prune(now: start.addingTimeInterval(7 * 60 * 60))
        XCTAssertNil(tracker.observations[sig])
    }
}

final class DeviceIdentifierTests: XCTestCase {
    private func fields(_ mfr: [UInt8]? = nil, services: [String] = [], serviceData: [String] = [], name: String? = nil) -> AdvertisementFields {
        AdvertisementFields(manufacturerData: mfr.map { Data($0) }, serviceUUIDs: services,
                            serviceDataUUIDs: serviceData, localName: name, txPower: nil)
    }

    func testAirPodsProFromProximityPairing() {
        let identity = DeviceIdentifier.identify(fields([0x4C, 0x00, 0x07, 0x19, 0x01, 0x0E, 0x20, 0x55]))
        XCTAssertEqual(identity.manufacturer, "Apple")
        XCTAssertEqual(identity.category, .earbuds)
        XCTAssertEqual(identity.model, "AirPods Pro")
        XCTAssertEqual(identity.confidence, .high)
    }

    func testBeatsModelIsCreditedToBeats() {
        let identity = DeviceIdentifier.identify(fields([0x4C, 0x00, 0x07, 0x19, 0x01, 0x0B, 0x20]))
        XCTAssertEqual(identity.model, "Powerbeats Pro")
        XCTAssertEqual(identity.manufacturer, "Beats (Apple)")
    }

    func testAppleNearbyInfoIsHighConfidenceApple() {
        let identity = DeviceIdentifier.identify(fields([0x4C, 0x00, 0x10, 0x05, 0x01, 0x18]))
        XCTAssertEqual(identity.manufacturer, "Apple")
        XCTAssertEqual(identity.confidence, .high)
        XCTAssertTrue(identity.evidence.contains { $0.contains("Nearby Info") })
    }

    func testInstantHotspotIsAPhone() {
        let identity = DeviceIdentifier.identify(fields([0x4C, 0x00, 0x0E, 0x06, 0x00]))
        XCTAssertEqual(identity.category, .phone)
    }

    func testSamsungTVFromName() {
        let identity = DeviceIdentifier.identify(fields(name: "[TV] Samsung 7 Series (55)"))
        XCTAssertEqual(identity.manufacturer, "Samsung")
        XCTAssertEqual(identity.category, .tv)
    }

    func testSamsungCompanyIDPlusBudsNameAgree() {
        let identity = DeviceIdentifier.identify(fields([0x75, 0x00, 0x01, 0x02], name: "Galaxy Buds2 Pro"))
        XCTAssertEqual(identity.manufacturer, "Samsung")
        XCTAssertEqual(identity.category, .earbuds)
        XCTAssertEqual(identity.confidence, .high)
    }

    func testChipMakerIsLowConfidence() {
        let identity = DeviceIdentifier.identify(fields([0x59, 0x00, 0x01]))
        XCTAssertEqual(identity.manufacturer, "Nordic Semiconductor")
        XCTAssertEqual(identity.confidence, .low)
    }

    func testBrandNameBeatsChipMaker() {
        let ranked = DeviceIdentifier.candidates(for: fields([0x5D, 0x00, 0x01], name: "JBL Flip 6"))
        XCTAssertEqual(ranked.first?.manufacturer, "JBL (Harman)")
        XCTAssertEqual(ranked.first?.category, .speaker)
        XCTAssertTrue(ranked.contains { $0.manufacturer == "Realtek" })
    }

    func testUnknownCompanyIDIsReported() {
        let identity = DeviceIdentifier.identify(fields([0x34, 0x12, 0x00]))
        XCTAssertEqual(identity.manufacturer, "Company 0x1234")
        XCTAssertEqual(identity.confidence, .low)
    }

    func testMicrosoftCDPWindowsPC() {
        let identity = DeviceIdentifier.identify(fields([0x06, 0x00, 0x01, 0x09, 0x20, 0x02]))
        XCTAssertNil(identity.manufacturer)
        XCTAssertEqual(identity.category, .computer)
        XCTAssertEqual(identity.label, "Windows PC")
    }

    func testTileService() {
        let identity = DeviceIdentifier.identify(fields(services: ["FEED"]), tracker: .tile)
        XCTAssertEqual(identity.manufacturer, "Tile")
        XCTAssertEqual(identity.category, .tracker)
    }

    func testFastPairAddsTypeToBrand() {
        let identity = DeviceIdentifier.identify(fields([0xE0, 0x00, 0x01], serviceData: ["FE2C"]))
        XCTAssertEqual(identity.manufacturer, "Google")
        XCTAssertEqual(identity.category, .earbuds)
    }

    func testTeslaKeyName() {
        let identity = DeviceIdentifier.identify(fields(name: "S0123456789abcdefC"))
        XCTAssertEqual(identity.manufacturer, "Tesla")
        XCTAssertEqual(identity.category, .car)
    }

    func testCarNameWithoutBrand() {
        let identity = DeviceIdentifier.identify(fields(name: "SYNC 3"))
        XCTAssertNil(identity.manufacturer)
        XCTAssertEqual(identity.category, .car)
    }

    func testHeartRateServiceGivesTypeOnly() {
        let identity = DeviceIdentifier.identify(fields(services: ["180D"]))
        XCTAssertNil(identity.manufacturer)
        XCTAssertEqual(identity.category, .watch)
    }

    func testNothingAdvertisedIsUnknown() {
        XCTAssertEqual(DeviceIdentifier.identify(fields()), .unknown)
        XCTAssertEqual(DeviceIdentity.unknown.label, "Unknown device")
    }

    func testFieldsMergeKeepsNameAndUnionsServices() {
        let first = fields([0x75, 0x00], services: ["180F"], name: "Galaxy S24")
        let later = fields([0x75, 0x00, 0x02], services: ["FE2C"])
        let merged = first.merged(with: later)
        XCTAssertEqual(merged.localName, "Galaxy S24")
        XCTAssertEqual(merged.serviceUUIDs, ["180F", "FE2C"])
        XCTAssertEqual(merged.manufacturerData, Data([0x75, 0x00, 0x02]))
    }

    func testFieldsJSONRoundTrip() {
        let original = fields([0x4C, 0x00, 0x10], services: ["FE9F"], name: "Phone")
        XCTAssertEqual(AdvertisementFields.fromJSON(original.json), original)
    }
}

final class PlaceSeenTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    func testGroupsNearbySightingsAndKeepsTimeRange() {
        let sightings = [
            Sighting(time: start, latitude: 40.0000, longitude: -75.0, rssi: -60),
            Sighting(time: start.addingTimeInterval(60), latitude: 40.0005, longitude: -75.0, rssi: -60),
            Sighting(time: start.addingTimeInterval(600), latitude: 40.0100, longitude: -75.0, rssi: -60),
            Sighting(time: start.addingTimeInterval(900), latitude: nil, longitude: nil, rssi: -60)
        ]
        let places = PlaceSeen.group(sightings, radius: 250)
        XCTAssertEqual(places.count, 2)
        // Most recent first.
        XCTAssertEqual(places[0].latitude, 40.0100, accuracy: 0.00001)
        XCTAssertEqual(places[1].sightings, 2)
        XCTAssertEqual(places[1].lastSeen, start.addingTimeInterval(60))
    }
}

final class AIPromptTests: XCTestCase {
    private let fields = AdvertisementFields(manufacturerData: Data([0x75, 0x00, 0x42, 0x09]),
                                             serviceUUIDs: ["FE2C"], serviceDataUUIDs: [],
                                             localName: "Jane's Galaxy Buds", txPower: 7)

    func testPromptContainsBroadcastDataAndGuesses() {
        let candidates = DeviceIdentifier.candidates(for: fields)
        let prompt = AIPrompts.devicePrompt(fields: fields, candidates: candidates, includeName: true)
        XCTAssertTrue(prompt.contains("75 00 42 09"))
        XCTAssertTrue(prompt.contains("Company ID: 0x0075"))
        XCTAssertTrue(prompt.contains("FE2C"))
        XCTAssertTrue(prompt.contains("Jane's Galaxy Buds"))
        XCTAssertTrue(prompt.contains("Samsung"))
        XCTAssertTrue(prompt.contains("Tx power: 7 dBm"))
    }

    func testNameCanBeWithheld() {
        let prompt = AIPrompts.devicePrompt(fields: fields, candidates: [], includeName: false)
        XCTAssertFalse(prompt.contains("Jane"))
        XCTAssertTrue(prompt.contains("(withheld by the user)"))
    }

    func testPromptHasNoLocationOrSignalStrength() {
        let prompt = AIPrompts.devicePrompt(fields: fields, candidates: DeviceIdentifier.candidates(for: fields), includeName: true)
        for word in ["latitude", "longitude", "RSSI", "dBm,", "timestamp"] {
            XCTAssertFalse(prompt.localizedCaseInsensitiveContains(word), word)
        }
    }

    func testParsesFencedJSON() throws {
        let reply = """
        Here you go:
        ```json
        {"manufacturer": "Samsung", "device_type": "Earbuds or headphones", "model": "Galaxy Buds2 Pro", "confidence": "high", "reasoning": "Samsung ID plus Fast Pair."}
        ```
        """
        let suggestion = try AIPrompts.parseSuggestion(reply, source: "test")
        XCTAssertEqual(suggestion.manufacturer, "Samsung")
        XCTAssertEqual(suggestion.category, .earbuds)
        XCTAssertEqual(suggestion.model, "Galaxy Buds2 Pro")
        XCTAssertEqual(suggestion.confidence, .high)
    }

    func testParsesNullsAndUnknownType() throws {
        let suggestion = try AIPrompts.parseSuggestion(
            #"{"manufacturer": null, "device_type": "spaceship", "model": "unknown", "confidence": "maybe", "reasoning": ""}"#,
            source: "test")
        XCTAssertNil(suggestion.manufacturer)
        XCTAssertNil(suggestion.model)
        XCTAssertEqual(suggestion.category, .unknown)
        XCTAssertEqual(suggestion.confidence, .low)
    }

    func testUnreadableReplyThrows() {
        XCTAssertThrowsError(try AIPrompts.parseSuggestion("I think it's a phone.", source: "test"))
    }
}

final class CloudSyncTests: XCTestCase {
    func testSyncIsUnavailableWithoutAContainer() {
        // Default builds don't set BLUECLUES_CLOUDKIT_CONTAINER.
        XCTAssertNil(CloudSync.containerIdentifier)
        XCTAssertFalse(CloudSync.isAvailableInThisBuild)
        XCTAssertFalse(CloudSync.shouldSync)
    }
}
