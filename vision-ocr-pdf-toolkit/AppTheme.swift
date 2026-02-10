import SwiftUI

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
}
