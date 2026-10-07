//
//  BluesCluesApp.swift
//  BluesClues
//
//  Created by Jared Maxwell on 8/31/25.
//

import SwiftUI

@main
struct BluesCluesApp: App {
    let persistenceController = PersistenceController.shared
    // The one DeviceService for the whole app; every tab shares it.
    @StateObject private var deviceService = DeviceService()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
                .environmentObject(deviceService)
        }
    }
}
