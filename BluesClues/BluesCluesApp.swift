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

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
        }
    }
}
