import AppKit

/// The native tab list follows the model: rows appear and disappear with tabs, the active tab is the selected row, and
/// selecting a row activates its tab (#148).
@MainActor
enum TabListProbe {
    static func run(window: BrowserWindowController) async -> (ok: Bool, detail: JSONValue) {
        window.window?.makeKeyAndOrderFront(nil)
        guard let content = window.window?.contentView, let table = DragHarness.list(in: content) else { return (false, "table not found") }
        let model = window.model
        func settle() async { try? await Task.sleep(for: .milliseconds(500)) }
        func rowCount() -> Int { table.numberOfRows }
        func expectedRows() -> Int { (model.pinnedTabs.isEmpty ? 0 : 1) + model.regularItems.count + 1 }
        await settle()
        var detail: [String: JSONValue] = [:]
        let start = rowCount()
        detail["startMatchesModel"] = .bool(start == expectedRows())

        let a = window.tabs.create(url: nil, activate: false), b = window.tabs.create(url: nil, activate: false)
        await settle()
        detail["rowsGrew"] = .bool(rowCount() == start + 2 && rowCount() == expectedRows())

        // Activating a tab selects its row.
        window.tabs.activate(b.id)
        await settle()
        func selectedID() -> UUID? {
            guard table.selectedRow >= 0 else { return nil }
            let index = table.selectedRow - (model.pinnedTabs.isEmpty ? 0 : 1)
            guard model.regularItems.indices.contains(index), case .tab(let tab) = model.regularItems[index] else { return nil }
            return tab.id
        }
        detail["activeIsSelected"] = .bool(selectedID() == b.id)

        // Selecting a row (what a click does) activates its tab.
        if let row = model.regularItems.firstIndex(where: { if case .tab(let t) = $0 { return t.id == a.id } else { return false } }) {
            table.selectRowIndexes(IndexSet(integer: row + (model.pinnedTabs.isEmpty ? 0 : 1)), byExtendingSelection: false)
            await settle()
            detail["selectingActivates"] = .bool(window.tabs.active?.id == a.id)
        } else {
            detail["selectingActivates"] = false
        }

        window.tabs.close(a.id); window.tabs.close(b.id)
        await settle()
        detail["rowsShrank"] = .bool(rowCount() == start && rowCount() == expectedRows())
        let ok = detail.values.allSatisfy { if case .bool(true) = $0 { return true } else { return false } }
        return (ok, .object(detail))
    }
}
