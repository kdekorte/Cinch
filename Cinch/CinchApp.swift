//
//  CinchApp.swift
//  Cinch
//
//  Created by Kevin DeKorte on 7/13/26.
//

import SwiftUI
import UniformTypeIdentifiers
#if canImport(AppKit)
import AppKit
#endif

@Observable class AppModel {
    // Menu intents to be handled by ContentView via .onReceive
    enum Intent { case newDocument, newTarDocument, open, save, saveAs, addFiles, setPassword, quit }
    var intent: Intent? = nil
}

@main
struct CinchApp: App {
    @State private var appModel = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appModel)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Zip Archive") { appModel.intent = .newDocument } // NEW: New Zip Creation
                    .keyboardShortcut("n", modifiers: [.command])
                Button("New tar.gz Archive") { appModel.intent = .newTarDocument }
                    .keyboardShortcut("n", modifiers: [.command, .option])

                Button("Open…") { appModel.intent = .open }
                    .keyboardShortcut("o", modifiers: [.command])
            }

            CommandGroup(replacing: .saveItem) {
                Button("Save") { appModel.intent = .save }
                    .keyboardShortcut("s", modifiers: [.command])

                Button("Save As…") { appModel.intent = .saveAs }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
            }

            CommandGroup(after: .saveItem) {
                Button("Set Password…") { appModel.intent = .setPassword }
                Button("Add Files to Zip…") { appModel.intent = .addFiles }
                    .keyboardShortcut("a", modifiers: [.command])
            }
            
            CommandGroup(before: .appTermination) {
                Divider()
            }
        }
    }
}
