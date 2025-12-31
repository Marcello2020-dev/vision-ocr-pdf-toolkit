//
//  FileDialogHelpers.swift
//  cpdf-merge
//
//  Created by Marcel Mißbach on 28.12.25.
//


import Foundation
import AppKit
import UniformTypeIdentifiers

enum FileDialogHelpers {

    static func choosePDFs(title: String = "PDFs auswählen") -> [URL]? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [UTType.pdf]

        return panel.runModal() == .OK ? panel.urls : nil
    }

    static func chooseFolder(title: String = "Output-Ordner wählen") -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false

        return panel.runModal() == .OK ? panel.url : nil
    }
}
