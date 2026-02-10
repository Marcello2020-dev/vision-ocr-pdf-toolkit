import SwiftUI

struct ContentView: View {
    var body: some View {
        ZStack {
            AppTheme.windowGradient
                .ignoresSafeArea()

            TabView {
                MergeView()
                    .tabItem { Text("PDF zusammenführen") }

                OCRView()
                    .tabItem { Text("PDF OCR") }

                PageToolsView()
                    .tabItem { Text("PDF Seiten organisieren") }

                RedactionView()
                    .tabItem { Text("PDF Schwärzen") }
            }
        }
        .frame(minWidth: 900, minHeight: 600)
        .tint(AppTheme.primaryAccent)
        .background(WindowThemeApplier())
    }
}
