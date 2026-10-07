//
//  FollowDetector.swift
//  BluesClues
//
//  Decides whether a device's sightings look like it is following the user
//  (in-motion mode) or lingering around them (stationary mode).
//

import Foundation

// MARK: - Scan Mode
enum ScanMode: String, CaseIterable, Identifiable {
    case inMotion = "In Motion"
    case stationary = "Stationary"

    var id: String { rawValue }

    var summary: String {
        switch self {
        case .inMotion:
            return "Flags devices that keep showing up at different places as you move."
        case .stationary:
            return "Flags unfamiliar devices that stay near you for a long time."
        }
    }
}

// MARK: - Sighting
struct Sighting: Equatable {
    let time: Date
    let latitude: Double?
    let longitude: Double?
    let rssi: Int
}

// MARK: - Detector Configuration
struct DetectorConfig {
    /// In motion: distinct places a device must be seen at.
    var minDistinctPlaces = 3
    /// In motion: two sightings closer than this count as the same place.
    var placeRadiusMeters: Double = 250
    /// In motion: minimum time between first and last sighting.
    var minFollowDuration: TimeInterval = 10 * 60
    /// Stationary: how long a device must stay around continuously.
    var minLingerDuration: TimeInterval = 20 * 60
    /// Stationary: a gap longer than this breaks continuous presence.
    var maxPresenceGap: TimeInterval = 5 * 60
    /// Only sightings this recent are considered.
    var lookback: TimeInterval = 6 * 60 * 60
}

// MARK: - Assessment
struct FollowAssessment: Equatable {
    let isSuspicious: Bool
    /// 0...1, how close the device is to meeting the alert rule.
    let score: Double
    let reason: String
}

// MARK: - Follow Detector
enum FollowDetector {
    static func assess(_ sightings: [Sighting],
                       mode: ScanMode,
                       config: DetectorConfig = DetectorConfig(),
                       now: Date = Date()) -> FollowAssessment {
        let recent = sightings
            .filter { now.timeIntervalSince($0.time) <= config.lookback }
            .sorted { $0.time < $1.time }
        guard let first = recent.first, let last = recent.last else {
            return FollowAssessment(isSuspicious: false, score: 0, reason: "Not seen recently")
        }

        switch mode {
        case .inMotion:
            let places = distinctPlaces(recent, radius: config.placeRadiusMeters)
            let span = last.time.timeIntervalSince(first.time)
            let placeScore = min(1, Double(places) / Double(max(1, config.minDistinctPlaces)))
            let timeScore = min(1, span / max(1, config.minFollowDuration))
            let suspicious = places >= config.minDistinctPlaces && span >= config.minFollowDuration
            let reason = "Seen at \(places) place\(places == 1 ? "" : "s") over \(minutesText(span))"
            return FollowAssessment(isSuspicious: suspicious, score: placeScore * timeScore, reason: reason)

        case .stationary:
            let presence = currentPresence(recent, maxGap: config.maxPresenceGap, now: now)
            let suspicious = presence >= config.minLingerDuration
            let score = min(1, presence / max(1, config.minLingerDuration))
            let reason = presence > 0 ? "Nearby for \(minutesText(presence))" : "Not nearby right now"
            return FollowAssessment(isSuspicious: suspicious, score: score, reason: reason)
        }
    }

    /// Greedy clustering: a sighting starts a new place when it is farther than
    /// `radius` from every place found so far. Sightings without a fix are skipped.
    static func distinctPlaces(_ sightings: [Sighting], radius: Double) -> Int {
        var centers: [(Double, Double)] = []
        for sighting in sightings {
            guard let lat = sighting.latitude, let lon = sighting.longitude else { continue }
            let isNew = centers.allSatisfy { distanceMeters(lat1: $0.0, lon1: $0.1, lat2: lat, lon2: lon) > radius }
            if isNew { centers.append((lat, lon)) }
        }
        return centers.count
    }

    /// Length of the unbroken run of sightings that reaches up to `now`.
    static func currentPresence(_ sorted: [Sighting], maxGap: TimeInterval, now: Date) -> TimeInterval {
        guard let last = sorted.last, now.timeIntervalSince(last.time) <= maxGap else { return 0 }
        var start = last.time
        for sighting in sorted.reversed().dropFirst() {
            if start.timeIntervalSince(sighting.time) > maxGap { break }
            start = sighting.time
        }
        return last.time.timeIntervalSince(start)
    }

    static func distanceMeters(lat1: Double, lon1: Double, lat2: Double, lon2: Double) -> Double {
        let earthRadius = 6_371_000.0
        let dLat = (lat2 - lat1) * .pi / 180
        let dLon = (lon2 - lon1) * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2)
            + cos(lat1 * .pi / 180) * cos(lat2 * .pi / 180) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * earthRadius * atan2(sqrt(a), sqrt(1 - a))
    }

    private static func minutesText(_ interval: TimeInterval) -> String {
        let minutes = Int(interval / 60)
        if minutes < 60 { return "\(minutes) min" }
        return "\(minutes / 60) h \(minutes % 60) min"
    }
}
