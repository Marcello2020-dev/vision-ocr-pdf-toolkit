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
    @StateObject private var diagnosticsStore = DiagnosticsStore.shared
    @State private var didRunStartupMaintenance = false

    var body: some Scene {
        WindowGroup {
            ContentView()
                .tint(AppTheme.primaryAccent)
                .onAppear {
                    if !didRunStartupMaintenance {
                        didRunStartupMaintenance = true
                        DispatchQueue.global(qos: .utility).async {
                            MergePipelineService.cleanupStaleTemporaryMergeFolders()
                        }
                    }

                    DispatchQueue.main.async {
                        guard let window = NSApplication.shared.windows.first,
                              let screen = window.screen ?? NSScreen.main
                        else { return }

                        // sichtbare Fläche = Desktop ohne Menüleiste/Dock
                        window.setFrame(screen.visibleFrame, display: true)
                        AppTheme.applyWindowChrome(window)
                    }
                }
        }
        .commands {
            DiagnosticsCommands(diagnosticsStore: diagnosticsStore)
        }

        Window("Diagnose-Log", id: DiagnosticsLogView.windowID) {
            DiagnosticsLogView()
                .tint(AppTheme.primaryAccent)
                .buttonStyle(AppActionButtonStyle())
                .background(WindowThemeApplier())
        }
    }
}
