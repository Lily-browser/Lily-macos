import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The sidebar's tab list in AppKit: the pinned tiles, the regular tabs (a split group as one pill) and the New Tab row,
/// in one `NSTableView`. SwiftUI's `List` took about 20 s to show 5,000 tabs and scrolled at about 10 frames a second, even
/// with plain text rows (#148); a table creates views only for the rows on screen, takes selection and drag and drop
/// natively, and draws the active tab's pill itself, so there is no second system pill to line up with.
///
/// The rows are still the SwiftUI views (`TabRow`, `SplitPill`, `NewTabRow`, the pinned grid), hosted in recycled cells,
/// so they look and behave as before: hover, close button, preview card, context menu, favicons.
struct NativeTabList: NSViewRepresentable {
    let window: WindowModel
    let pinned: [WindowModel.TabItem]
    let items: [WindowModel.ListItem]
    let activeID: UUID?
    let row: SidebarRowStyle
    let accent: String
    let design: Font.Design
    let pinnedColumns: Int

    func makeCoordinator() -> NativeTabListController { NativeTabListController(window: window) }
    func makeNSView(context: Context) -> NSScrollView { context.coordinator.scrollView }
    func updateNSView(_ view: NSScrollView, context: Context) { context.coordinator.update(self) }
}

/// The table, so the self-test can find it among the window's views.
final class TabListTableView: NSTableView {}

/// Scroll view of the tab list. A scroll view can take over a trackpad gesture once it starts, so the window's local
/// monitor never sees the rest of it; the events are handed to the window's space swipe from here too.
final class TabListScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        if let controller = window?.windowController as? BrowserWindowController, controller.handleSpaceSwipe(event) { return }
        super.scrollWheel(with: event)
    }
}

/// A row's selection pill: the list's own shape (`SidebarPill`), in a neutral selection color with the user's accent over it.
final class TabListRowView: NSTableRowView {
    var accent = NSColor.controlAccentColor

    override func drawSelection(in dirtyRect: NSRect) {
        let pill = NSBezierPath(roundedRect: bounds.insetBy(dx: SidebarPill.inset, dy: 0), xRadius: SidebarPill.radius, yRadius: SidebarPill.radius)
        NSColor.unemphasizedSelectedContentBackgroundColor.setFill()
        pill.fill()
        accent.withAlphaComponent(0.22).setFill()
        pill.fill()
    }
}

/// A table cell holding one SwiftUI row, laid out from the cell's real bounds (a new cell starts with none).
final class HostingCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("lily.tabs.cell")
    private let host = NSHostingView(rootView: AnyView(EmptyView()))
    private var insets = NSEdgeInsets()

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.identifier
        host.sizingOptions = [] // the table decides the row's height
        addSubview(host)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ view: AnyView, insets: NSEdgeInsets) {
        self.insets = insets
        host.rootView = view
        needsLayout = true
    }

    override func layout() {
        super.layout()
        host.frame = NSRect(x: insets.left, y: insets.bottom, width: max(0, bounds.width - insets.left - insets.right),
                            height: max(0, bounds.height - insets.top - insets.bottom))
    }
}

@MainActor
final class NativeTabListController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let scrollView = TabListScrollView()
    let table = TabListTableView()
    private let window: WindowModel
    private var props: NativeTabList?
    private var ids: [String] = []
    /// While the table is told which row is active, so its selection callback doesn't activate it again.
    private var syncing = false
    /// The regular-list index of the row being dragged out of this table, nil for drags from elsewhere.
    private var draggedIndex: Int?
    private var dragContents: (sequence: Int, drop: TabDrop?)?

    init(window: WindowModel) {
        self.window = window
        super.init()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("tabs"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.backgroundColor = .clear
        table.intercellSpacing = .zero
        table.gridStyleMask = []
        table.allowsMultipleSelection = false
        table.allowsEmptySelection = true
        table.usesAutomaticRowHeights = false
        table.focusRingType = .none
        table.setAccessibilityLabel("Tabs")
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.registerForDraggedTypes([NSPasteboard.PasteboardType(UTType.lilyTab.identifier), .URL])
        table.setDraggingSourceOperationMask([.move, .copy], forLocal: true)
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        table.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(widthMayHaveChanged), name: NSView.frameDidChangeNotification, object: table)
        scrollView.documentView = table
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
    }

    // MARK: Rows

    /// Rows are: the pinned tiles (when there are any), one per regular item, then New Tab.
    private var pinnedRows: Int { (props?.pinned.isEmpty ?? true) ? 0 : 1 }
    private var items: [WindowModel.ListItem] { props?.items ?? [] }
    private func item(at row: Int) -> WindowModel.ListItem? {
        let index = row - pinnedRows
        return items.indices.contains(index) ? items[index] : nil
    }
    private func isPinnedRow(_ row: Int) -> Bool { pinnedRows == 1 && row == 0 }
    private func isNewTabRow(_ row: Int) -> Bool { row == pinnedRows + items.count }

    private static func ids(for props: NativeTabList) -> [String] {
        (props.pinned.isEmpty ? [] : ["pinned"]) + props.items.map(\.id) + ["new"]
    }

    private static func same(_ a: WindowModel.ListItem, _ b: WindowModel.ListItem) -> Bool {
        switch (a, b) {
        case (.tab(let x), .tab(let y)): return x == y
        case (.split(let lx, let mx), .split(let ly, let my)): return lx == ly && mx == my
        default: return false
        }
    }

    func update(_ new: NativeTabList) {
        let old = props
        props = new
        let newIDs = Self.ids(for: new)
        guard let old else {
            ids = newIDs
            table.reloadData()
            syncSelection(scroll: false)
            return
        }
        let restyled = old.row != new.row || old.accent != new.accent || old.design != new.design || old.pinnedColumns != new.pinnedColumns
        let oldIDs = ids
        ids = newIDs
        if restyled { table.reloadData(); syncSelection(scroll: false); return }
        if oldIDs != newIDs {
            let difference = newIDs.difference(from: oldIDs)
            if difference.count > 200 || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                table.reloadData() // a whole list changing (another space, a restore), or Reduce Motion: no animation
            } else {
                var removed = IndexSet(), inserted = IndexSet()
                for change in difference {
                    switch change {
                    case .remove(let offset, _, _): removed.insert(offset)
                    case .insert(let offset, _, _): inserted.insert(offset)
                    }
                }
                table.beginUpdates()
                table.removeRows(at: removed, withAnimation: .effectFade)
                table.insertRows(at: inserted, withAnimation: .effectFade)
                table.endUpdates()
            }
        }
        refreshChangedRows(from: old, to: new, oldIDs: oldIDs)
        syncSelection(scroll: old.activeID != new.activeID)
    }

    /// Rows that stayed but whose content changed (a title, a favicon, a loading state, the pinned tiles).
    private func refreshChangedRows(from old: NativeTabList, to new: NativeTabList, oldIDs: [String]) {
        var changed = IndexSet()
        if pinnedRows == 1, old.pinned != new.pinned || old.activeID != new.activeID { changed.insert(0) }
        let before = Dictionary(old.items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for (index, item) in new.items.enumerated() {
            if let previous = before[item.id], !Self.same(previous, item) { changed.insert(index + pinnedRows) }
        }
        guard !changed.isEmpty else { return }
        table.noteHeightOfRows(withIndexesChanged: changed)
        table.reloadData(forRowIndexes: changed, columnIndexes: IndexSet(integer: 0))
    }

    private func syncSelection(scroll: Bool) {
        let row = props?.activeID.flatMap { id in items.firstIndex { if case .tab(let t) = $0 { return t.id == id } else { return false } } }.map { $0 + pinnedRows }
        syncing = true
        defer { syncing = false }
        if let row {
            if table.selectedRow != row { table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
            if scroll, !table.rows(in: table.visibleRect).contains(row) { table.scrollRowToVisible(row) }
        } else if table.selectedRow >= 0 {
            table.deselectAll(nil)
        }
    }

    @objc private func widthMayHaveChanged() {
        // The pinned tiles' height depends on the width.
        if pinnedRows == 1 { table.noteHeightOfRows(withIndexesChanged: IndexSet(integer: 0)) }
    }

    // MARK: Data source and delegate

    func numberOfRows(in tableView: NSTableView) -> Int { ids.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let id = NSUserInterfaceItemIdentifier("lily.tabs.row")
        let view = (tableView.makeView(withIdentifier: id, owner: nil) as? TabListRowView) ?? { let new = TabListRowView(); new.identifier = id; return new }()
        view.accent = NSColor(hex: props?.accent ?? AppearanceStyle.defaultAccent)
        return view
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard let props else { return 30 }
        let rowHeight = props.row.rowHeight
        if isPinnedRow(row) {
            return PinnedTabsView.height(count: props.pinned.count, width: max(0, tableView.bounds.width - 16), fixedColumns: props.pinnedColumns) + 10
        }
        if let item = item(at: row), case .split(let layout, let members) = item {
            return Self.splitContentHeight(layout, count: members.count, rowHeight: rowHeight) + 12
        }
        return rowHeight + SidebarPill.rowPadding
    }

    /// What a split pill's cells take: tiles in a row, a stack, or a grid, 3 pt apart, inside 3 pt of padding.
    private static func splitContentHeight(_ layout: SplitLayout, count: Int, rowHeight: CGFloat) -> CGFloat {
        let lines: Int
        switch layout {
        case .twoColumns, .threeColumns: lines = 1
        case .twoRows, .threeRows: lines = max(1, count)
        case .grid: lines = max(1, (count + 1) / 2)
        }
        return CGFloat(lines) * rowHeight + CGFloat(lines - 1) * 3 + 6
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let props else { return nil }
        let cell = (tableView.makeView(withIdentifier: HostingCell.identifier, owner: nil) as? HostingCell) ?? HostingCell(frame: .zero)
        let window = window
        let rowStyle = props.row
        let content: AnyView
        var insets = NSEdgeInsets(top: SidebarPill.rowPadding / 2, left: 16, bottom: SidebarPill.rowPadding / 2, right: 16)
        if isPinnedRow(row) {
            content = AnyView(PinnedTabsGrid(window: window, tabs: props.pinned, activeID: props.activeID, accent: props.accent, columns: props.pinnedColumns))
            insets = NSEdgeInsets(top: 2, left: 8, bottom: 8, right: 8)
        } else if let item = item(at: row) {
            switch item {
            case .tab(let tab):
                content = AnyView(TabRow(tab: tab, window: window, row: rowStyle))
            case .split(let layout, let members):
                content = AnyView(SplitPill(layout: layout, members: members, window: window, row: rowStyle, accent: props.accent))
                insets = NSEdgeInsets(top: 3, left: 6, bottom: 3, right: 6)
            }
        } else {
            content = AnyView(NewTabRow(row: rowStyle) { window.newTab() })
        }
        // The row's identity is its item's: a recycled cell must not carry one tab's hover, close button or preview card
        // (SwiftUI `@State`) over to another.
        cell.show(AnyView(content.id(ids[row]).appAccent().fontDesign(props.design)), insets: insets)
        return cell
    }

    /// Only a tab row can be the selection; clicking it activates the tab. Pinned tiles, split pills and New Tab handle
    /// their own clicks.
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .tab = item(at: row) { return true }
        return false
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !syncing, case .tab(let tab) = item(at: table.selectedRow) else { return }
        if tab.id != window.activeID { window.activate(tab.id) }
    }

    // MARK: Dragging out

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        switch item(at: row) {
        case .tab(let tab): return TabDrag.pasteboardItem(for: tab)
        case .split(_, let members): return members.first.map(TabDrag.pasteboardItem(for:))
        case nil: return nil
        }
    }

    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint, forRowIndexes rowIndexes: IndexSet) {
        draggedIndex = rowIndexes.first.map { $0 - pinnedRows }
    }

    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        draggedIndex = nil
    }

    // MARK: Dropping in

    private func contents(of info: any NSDraggingInfo) -> TabDrop? {
        if let dragContents, dragContents.sequence == info.draggingSequenceNumber { return dragContents.drop }
        let drop = TabDrag.read(info.draggingPasteboard)
        dragContents = (info.draggingSequenceNumber, drop)
        return drop
    }

    func tableView(_ tableView: NSTableView, validateDrop info: any NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        guard let drop = contents(of: info) else { return [] }
        if case .link = drop, drop.webLink == nil { return [] }
        // Between the regular rows only: not among the pinned tiles, not past New Tab.
        tableView.setDropRow(min(max(row, pinnedRows), pinnedRows + items.count), dropOperation: .above)
        if case .tab = drop { return .move }
        return .copy
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: any NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        defer { dragContents = nil }
        let destination = min(max(row - pinnedRows, 0), items.count)
        // A row from this list moves like before (a split group moves as one block); anything else is dropped in.
        if info.draggingSource as? NSTableView === table, let source = draggedIndex, items.indices.contains(source) {
            window.moveItems(from: IndexSet(integer: source), to: destination)
            return true
        }
        guard let drop = contents(of: info) else { return false }
        window.dropInList(drop, atRow: destination)
        return true
    }
}
