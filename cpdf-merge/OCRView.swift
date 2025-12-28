import SwiftUI

struct OCRView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("OCR")
                .font(.title2)
            Text("Coming soon: OCR pipeline (Tesseract / ocrmypdf) and PDF post-processing.")
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding()
    }
}