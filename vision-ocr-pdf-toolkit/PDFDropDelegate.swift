import SwiftUI
import UniformTypeIdentifiers

// MARK: - Drop Delegate for reordering
struct PDFDropDelegate: DropDelegate {
    let item: URL
    @Binding var items: [URL]
    @Binding var draggedItem: URL?

    func dropEntered(info: DropInfo) {
        guard let dragged = draggedItem, dragged != item else { return }
        guard let fromIndex = items.firstIndex(of: dragged),
              let toIndex = items.firstIndex(of: item) else { return }

        if items[toIndex] != dragged {
            withAnimation {
                items.move(
                    fromOffsets: IndexSet(integer: fromIndex),
                    toOffset: toIndex > fromIndex ? toIndex + 1 : toIndex
                )
            }
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        draggedItem = nil
        return true
    }
}
