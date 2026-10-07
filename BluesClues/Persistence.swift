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

    init(inMemory: Bool = false) {
        container = NSPersistentContainer(name: "BluesClues")
        if inMemory {
            container.persistentStoreDescriptions.first!.url = URL(fileURLWithPath: "/dev/null")
        }
        container.persistentStoreDescriptions.first?.shouldMigrateStoreAutomatically = true
        container.persistentStoreDescriptions.first?.shouldInferMappingModelAutomatically = true

        var loadError: Error?
        container.loadPersistentStores { _, error in loadError = error }

        // Older builds shipped an unversioned model, so their stores can't be
        // migrated. Their data was unreliable anyway: start over with a fresh store.
        if let error = loadError, !inMemory,
           let url = container.persistentStoreDescriptions.first?.url {
            print("Persistence: resetting incompatible store: \(error.localizedDescription)")
            try? container.persistentStoreCoordinator.destroyPersistentStore(at: url, ofType: NSSQLiteStoreType, options: nil)
            loadError = nil
            container.loadPersistentStores { _, error in loadError = error }
        }
        if let error = loadError {
            fatalError("Unable to open the BluesClues data store: \(error)")
        }

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
}
