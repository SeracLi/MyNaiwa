//
//  MyNaiWaApp.swift
//  MyNaiWa
//
//  Created by Serac on 2026/6/26.
//

import SwiftUI
import AVFoundation

@main
struct MyNaiWaApp: App {
    init() {
        // Play audio through silent switch / DnD, matching the original naiwa app.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.light)
        }
    }
}
