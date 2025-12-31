//
//  OCRMyPDFService.swift
//  cpdf-merge
//
//  Created by Marcel Mißbach on 30.12.25.
//


import Foundation

enum OCRMyPDFService {
    // Du kannst die Reihenfolge gern erweitern, falls du andere Pfade nutzt
    static let candidatePaths: [String] = [
        "/opt/homebrew/bin/ocrmypdf",
        "/usr/local/bin/ocrmypdf",
        "/usr/bin/ocrmypdf"
    ]

    static var defaultPath: String {
        for p in candidatePaths where FileManager.default.isExecutableFile(atPath: p) {
            return p
        }
        // Fallback: wenn nicht gefunden, trotzdem ein Standard (führt dann zu „not executable“ im Check)
        return "/opt/homebrew/bin/ocrmypdf"
    }

    static var isAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: defaultPath)
    }

    static func run(arguments: [String], ocrmypdfPath: String = defaultPath, completion: @escaping (Int32, String, String) -> Void) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: ocrmypdfPath)
        proc.arguments = arguments
        
        // Ensure Homebrew tools (tesseract, gs, etc.) are found when launched from a GUI app
        var env = ProcessInfo.processInfo.environment

        let brewPaths = [
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "/usr/local/sbin"
        ]

        let currentPath = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = (brewPaths + [currentPath]).joined(separator: ":")

        // Optional but helpful for Tesseract language data when installed via Homebrew
        // (doesn't hurt if it doesn't exist)
        env["TESSDATA_PREFIX"] = env["TESSDATA_PREFIX"] ?? "/opt/homebrew/share/tessdata"

        proc.environment = env

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        do {
            try proc.run()
        } catch {
            completion(-1, "", "Failed to start ocrmypdf: \(error)")
            return
        }

        proc.terminationHandler = { p in
            let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let out = String(data: outData, encoding: .utf8) ?? ""
            let err = String(data: errData, encoding: .utf8) ?? ""
            completion(p.terminationStatus, out, err)
        }
    }
}
