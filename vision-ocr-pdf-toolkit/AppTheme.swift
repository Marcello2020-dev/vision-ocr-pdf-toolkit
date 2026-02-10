import SwiftUI
import AppKit

enum AppTheme {
    static let primaryAccent = Color("AccentColor")
    static let secondaryAccent = Color("SecondaryAccent")

    static let windowGradient = LinearGradient(
        colors: [
            primaryAccent.opacity(0.10),
            secondaryAccent.opacity(0.12),
            primaryAccent.opacity(0.06)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let panelGradient = LinearGradient(
        colors: [
            primaryAccent.opacity(0.12),
            secondaryAccent.opacity(0.16),
            primaryAccent.opacity(0.10)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let pdfCanvasBackground = NSColor(
        red: 0.09,
        green: 0.27,
        blue: 0.42,
        alpha: 0.22
    )

    static func applyWindowChrome(_ window: NSWindow) {
        let tintColor = NSColor(
            red: 0.09,
            green: 0.33,
            blue: 0.52,
            alpha: 1.0
        )
        let baseColor = NSColor.windowBackgroundColor
        window.backgroundColor = baseColor.blended(withFraction: 0.22, of: tintColor) ?? baseColor
        window.isOpaque = true
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
    }
}

struct WindowThemeApplier: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = nsView.window else { return }
            AppTheme.applyWindowChrome(window)
        }
    }
}
