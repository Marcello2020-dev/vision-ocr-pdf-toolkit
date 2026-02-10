import SwiftUI

struct ContentView: View {
    var body: some View {
        TabView {
            MergeView()
                .tabItem { Text("PDF zusammenführen") }

            OCRView()
                .tabItem { Text("PDF OCR") }

            PageToolsView()
                .tabItem { Text("PDF-Seiten organisieren") }

            RedactionView()
                .tabItem { Text("PDF Schwärzen") }
        }
        .frame(minWidth: 900, minHeight: 600)
        .padding()
    }
}
