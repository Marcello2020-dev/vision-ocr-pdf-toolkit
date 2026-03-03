// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "vision-ocr-pdf-toolkit-core-tests",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(
            name: "MergePipelineCore",
            targets: ["MergePipelineCore"]
        ),
    ],
    targets: [
        .target(
            name: "MergePipelineCore",
            path: "vision-ocr-pdf-toolkit",
            exclude: [
                "AppTheme.swift",
                "Assets.xcassets",
                "BookmarkTitleBuilder.swift",
                "ContentView.swift",
                "DiagnosticsLogView.swift",
                "DiagnosticsStore.swift",
                "FileDialogHelpers.swift",
                "FileOps.swift",
                "Info.plist",
                "MergeView.swift",
                "OCRView.swift",
                "PDFDropDelegate.swift",
                "PDFMergeService.swift",
                "PDFRedactionService.swift",
                "PageToolsView.swift",
                "RedactionView.swift",
                "URLUtils.swift",
                "UndoActionTarget.swift",
                "VisionOCRService.swift",
                "vision-ocr-pdf-toolkitApp.swift",
            ],
            sources: [
                "PDFKitMerger.swift",
                "PDFKitOutline.swift",
                "MergePipelineService.swift",
            ]
        ),
        .testTarget(
            name: "MergePipelineCoreTests",
            dependencies: ["MergePipelineCore"],
            path: "Tests/MergePipelineCoreTests"
        ),
    ]
)
