//
//  macOSFramesToFireTVApp.swift
//  macOSFramesToFireTV
//
//  Created by Aryan Rogye on 8/3/26.
//

import SwiftUI

@main
struct macOSFramesToFireTVApp: App {
    @State private var model = MacStreamingModel()

    var body: some Scene {
        MenuBarExtra {
            MacMenuBarContent(model: model)
        } label: {
            Label("Frames to Fire TV", systemImage: model.menuBarSymbol)
        }

        Window("Pair Receiver", id: MacPairingWindow.id) {
            MacPairingView(model: model)
        }
        .defaultLaunchBehavior(.suppressed)
        .defaultSize(width: 380, height: 280)
        .windowResizability(.contentSize)
    }
}
