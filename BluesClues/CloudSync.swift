//
//  CloudSync.swift
//  BluesClues
//
//  Optional iCloud sync of devices, labels, logs and sightings through Core
//  Data + CloudKit, into the user's own private iCloud database. BlueClues
//  has no server; the developer can't read a user's private database.
//
//  CloudKit needs an app signed by a paid Apple Developer account with the
//  iCloud capability. A build turns sync on by setting the
//  BLUECLUES_CLOUDKIT_CONTAINER build setting (e.g. iCloud.<bundle id>) and
//  signing with BluesClues-iCloud.entitlements. Without that, the toggle
//  explains why sync isn't available and the app keeps data on the phone.
//

import Foundation
import CoreData
import CloudKit

enum CloudSync {
    private static let enabledKey = "iCloudSyncEnabled"

    /// The CloudKit container this build was signed for, if any.
    static var containerIdentifier: String? {
        let value = (Bundle.main.object(forInfoDictionaryKey: "BlueCluesCloudKitContainer") as? String)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        return value.isEmpty || value.hasPrefix("$(") ? nil : value
    }

    static var isAvailableInThisBuild: Bool { containerIdentifier != nil }

    /// The user's choice. Read once at launch; changing it needs a restart.
    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    static var shouldSync: Bool { isAvailableInThisBuild && isEnabled }
}

// MARK: - Sync Monitor
/// Watches CloudKit sync events so Settings can show what's happening.
@MainActor
final class CloudSyncMonitor: ObservableObject {
    @Published private(set) var lastSuccess: Date?
    @Published private(set) var lastError: String?
    @Published private(set) var accountStatus: String?
    @Published private(set) var isActive = false

    private var observer: NSObjectProtocol?

    init() {
        isActive = PersistenceController.shared.isSyncing
        guard isActive else { return }
        observer = NotificationCenter.default.addObserver(
            forName: NSPersistentCloudKitContainer.eventChangedNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let event = notification.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                    as? NSPersistentCloudKitContainer.Event, event.endDate != nil else { return }
            Task { @MainActor in
                if let error = event.error {
                    self?.lastError = error.localizedDescription
                } else {
                    self?.lastSuccess = event.endDate
                    self?.lastError = nil
                }
            }
        }
        refreshAccountStatus()
    }

    func refreshAccountStatus() {
        // Only touch CloudKit when the build is entitled for it; CKContainer
        // traps in builds without the iCloud entitlement.
        guard isActive, let identifier = CloudSync.containerIdentifier else { return }
        CKContainer(identifier: identifier).accountStatus { [weak self] status, _ in
            let text: String
            switch status {
            case .available: text = "Signed in to iCloud"
            case .noAccount: text = "Not signed in to iCloud. Sign in from the Settings app."
            case .restricted: text = "iCloud is restricted on this iPhone."
            case .temporarilyUnavailable: text = "iCloud is temporarily unavailable."
            case .couldNotDetermine: text = "Couldn't check the iCloud account."
            @unknown default: text = "Unknown iCloud account status."
            }
            Task { @MainActor in self?.accountStatus = text }
        }
    }
}
