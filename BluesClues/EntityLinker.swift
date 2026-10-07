//
//  EntityLinker.swift
//  BluesClues
//
//  iOS gives every Bluetooth address its own peripheral identifier, and most
//  trackers change address every ~15 minutes. The linker joins those
//  identifiers back into one entity when a tracker of the same kind vanishes
//  and a new one appears right away at a similar signal strength.
//

import Foundation

struct EntityLinker {
    struct Entity {
        let id: String
        let kind: TrackerKind?
        var currentPeripheral: String
        var lastSeen: Date
        var lastRSSI: Int
    }

    /// The old identifier must have been silent at least this long...
    var minSilence: TimeInterval = 3
    /// ...and no longer than this when the new identifier appears.
    var maxHandoffGap: TimeInterval = 90
    /// Signal strengths must be within this many dB to be linked.
    var maxRSSIDelta = 15

    private(set) var entities: [String: Entity] = [:]
    private var peripheralToEntity: [String: String] = [:]

    /// Returns the entity id for this sighting, linking it to a recently
    /// vanished entity of the same rotating kind when one fits.
    mutating func entityID(forPeripheral peripheral: String,
                           kind: TrackerKind?,
                           rssi: Int,
                           at time: Date) -> String {
        if let id = peripheralToEntity[peripheral], var entity = entities[id] {
            entity.lastSeen = time
            entity.lastRSSI = rssi
            entities[id] = entity
            return id
        }

        let id = handoffCandidate(kind: kind, rssi: rssi, at: time) ?? peripheral
        var entity = entities[id] ?? Entity(id: id, kind: kind, currentPeripheral: peripheral, lastSeen: time, lastRSSI: rssi)
        entity.currentPeripheral = peripheral
        entity.lastSeen = time
        entity.lastRSSI = rssi
        entities[id] = entity
        peripheralToEntity[peripheral] = id
        return id
    }

    /// Drops entities not seen for `age`, keeping memory bounded.
    mutating func prune(olderThan age: TimeInterval, now: Date) {
        let stale = Set(entities.values.filter { now.timeIntervalSince($0.lastSeen) > age }.map(\.id))
        guard !stale.isEmpty else { return }
        entities = entities.filter { !stale.contains($0.key) }
        peripheralToEntity = peripheralToEntity.filter { !stale.contains($0.value) }
    }

    private func handoffCandidate(kind: TrackerKind?, rssi: Int, at time: Date) -> String? {
        guard let kind, kind.rotatesAddress else { return nil }
        return entities.values
            .filter { entity in
                let silence = time.timeIntervalSince(entity.lastSeen)
                return entity.kind == kind
                    && silence >= minSilence
                    && silence <= maxHandoffGap
                    && abs(entity.lastRSSI - rssi) <= maxRSSIDelta
            }
            .min { abs($0.lastRSSI - rssi) < abs($1.lastRSSI - rssi) }?
            .id
    }
}
