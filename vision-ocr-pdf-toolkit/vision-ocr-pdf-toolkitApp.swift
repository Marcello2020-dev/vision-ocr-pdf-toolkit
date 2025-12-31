//
//  vision-ocr-pdf-toolkitApp.swift
//  vision-ocr-pdf-toolkit
//
//  Created by Marcel Mißbach on 28.12.25.
//

import SwiftUI
import AppKit

@main
struct vision_ocr_pdf_toolkitApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .onAppear {
                    DispatchQueue.main.async {
                        guard let window = NSApplication.shared.windows.first,
                              let screen = window.screen ?? NSScreen.main
                        else { return }

                        // sichtbare Fläche = Desktop ohne Menüleiste/Dock
                        window.setFrame(screen.visibleFrame, display: true)
                    }
                }
        }
    }
}
