//
//  ToolsView.swift
//  cpdf-merge
//
//  Created by Marcel Mißbach on 28.12.25.
//


import SwiftUI

struct ToolsView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Tools")
                .font(.title2)
            Text("Coming soon: cpdf path, defaults, diagnostics, log export.")
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding()
    }
}