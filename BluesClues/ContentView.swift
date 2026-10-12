//
//  ContentView.swift
//  BluesClues
//
//  Created by Jared Maxwell on 8/31/25.
//

import SwiftUI
import CoreData

struct ContentView: View {
    var body: some View {
        MainTabView()
    }
}

#Preview {
    ContentView()
        .environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
        .environmentObject(DeviceService(persistenceController: .preview, autoStart: false))
}
