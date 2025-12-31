//
//  URLUtils.swift
//  cpdf-merge
//
//  Created by Marcel Mißbach on 28.12.25.
//


import Foundation

enum URLUtils {
    static func commonParentFolder(of urls: [URL]) -> URL? {
        guard let first = urls.first else { return nil }
        let folder = first.deletingLastPathComponent().standardizedFileURL

        for u in urls {
            if u.deletingLastPathComponent().standardizedFileURL != folder {
                return nil
            }
        }
        return folder
    }
}