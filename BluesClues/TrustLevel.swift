//
//  TrustLevel.swift
//  BluesClues
//
//  How much the user trusts a device, and which devices may raise alerts.
//

import Foundation

// MARK: - Trust Level
enum TrustLevel: String, CaseIterable, Identifiable {
    case unknown
    case mine
    case friendly
    case questionable

    var id: String { rawValue }

    var title: String {
        switch self {
        case .unknown: return "Unknown"
        case .mine: return "Mine"
        case .friendly: return "Friendly"
        case .questionable: return "Questionable"
        }
    }

    var systemImage: String {
        switch self {
        case .unknown: return "questionmark.circle"
        case .mine: return "person.crop.circle.badge.checkmark"
        case .friendly: return "hand.thumbsup"
        case .questionable: return "eye.trianglebadge.exclamationmark"
        }
    }

    /// Mine and friendly devices never alert.
    var canAlert: Bool { self == .unknown || self == .questionable }
}

// MARK: - Alert Scope
enum AlertScope: String, CaseIterable, Identifiable {
    case allUnknown = "All unknown devices"
    case trackersOnly = "Trackers only"

    var id: String { rawValue }
}

// MARK: - Alert Policy
enum AlertPolicy {
    static func isEligible(trust: TrustLevel, isTracker: Bool, scope: AlertScope) -> Bool {
        trust.canAlert && (scope == .allUnknown || isTracker)
    }
}
