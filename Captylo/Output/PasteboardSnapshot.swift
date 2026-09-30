import AppKit

/// Every pasteboard item x every type captured as `Data`, so multi-item and multi-type
/// content (rich text, images, file URLs) comes back exactly after a paste (gotcha 52).
struct PasteboardSnapshot: Sendable, Equatable {
    struct Entry: Sendable, Equatable {
        let type: String
        let data: Data
    }

    /// One inner array per pasteboard item, in the original order.
    let items: [[Entry]]

    init(items: [[Entry]]) {
        self.items = items
    }

    /// Reads every item and type now; lazily promised types are rendered by their source app.
    @MainActor
    init(capturing pasteboard: NSPasteboard) {
        let pasteboardItems = pasteboard.pasteboardItems ?? []
        items = pasteboardItems.map { item in
            item.types.compactMap { type in
                item.data(forType: type).map { Entry(type: type.rawValue, data: $0) }
            }
        }
    }

    var isEmpty: Bool { items.allSatisfy(\.isEmpty) }

    /// Clears the pasteboard and writes the captured items back; an empty snapshot just clears it.
    @MainActor
    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let objects: [NSPasteboardItem] = items.compactMap { entries in
            guard !entries.isEmpty else { return nil }
            let item = NSPasteboardItem()
            for entry in entries {
                item.setData(entry.data, forType: NSPasteboard.PasteboardType(entry.type))
            }
            return item
        }
        guard !objects.isEmpty else { return }
        if !pasteboard.writeObjects(objects) {
            Log.output.error("Clipboard restore failed to write \(objects.count) item(s)")
        }
    }
}
