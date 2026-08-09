//
//  macOSFramesToFireTVApp.swift
//  macOSFramesToFireTV
//
//  Created by Aryan Rogye on 8/3/26.
//

import SwiftUI

@main
struct macOSFramesToFireTVApp: App {
    var body: some Scene {
        WindowGroup {
            MacContentView()
        }
        .defaultSize(width: 820, height: 590)
        .windowResizability(.contentMinSize)
    }
}
