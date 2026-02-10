import SwiftUI
import AppKit

struct DiagnosticsLogView: View {
    static let windowID = "diagnostics-log"

    @ObservedObject private var diagnosticsStore = DiagnosticsStore.shared

    private var hasLog: Bool {
        !diagnosticsStore.mergeLog.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Diagnose-Log")
                    .font(.headline)

                Spacer()

                Button("Kopieren") { copyLogToPasteboard() }
                    .disabled(!hasLog)

                Button("Leeren") { diagnosticsStore.clearMergeLog() }
                    .disabled(!hasLog)
            }

            ScrollView {
                Text(hasLog ? diagnosticsStore.mergeLog : "Kein Diagnose-Log vorhanden.")
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 6))
        }
        .padding(14)
        .frame(minWidth: 760, minHeight: 420)
        .background(AppTheme.panelGradient.ignoresSafeArea())
    }

    private func copyLogToPasteboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(diagnosticsStore.mergeLog, forType: .string)
    }
}

struct DiagnosticsCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var diagnosticsStore: DiagnosticsStore

    private var hasLog: Bool {
        !diagnosticsStore.mergeLog.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some Commands {
        CommandMenu("Diagnose") {
            Button("Diagnose-Log anzeigen") {
                openWindow(id: DiagnosticsLogView.windowID)
            }
            .keyboardShortcut("d", modifiers: [.command, .option])

            Button("Diagnose-Log leeren") {
                diagnosticsStore.clearMergeLog()
            }
            .disabled(!hasLog)
        }
    }
}
