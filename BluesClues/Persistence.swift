//
//  Persistence.swift
//  BluesClues
//
//  Created by Jared Maxwell on 8/31/25.
//

import CoreData

struct PersistenceController {
    static let shared = PersistenceController()

    @MainActor
    static let preview: PersistenceController = {
        let result = PersistenceController(inMemory: true)
        let viewContext = result.container.viewContext
        // Create some sample Bluetooth devices for preview
        for i in 0..<5 {
            let device = BluetoothDevice(context: viewContext)
            device.uuid = "preview-device-\(i)"
            device.name = "Sample Device \(i + 1)"
            device.deviceType = ["Phone", "Headphones", "Computer", "Speaker"][i % 4]
            device.firstSeen = Date().addingTimeInterval(-Double(i) * 86400) // Days ago
            device.lastSeen = Date()
            device.isFavorite = i == 0
        }
        do {
            try viewContext.save()
        } catch {
            // Replace this implementation with code to handle the error appropriately.
            // fatalError() causes the application to generate a crash log and terminate. You should not use this function in a shipping application, although it may be useful during development.
            let nsError = error as NSError
            fatalError("Unresolved error \(nsError), \(nsError.userInfo)")
        }
        return result
    }()

    let container: NSPersistentContainer
    /// True when this run syncs with iCloud (see CloudSync).
    let isSyncing: Bool

    init(inMemory: Bool = false) {
        // NSPersistentCloudKitContainer behaves like a plain container when no
        // CloudKit options are set, so the same store works with sync on or off.
        let container = NSPersistentCloudKitContainer(name: "BluesClues")
        self.container = container
        guard let description = container.persistentStoreDescriptions.first else {
            fatalError("Missing store description")
        }
        if inMemory {
            description.url = URL(fileURLWithPath: "/dev/null")
        }
        description.shouldMigrateStoreAutomatically = true
        description.shouldInferMappingModelAutomatically = true
        // Always on, so turning sync on later doesn't need a store rebuild.
        description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
        description.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)

        var syncing = false
        if !inMemory, CloudSync.shouldSync, let identifier = CloudSync.containerIdentifier {
            description.cloudKitContainerOptions = NSPersistentCloudKitContainerOptions(containerIdentifier: identifier)
            syncing = true
        }

        var loadError: Error?
        container.loadPersistentStores { _, error in loadError = error }

        // If CloudKit setup fails, keep the data and run without sync.
        if loadError != nil, syncing {
            print("Persistence: iCloud sync unavailable, continuing without it: \(loadError!.localizedDescription)")
            description.cloudKitContainerOptions = nil
            syncing = false
            loadError = nil
            container.loadPersistentStores { _, error in loadError = error }
        }

        // Builds before the versioned model shipped an unversioned store that
        // can't be migrated. Only that case resets the store; any other error
        // stops the app rather than deleting data.
        if let error = loadError as NSError?, !inMemory,
           [NSPersistentStoreIncompatibleVersionHashError, NSMigrationMissingSourceModelError].contains(error.code),
           let url = description.url {
            print("Persistence: resetting incompatible store: \(error.localizedDescription)")
            try? container.persistentStoreCoordinator.destroyPersistentStore(at: url, ofType: NSSQLiteStoreType, options: nil)
            loadError = nil
            container.loadPersistentStores { _, error in loadError = error }
        }
        if let error = loadError {
            fatalError("Unable to open the BluesClues data store: \(error)")
        }
        isSyncing = syncing

        // Model version 2 replaced the "this is mine" flag with trust levels.
        let upgrade = NSBatchUpdateRequest(entityName: "BluetoothDevice")
        upgrade.predicate = NSPredicate(format: "isIgnored == YES")
        upgrade.propertiesToUpdate = ["trustLevel": TrustLevel.mine.rawValue, "isIgnored": false]
        _ = try? container.viewContext.execute(upgrade)

        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
    }
}

extension BluetoothDevice {
    var trust: TrustLevel {
        get { TrustLevel(rawValue: trustLevel ?? "") ?? .unknown }
        set { trustLevel = newValue.rawValue }
    }

    var advertisementFields: AdvertisementFields? {
        AdvertisementFields.fromJSON(advertisementJSON)
    }

    /// What is stored about who made this device: confirmed by the user or
    /// the latest automatic guess.
    var storedIdentity: DeviceIdentity {
        let category = DeviceCategory(rawValue: identifiedCategory ?? "") ?? .unknown
        guard manufacturer != nil || category != .unknown || identifiedModel != nil else { return .unknown }
        return DeviceIdentity(
            manufacturer: manufacturer,
            category: category,
            model: identifiedModel,
            confidence: manufacturerConfirmed ? .confirmed : IdentificationConfidence(rawValue: identityConfidence ?? "") ?? .low,
            evidence: (identityEvidence ?? "").split(separator: "\n").map(String.init))
    }

    /// Writes an identity, touching only fields that changed so routine
    /// sightings don't dirty the object.
    func store(_ identity: DeviceIdentity, confirmed: Bool) {
        func set<T: Equatable>(_ keyPath: ReferenceWritableKeyPath<BluetoothDevice, T>, _ value: T) {
            if self[keyPath: keyPath] != value { self[keyPath: keyPath] = value }
        }
        set(\.manufacturer, identity.manufacturer)
        set(\.identifiedCategory, identity.category == .unknown ? nil : identity.category.rawValue)
        set(\.identifiedModel, identity.model)
        set(\.identityConfidence, confirmed ? nil : identity.confidence.rawValue)
        set(\.identityEvidence, identity.evidence.isEmpty ? nil : identity.evidence.joined(separator: "\n"))
        set(\.manufacturerConfirmed, confirmed)
    }
}
