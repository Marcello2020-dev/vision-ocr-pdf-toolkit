import SwiftUI

struct ContentView: View {
    var body: some View {
        TabView {
            MergeView()
                .tabItem { Text("Merge") }

            OCRView()
                .tabItem { Text("OCR") }

            ToolsView()
                .tabItem { Text("Tools") }
        }
        .frame(minWidth: 900, minHeight: 600)
        .padding()
    }
}
