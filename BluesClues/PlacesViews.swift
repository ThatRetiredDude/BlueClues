//
//  PlacesViews.swift
//  BluesClues
//
//  Shows where a device or log entry was recorded.
//

import SwiftUI
import MapKit

struct PlaceMap: View {
    let places: [PlaceSeen]

    var body: some View {
        Map(initialPosition: .automatic) {
            ForEach(places) { place in
                Marker(place.sightings > 1 ? "\(place.sightings)×" : "",
                       systemImage: "antenna.radiowaves.left.and.right",
                       coordinate: CLLocationCoordinate2D(latitude: place.latitude, longitude: place.longitude))
            }
        }
    }
}

struct PlacesSeenSection: View {
    let places: [PlaceSeen]

    private let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Where it was seen")
                .font(.headline)
            if places.isEmpty {
                Text("No locations recorded yet. Locations are saved with each sighting once BlueClues has a location fix.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                PlaceMap(places: places)
                    .frame(height: 200)
                    .cornerRadius(8)
                Text("\(places.count) place\(places.count == 1 ? "" : "s") (250 m apart)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                ForEach(places.prefix(10)) { place in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(String(format: "%.5f, %.5f", place.latitude, place.longitude))
                                .font(.subheadline)
                                .monospacedDigit()
                            Text(timeRange(place) + " · \(place.sightings) sighting\(place.sightings == 1 ? "" : "s")")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        if let url = place.mapsURL {
                            Link(destination: url) {
                                Image(systemName: "map")
                            }
                        }
                    }
                }
            }
        }
    }

    private func timeRange(_ place: PlaceSeen) -> String {
        let first = formatter.string(from: place.firstSeen)
        if place.lastSeen.timeIntervalSince(place.firstSeen) < 60 { return first }
        return "\(first) – \(formatter.string(from: place.lastSeen))"
    }
}
