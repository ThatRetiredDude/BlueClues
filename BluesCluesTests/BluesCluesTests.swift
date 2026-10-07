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
