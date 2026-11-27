import SwiftUI

/// The vertical tab sidebar, in SwiftUI.
struct SidebarView: View {
    /// Fills the sidebar's hosting view, so frames measured in it are in the host's coordinates.
    static let coordinateSpace = "Lily.sidebar"
    @Bindable var window: WindowModel
    @AppStorage(AppearanceStyle.Key.showsAddressField) private var showsAddress = true
    @AppStorage(AppearanceStyle.Key.interfaceFont) private var font = InterfaceFont.default.rawValue

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let depth = SpaceSwipe.depth(offset: window.spaceDragOffset, reduceMotion: reduceMotion)
        VStack(spacing: 0) {
            if showsAddress {
                AddressPill(window: window)
                    .padding(.horizontal, 10)
                    .padding(.top, 6)
                    .padding(.bottom, 6)
            }
            switch window.panel {
            case .tabs:
                // The drag offset moves the container, so the outgoing and incoming spaces share it
                // and a committed swipe continues from where the fingers left the list.
                ZStack {
                    VStack(spacing: 0) {
                        if !window.isPrivate, let space = window.currentSpace { SpaceHeader(space: space, window: window) }
                        TabListView(window: window)
                    }
                    .id(window.currentSpaceID)
                    // The next space slides in from its side and settles up from slightly back; with Reduce Motion it fades.
                    .transition(reduceMotion ? .opacity : .push(from: window.spaceForward ? .trailing : .leading).combined(with: .scale(scale: 0.95)))
                }
                // Depth: while dragging, the list recedes (smaller, tilted away), pivoting on the edge it moves toward.
                .scaleEffect(depth.scale, anchor: depth.anchor)
                .rotation3DEffect(.degrees(depth.tilt), axis: (x: 0, y: 1, z: 0), anchor: depth.anchor, perspective: 0.5)
                .opacity(depth.opacity)
                .offset(x: window.spaceDragOffset)
                .clipped()
                .transition(.move(edge: .leading).combined(with: .opacity))
            case .assistant:
                AssistantPanelView(chat: window.assistant, window: window)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            case .history:
                HistoryPanelView(window: window)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
            SidebarFooter(window: window)
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
        }
        .animation(.smooth(duration: 0.25), value: window.panel)
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.35, dampingFraction: 0.86), value: window.currentSpaceID)
        .background {
            if window.isPrivate { SidebarBackground(spaceColor: nil) }
            else { SpaceWash(from: window.washFrom, to: window.washTo, progress: window.spaceDragProgress) }
        }
        .appAccent()
        .overlay(alignment: .bottom) {
            if let toast = window.toast {
                HStack(spacing: 10) {
                    Text(toast.message)
                    if let action = toast.action {
                        Button(action.title) {
                            window.toast = nil
                            action.run()
                        }
                        .buttonStyle(.borderless).fontWeight(.semibold)
                    }
                }
                    .font(.callout)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(.regularMaterial, in: Capsule())
                    .shadow(radius: 8, y: 3)
                    .padding(.bottom, 52)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .id(toast.id)
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: window.toast)
        .fontDesign(InterfaceFont(stored: font).design)
        .coordinateSpace(name: Self.coordinateSpace)
    }
}

struct NavButton: View {
    let symbol: String
    let help: String
    var enabled = true
    var width: CGFloat = 30
    var height: CGFloat = 28
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: width, height: height)
                .background(hovering && enabled ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear),
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                // The whole frame takes clicks, not only the glyph's pixels.
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? .secondary : .tertiary)
        .disabled(!enabled)
        .help(help)
        .onHover { hovering = $0 }
    }
}

/// Shows the active page's address; clicking it opens the command bar on that URL (⌘L).
private struct AddressPill: View {
    let window: WindowModel
    @AppStorage(AppearanceStyle.Key.sidebarTextSize) private var textSize = SidebarTextSize.default.rawValue
    @State private var hovering = false
    @State private var security: IdentifiedSecurity?

    var body: some View {
        let url = window.activeTab?.url
        HStack(spacing: 7) {
            // The lock is its own button: it shows the site's security details.
            Button { showSecurity() } label: {
                Image(systemName: lockSymbol(url))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(url?.scheme == "http" ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .frame(width: 18, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(url == nil)
            .help("Connection and site information")
            .popover(item: $security) { item in
                SiteSecurityView(security: item.value, window: window)
            }
            Button { window.presentCommandBar(newTab: false) } label: {
                HStack(spacing: 7) {
                    Text(display(url)).lineLimit(1).truncationMode(.middle).font(.system(size: SidebarTextSize(stored: textSize).titleSize))
                        .foregroundStyle(url == nil ? .tertiary : .primary)
                    Spacer(minLength: 0)
                    if window.isPrivate {
                        Label("Private", systemImage: "eyeglasses").labelStyle(.iconOnly).foregroundStyle(.secondary).help("Private window")
                    }
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open Location (⌘L)")
        }
        .padding(.horizontal, 10)
        .frame(height: SidebarTextSize(stored: textSize).rowHeight + 6)
        .background(.quaternary.opacity(hovering ? 1.0 : 0.6), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .onHover { hovering = $0 }
    }

    private func lockSymbol(_ url: URL?) -> String {
        guard let url else { return "magnifyingglass" }
        if window.controller?.tabs.active?.showsErrorPage == true { return "exclamationmark.triangle" }
        if url.scheme == "https" { return window.controller?.tabs.active?.webView.hasOnlySecureContent == false ? "lock.trianglebadge.exclamationmark" : "lock.fill" }
        return url.isFileURL ? "doc" : "exclamationmark.triangle"
    }

    private func showSecurity() {
        guard let web = window.controller?.tabs.active?.webView, let url = web.url else { return }
        security = IdentifiedSecurity(value: SiteSecurity(webView: web, url: url, isErrorPage: window.controller?.tabs.active?.showsErrorPage == true))
    }

    private func display(_ url: URL?) -> String {
        guard let url else { return "Search or enter address" }
        guard let host = url.host, url.scheme?.hasPrefix("http") == true else { return url.absoluteString }
        let path = url.path == "/" ? "" : url.path
        return host.replacingOccurrences(of: "www.", with: "", options: .anchored) + path
    }
}

/// Pinned tabs as rounded tiles, then the regular tabs, where a split group shows as one pill
/// laid out like the split itself.
private struct TabListView: View {
    @Bindable var window: WindowModel
    @AppStorage(AppearanceStyle.Key.accent) private var accent = AppearanceStyle.defaultAccent
    /// Read once here and handed to the rows as a plain value: thousands of rows don't each observe them.
    @AppStorage(AppearanceStyle.Key.sidebarTextSize) private var storedTextSize = SidebarTextSize.default.rawValue
    @AppStorage(AppearanceStyle.Key.tabDensity) private var density = TabDensity.default.rawValue
    @AppStorage(AppearanceStyle.Key.closeButton) private var closeButton = CloseButtonVisibility.default.rawValue
    @AppStorage(AppearanceStyle.Key.dimSleepingTabs) private var dimSleeping = true
    @AppStorage(AppearanceStyle.Key.pinnedColumns) private var pinnedColumns = PinnedColumns.automatic
    @AppStorage(AppearanceStyle.Key.interfaceFont) private var font = InterfaceFont.default.rawValue

    var body: some View {
        let row = SidebarRowStyle(textSize: SidebarTextSize(stored: storedTextSize), density: TabDensity(stored: density),
                                       closeButton: CloseButtonVisibility(stored: closeButton), dimsSleepingTabs: dimSleeping)
        NativeTabList(window: window, pinned: window.pinnedTabs, items: window.regularItems, activeID: window.activeID, row: row,
                      accent: accent, design: InterfaceFont(stored: font).design, pinnedColumns: PinnedColumns.clamped(pinnedColumns))
    }
}

/// A split group: one rounded pill holding its tabs arranged like the split (side by side, stacked,
/// three columns/rows, or a 2×2 grid). Clicking a tab focuses it in the split.
struct SplitPill: View {
    let layout: SplitLayout
    let members: [WindowModel.TabItem]
    let window: WindowModel
    let row: SidebarRowStyle
    let accent: String
    @State private var dropTargeted = false

    var body: some View {
        let isActive = members.contains { $0.id == window.activeID }
        Group {
            switch layout {
            case .twoColumns, .threeColumns:
                HStack(spacing: 3) { cells(members, compact: layout == .threeColumns) }
            case .twoRows, .threeRows:
                VStack(spacing: 3) { cells(members, compact: false) }
            case .grid:
                Grid(horizontalSpacing: 3, verticalSpacing: 3) {
                    GridRow { cells(Array(members.prefix(2)), compact: true) }
                    GridRow { cells(Array(members.dropFirst(2)), compact: true) }
                }
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(isActive ? AnyShapeStyle(Color(hex: accent).opacity(0.12)) : AnyShapeStyle(.quaternary.opacity(0.5))))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(dropTargeted ? Color.accentColor : isActive ? Color(hex: accent).opacity(0.45) : .clear, lineWidth: dropTargeted ? 2 : 1))
        // A tab dropped here joins the split (while there's room for another pane).
        .tabDropTarget($dropTargeted) { drop in members.first.map { window.dropOnSplit(drop, joining: $0.id) } ?? false }
        .overlay(alignment: .topTrailing) {
            Image(systemName: layout.symbol).font(.system(size: 8, weight: .semibold)).foregroundStyle(.tertiary).padding(4)
        }
        .help(layout.title)
    }

    @ViewBuilder
    private func cells(_ tabs: [WindowModel.TabItem], compact: Bool) -> some View {
        ForEach(tabs) { tab in
            let focused = tab.id == window.activeID
            HStack(spacing: 5) {
                FaviconView(page: tab.url, fetch: tab.isSleeping ? nil : tab.favicon ?? tab.url?.faviconGuess, remember: !window.isPrivate && !window.isSensitive(tab.url),
                            size: row.favicon - 2)
                if !compact { Text(tab.title).font(.system(size: row.titleSize - 1)).lineLimit(1).truncationMode(.tail) }
            }
            .frame(maxWidth: .infinity, alignment: compact ? .center : .leading)
            .padding(.horizontal, 7).frame(height: row.rowHeight)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(focused ? AnyShapeStyle(Color(hex: accent).opacity(0.3)) : AnyShapeStyle(.background.opacity(0.35))))
            .contentShape(Rectangle())
            .onTapGesture { window.activate(tab.id) }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(focused ? [.isButton, .isSelected] : .isButton)
            .help(tab.title)
            .contextMenu { TabContextMenu(tab: tab, window: window) }
        }
    }
}

struct TabRow: View {
    let tab: WindowModel.TabItem
    let window: WindowModel
    let row: SidebarRowStyle
    @State private var hovering = false
    @State private var preview: WindowModel.TabPreview?
    /// Settings → Appearance → Dim sleeping tabs.
    private var dimmed: Bool { tab.isSleeping && row.dimsSleepingTabs }

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                // A sleeping or restored tab's site isn't open: its kept icon only, no request.
                FaviconView(page: tab.url, fetch: tab.isSleeping ? nil : tab.favicon ?? tab.url?.faviconGuess, remember: !window.isPrivate && !window.isSensitive(tab.url), size: row.favicon)
                    .opacity(dimmed ? 0.45 : 1)
                    .saturation(dimmed ? 0 : 1)
                if tab.isLoading { ProgressView().controlSize(.mini).scaleEffect(0.8) }
            }
            .frame(width: row.favicon + 2)
            Text(tab.title).font(.system(size: row.titleSize)).lineLimit(1).truncationMode(.tail)
                .foregroundStyle(dimmed ? .secondary : .primary)
                .help(tab.isSleeping ? "Sleeping to save memory. Opens where you left off." : tab.title)
            Spacer(minLength: 0)
            if tab.inSplit {
                Image(systemName: "rectangle.split.2x1").font(.system(size: 10)).foregroundStyle(.tint).help("In Split View").accessibilityLabel("In Split View")
            }
            if row.closeButton.shows(hovering: hovering) && !tab.isPinned {
                Button { window.close(tab.id) } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }
                    .accessibilityLabel("Close Tab")
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Close Tab (⌘W)")
            }
        }
        .frame(height: row.rowHeight)
        .contentShape(Rectangle())
        // No tap gesture here: a gesture that handles the mouse-down stops the list from starting a drag, so a
        // click selects the row (the list's selection activates the tab) and the drag keeps working.
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(window.activeID == tab.id ? [.isButton, .isSelected] : .isButton)
        .onHover { hovering = $0 }
        // One sleep, cancelled when the pointer leaves: no timer runs unless a row is hovered.
        .task(id: hovering) {
            guard hovering else { preview = nil; return }
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled { preview = window.preview(tab.id) }
        }
        // A small floating card over the row's right edge; it never takes clicks.
        .overlay(alignment: .trailing) {
            if let preview { TabPreviewView(info: preview).padding(.trailing, 4).allowsHitTesting(false).transition(.opacity) }
        }
        .zIndex(preview == nil ? 0 : 1)
        .contextMenu { TabContextMenu(tab: tab, window: window) }
    }
}

/// Hover preview: the tab's state and the memory its web process really uses.
private struct TabPreviewView: View {
    let info: WindowModel.TabPreview

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: info.isActive ? "bolt.fill" : "moon.zzz").foregroundStyle(info.isActive ? Color.accentColor : .secondary)
            Text(info.isActive ? "Active" : "Inactive")
            Text("·").foregroundStyle(.tertiary)
            Text(memoryText).monospacedDigit()
        }
        .font(.system(size: 11, weight: .medium))
        .fixedSize()
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.separator))
        .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
    }

    private var memoryText: String {
        if let bytes = info.memory { return TabMemory.format(bytes) }
        return info.isSleeping ? "0 MB" : "n/a"
    }
}

/// The "New Tab" row at the end of the list: the whole row is the button, not just its glyph and text.
struct NewTabRow: View {
    let row: SidebarRowStyle
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "plus")
                    .font(.system(size: row.titleSize - 2, weight: .semibold))
                    .frame(width: row.favicon + 2)
                Text("New Tab").font(.system(size: row.titleSize))
                Spacer(minLength: 0)
            }
            .foregroundStyle(.secondary)
            .frame(height: row.rowHeight)
            // Drawn past the content (which the list insets 16 pt) to the same inset and radius as the active tab's pill.
            .background {
                RoundedRectangle(cornerRadius: SidebarPill.radius, style: .continuous)
                    .fill(hovering ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear))
                    .padding(.horizontal, SidebarPill.inset - 16)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("New Tab (⌘T)")
        .onHover { hovering = $0 }
    }
}

/// The shape of a sidebar row's pill (the list's own selection pill, measured on macOS 27 from a render). The self-test
/// ("active tab is one pill") fails if a macOS release changes it and a differently colored strip shows.
enum SidebarPill {
    static let inset: CGFloat = 10
    static let radius: CGFloat = 6
    /// What a row adds above and below its content (the list's measured row pitch minus the row height).
    static let rowPadding: CGFloat = 7.5
}

/// Right-click menu for a tab.
private struct SidebarFooter: View {
    @Bindable var window: WindowModel
    // Settings → Appearance → Sidebar footer; the space switcher always shows.
    @AppStorage(AppearanceStyle.Key.footerAssistant) private var showsAssistant = true
    @AppStorage(AppearanceStyle.Key.footerHistory) private var showsHistory = true
    @AppStorage(AppearanceStyle.Key.footerDownloads) private var showsDownloads = true
    @AppStorage(AppearanceStyle.Key.footerNewTab) private var showsNewTab = true

    var body: some View {
        HStack(spacing: 2) {
            if showsAssistant { assistantButton }
            if !window.isPrivate { SpaceSwitcher(window: window).frame(maxWidth: .infinity) } else { Spacer() }
            if showsHistory, window.controller?.history != nil {
                NavButton(symbol: "clock", help: "History") { window.panel = window.panel == .history ? .tabs : .history }
                    .foregroundStyle(window.panel == .history ? .primary : .secondary)
            }
            if showsDownloads { DownloadsButton(downloads: DownloadManager.shared, window: window) }
            if window.canReopenClosed {
                NavButton(symbol: "arrow.uturn.backward", help: "Reopen Closed Tab (⇧⌘T)") { window.reopenClosed() }
            }
            if showsNewTab { NavButton(symbol: "plus", help: "New Tab (⌘T)", width: 32, height: 30) { window.newTab() } }
        }
    }

    private var assistantButton: some View {
        Button { window.showsAssistant.toggle() } label: {
            Image(systemName: "sparkles")
                .font(.system(size: 12, weight: .medium))
                .frame(width: 30)
                .padding(.horizontal, 8).frame(height: 28)
                .background(window.showsAssistant ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear),
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .foregroundStyle(window.showsAssistant ? .primary : .secondary)
        .help("Assistant (⌘E)")
    }
}

// MARK: - Spaces

/// The current space's name above its tabs, with a menu to rename, restyle or delete it.
private struct SpaceHeader: View {
    let space: Space
    let window: WindowModel
    @AppStorage(AppearanceStyle.Key.sidebarTextSize) private var textSize = SidebarTextSize.default.rawValue
    @State private var editing = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: space.symbol).foregroundStyle(Color(hex: space.color)).font(.system(size: 11, weight: .semibold))
            Text(space.name).font(.system(size: SidebarTextSize(stored: textSize).headerSize, weight: .semibold)).foregroundStyle(.secondary)
            if space.hasSeparateLogins {
                Image(systemName: "person.badge.key.fill").font(.system(size: 10)).foregroundStyle(.secondary)
                    .help("Separate logins: this space has its own cookies and site data")
            }
            Spacer()
            Menu {
                Button { editing = true } label: { Label("Edit Space…", systemImage: "pencil") }
                Button(role: .destructive) { window.deleteSpace(space.id) } label: { Label("Delete Space and Its Tabs", systemImage: "trash") }
                    .disabled(window.spaces.count < 2)
            } label: { Image(systemName: "ellipsis") }
                .accessibilityLabel("Space Options")
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        }
        .padding(.horizontal, 16).padding(.vertical, 4)
        .popover(isPresented: $editing) {
            SpaceEditor(space: space, title: "Edit Space", allowsSeparateLogins: !window.isPrivate) { window.updateSpace($0) }
        }
    }
}

/// Space icons in the footer; click to switch, + to add. Two-finger swipes on the sidebar also switch.
private struct SpaceSwitcher: View {
    let window: WindowModel
    @State private var adding = false

    var body: some View {
        HStack(spacing: 4) {
            ForEach(window.spaces) { space in SpaceSwitcherButton(space: space, window: window) }
            Button { adding = true } label: {
                Image(systemName: "plus").font(.system(size: 10, weight: .bold)).frame(width: 20, height: 20).contentShape(Circle())
            }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("New Space")
                .popover(isPresented: $adding) {
                    SpaceEditor(space: Space(name: "", symbol: Space.symbols.randomElement() ?? "circle.fill",
                                             color: AppearanceStyle.presets.randomElement() ?? AppearanceStyle.defaultAccent),
                                title: "New Space", allowsSeparateLogins: !window.isPrivate) { window.addSpace($0) }
                }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: window.currentSpaceID)
    }
}

/// One space in the footer switcher. A tab dropped on it moves to that space; a link opens there.
private struct SpaceSwitcherButton: View {
    let space: Space
    let window: WindowModel
    @State private var dropTargeted = false

    var body: some View {
        let current = space.id == window.currentSpaceID
        Button { window.switchSpace(to: space.id) } label: {
            Image(systemName: space.symbol)
                .font(.system(size: current || dropTargeted ? 12 : 9, weight: .semibold))
                .foregroundStyle(current || dropTargeted ? Color(hex: space.color) : .secondary)
                .frame(width: 20, height: 20)
                .background(current || dropTargeted ? Color(hex: space.color).opacity(dropTargeted ? 0.35 : 0.18) : .clear, in: Circle())
                .scaleEffect(dropTargeted ? 1.2 : 1)
                .animation(.spring(response: 0.25, dampingFraction: 0.7), value: dropTargeted)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(space.name)
        .tabDropTarget($dropTargeted) { window.dropOnSpace($0, space: space.id) }
        .contextMenu {
            Button(role: .destructive) { window.deleteSpace(space.id) } label: { Label("Delete Space", systemImage: "trash") }
                .disabled(window.spaces.count < 2)
        }
    }
}

private struct SpaceEditor: View {
    @State var space: Space
    let title: String
    /// Private windows already keep everything apart, in one throwaway store.
    let allowsSeparateLogins: Bool
    let save: (Space) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            TextField("Name", text: $space.name).textFieldStyle(.roundedBorder).onSubmit(commit)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(28)), count: 6), spacing: 6) {
                ForEach(Space.symbols, id: \.self) { symbol in
                    Image(systemName: symbol)
                        .frame(width: 28, height: 28)
                        .background(space.symbol == symbol ? Color(hex: space.color).opacity(0.25) : .clear, in: RoundedRectangle(cornerRadius: 6))
                        .onTapGesture { space.symbol = symbol }
                }
            }
            HStack(spacing: 8) {
                ForEach(AppearanceStyle.presets, id: \.self) { hex in
                    Circle().fill(Color(hex: hex)).frame(width: 18, height: 18)
                        .overlay(Circle().strokeBorder(.primary.opacity(space.color == hex ? 0.8 : 0), lineWidth: 2).padding(-3))
                        .onTapGesture { space.color = hex }
                }
            }
            if allowsSeparateLogins {
                Toggle(isOn: Binding(get: { space.hasSeparateLogins }, set: { space.separateLogins = $0 })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Separate logins")
                        Text("Its own cookies and site data, so you can use other accounts here. Open tabs in this space reload.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.switch).controlSize(.small)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save", action: commit).keyboardShortcut(.defaultAction)
            }
        }
        .padding(16).frame(width: 260)
    }

    private func commit() {
        save(space)
        dismiss()
    }
}

/// `.popover(item:)` needs Identifiable; the details are rebuilt each time the lock is clicked.
private struct IdentifiedSecurity: Identifiable {
    let id = UUID()
    let value: SiteSecurity
}
