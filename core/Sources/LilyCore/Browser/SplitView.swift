import AppKit
import LilyKit
import WebKit

/// `SplitLayout` and `SplitGroup` are LilyKit's (shared with Lily-ios); the Mac adds how a layout is named and drawn.
extension SplitLayout {
    var title: String {
        switch self {
        case .twoColumns: return "Two Side by Side"
        case .twoRows: return "Two Stacked"
        case .threeColumns: return "Three Columns"
        case .threeRows: return "Three Rows"
        case .grid: return "Four in a Grid"
        }
    }

    var symbol: String {
        switch self {
        case .twoColumns: return "rectangle.split.2x1"
        case .twoRows: return "rectangle.split.1x2"
        case .threeColumns: return "rectangle.split.3x1"
        case .threeRows: return "rectangle.split.1x3"
        case .grid: return "rectangle.split.2x2"
        }
    }
}

/// Right-hand pane: the active tab, or the active split group, as rounded cards. Clicking a pane
/// focuses its tab; the focused pane wears the accent color.
@MainActor
final class TabContentViewController: NSViewController {
    private let container = NSView()
    /// Where the Find bar (⌘F) sits, above the panes; zero height while it's hidden.
    private let findSlot = NSView()
    private lazy var findHeight = findSlot.heightAnchor.constraint(equalToConstant: 0)
    private let emptyLabel = NSTextField(labelWithString: "Press ⌘T to open a tab")
    private var panes: [PaneView] = []
    private var shown: (layout: SplitLayout?, ids: [UUID]) = (nil, [])
    private var clickMonitor: Any?
    /// Settings → Appearance → Page: corner radius and the margin around the panes.
    private(set) var pageStyle = PageStyle.current()
    private var edgeConstraints: (leading: [NSLayoutConstraint], trailing: [NSLayoutConstraint], bottom: NSLayoutConstraint)?
    /// Called when the user clicks into a pane that isn't the active tab.
    var onFocus: (@MainActor (UUID) -> Void)?
    /// Called when a paused pane is scrolled, which resumes it without focusing it.
    var onResume: (@MainActor (UUID) -> Void)?

    override func loadView() {
        let root = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        findSlot.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(findSlot)
        root.addSubview(container)
        let leading = [findSlot.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                       container.leadingAnchor.constraint(equalTo: root.leadingAnchor)]
        let trailing = [root.trailingAnchor.constraint(equalTo: findSlot.trailingAnchor),
                        root.trailingAnchor.constraint(equalTo: container.trailingAnchor)]
        let bottom = root.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        edgeConstraints = (leading, trailing, bottom)
        NSLayoutConstraint.activate(leading + trailing + [
            findSlot.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            findHeight,
            container.topAnchor.constraint(equalTo: findSlot.bottomAnchor),
            bottom,
        ])
        applyEdges()
        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            emptyLabel.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: root.centerYAnchor),
        ])
        view = root
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        guard clickMonitor == nil else { return }
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            MainActor.assumeIsolated { self?.focusPane(at: event) }
            return event
        }
    }

    /// Settings → Appearance → Page changed (or the sidebar moved sides): live, no rebuild.
    func apply(_ style: PageStyle) {
        guard style != pageStyle else { return }
        pageStyle = style
        guard isViewLoaded else { return }
        applyEdges()
        panes.forEach { $0.cornerRadius = style.cornerRadius }
    }

    private func applyEdges() {
        guard let edgeConstraints else { return }
        edgeConstraints.leading.forEach { $0.constant = pageStyle.leading }
        edgeConstraints.trailing.forEach { $0.constant = pageStyle.trailing }
        edgeConstraints.bottom.constant = pageStyle.padding
    }

    func tearDown() {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
    }

    /// Shows `active` alone, or its split group when it belongs to one.
    func display(active: Tab?, split: SplitGroup?, lookup: (UUID) -> Tab?) {
        _ = view
        emptyLabel.isHidden = active != nil
        guard let active else { rebuild(layout: nil, tabs: []); return }
        if let split, split.tabIDs.contains(active.id) {
            let tabs = split.tabIDs.compactMap(lookup)
            if shown.layout != split.layout || shown.ids != tabs.map(\.id) { rebuild(layout: split.layout, tabs: tabs) }
        } else if shown.layout != nil || shown.ids != [active.id] {
            rebuild(layout: nil, tabs: [active])
        }
        panes.forEach { $0.isFocused = panes.count > 1 && $0.tabID == active.id }
        // The pane you're in always runs.
        panes.first { $0.tabID == active.id }?.thaw()
    }

    // MARK: Find bar (⌘F)

    /// Shows `bar` above the panes, or removes it (nil).
    func setFindBar(_ bar: NSView?) {
        _ = view
        findSlot.subviews.forEach { $0.removeFromSuperview() }
        guard let bar else { findHeight.constant = 0; return }
        bar.translatesAutoresizingMaskIntoConstraints = false
        findSlot.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: findSlot.leadingAnchor), bar.trailingAnchor.constraint(equalTo: findSlot.trailingAnchor),
            bar.topAnchor.constraint(equalTo: findSlot.topAnchor), bar.bottomAnchor.constraint(equalTo: findSlot.bottomAnchor),
        ])
        findHeight.constant = FindBarView.height
    }

    var isFindBarShown: Bool { !findSlot.subviews.isEmpty }

    // MARK: Pausing idle panes (PaneFreezer)

    func isFrozen(_ id: UUID) -> Bool { panes.first { $0.tabID == id }?.isFrozen ?? false }

    /// Covers an unfocused pane with `snapshot` and hides its web view, which WebKit then treats
    /// as not visible: its timers, animation frames and rendering are suspended
    /// (`inactiveSchedulingPolicy = .suspend`).
    func freeze(_ id: UUID, snapshot: NSImage) {
        guard panes.count > 1, let pane = panes.first(where: { $0.tabID == id }), !pane.isFocused else { return }
        pane.freeze(snapshot)
    }

    func thawAll() { panes.forEach { $0.thaw() } }

    /// The tab's web view was replaced: its pane is rebuilt on the next `display`.
    func webViewReplaced(_ id: UUID) {
        if shown.ids.contains(id) { shown = (shown.layout, []) }
    }

    private func rebuild(layout: SplitLayout?, tabs: [Tab]) {
        container.subviews.forEach { $0.removeFromSuperview() }
        panes.forEach { $0.thaw() }
        panes = tabs.map { tab in PaneView(tab: tab, cornerRadius: pageStyle.cornerRadius) { [weak self] in self?.onResume?(tab.id) } }
        shown = (layout, tabs.map(\.id))
        guard !panes.isEmpty else { return }
        let content: NSView
        switch layout {
        case nil: content = panes[0]
        case .twoColumns, .threeColumns: content = Self.split(panes, vertical: true)
        case .twoRows, .threeRows: content = Self.split(panes, vertical: false)
        case .grid:
            content = Self.split([Self.split(Array(panes.prefix(2)), vertical: true),
                                  Self.split(Array(panes.dropFirst(2)), vertical: true)], vertical: false)
        }
        content.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            content.topAnchor.constraint(equalTo: container.topAnchor),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        if layout != nil {
            Haptics.step()
            content.alphaValue = 0
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                content.animator().alphaValue = 1
            }
        }
    }

    private static func split(_ views: [NSView], vertical: Bool) -> NSSplitView {
        let split = EvenSplitView()
        split.isVertical = vertical
        split.dividerStyle = .thin
        views.forEach(split.addArrangedSubview)
        return split
    }

    private func focusPane(at event: NSEvent) {
        guard panes.count > 1, event.window === view.window,
              let pane = panes.first(where: { $0.bounds.contains($0.convert(event.locationInWindow, from: nil)) }),
              !pane.isFocused else { return }
        onFocus?(pane.tabID)
    }
}

/// Splits its space evenly the first time it is laid out; the user can then drag the dividers.
private final class EvenSplitView: NSSplitView {
    private var distributed = false

    override func layout() {
        super.layout()
        guard !distributed, arrangedSubviews.count > 1 else { return }
        let total = (isVertical ? bounds.width : bounds.height) - dividerThickness * CGFloat(arrangedSubviews.count - 1)
        guard total > 0 else { return }
        distributed = true
        let share = total / CGFloat(arrangedSubviews.count)
        for index in 0..<(arrangedSubviews.count - 1) {
            setPosition(share * CGFloat(index + 1) + dividerThickness * CGFloat(index), ofDividerAt: index)
        }
    }
}

/// One rounded card holding a tab's web view, or a still picture of it while it's paused.
private final class PaneView: NSView {
    let tabID: UUID
    var isFocused = false { didSet { updateBorder() } }
    var cornerRadius: CGFloat {
        get { layer?.cornerRadius ?? 0 }
        set { layer?.cornerRadius = newValue }
    }
    private weak var web: NSView?
    private var cover: FrozenPaneView?
    private let resumed: () -> Void
    var isFrozen: Bool { cover != nil }

    init(tab: Tab, cornerRadius: CGFloat, resumed: @escaping () -> Void) {
        tabID = tab.id
        self.resumed = resumed
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = cornerRadius
        layer?.masksToBounds = true
        let web = tab.webView
        web.removeFromSuperview()
        web.isHidden = false
        web.translatesAutoresizingMaskIntoConstraints = false
        addSubview(web)
        self.web = web
        NSLayoutConstraint.activate([
            web.leadingAnchor.constraint(equalTo: leadingAnchor),
            web.trailingAnchor.constraint(equalTo: trailingAnchor),
            web.topAnchor.constraint(equalTo: topAnchor),
            web.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        updateBorder()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func freeze(_ snapshot: NSImage) {
        guard cover == nil, let web else { return }
        let cover = FrozenPaneView(snapshot: snapshot) { [weak self] in
            self?.thaw()
            self?.resumed()
        }
        cover.translatesAutoresizingMaskIntoConstraints = false
        addSubview(cover, positioned: .above, relativeTo: web)
        NSLayoutConstraint.activate([
            cover.leadingAnchor.constraint(equalTo: leadingAnchor),
            cover.trailingAnchor.constraint(equalTo: trailingAnchor),
            cover.topAnchor.constraint(equalTo: topAnchor),
            cover.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        self.cover = cover
        web.isHidden = true
    }

    func thaw() {
        guard let cover else { return }
        web?.isHidden = false
        cover.removeFromSuperview()
        self.cover = nil
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBorder()
    }

    private func updateBorder() {
        let accent = NSColor(hex: UserDefaults.standard.string(forKey: AppearanceStyle.Key.accent) ?? AppearanceStyle.defaultAccent)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.borderWidth = isFocused ? 2 : 0.5
            layer?.borderColor = (isFocused ? accent : NSColor.separatorColor).cgColor
        }
    }
}

/// A paused pane: its last picture and a "Paused" badge. Scrolling it resumes the page (a click
/// focuses the pane, which resumes it too).
private final class FrozenPaneView: NSView {
    private let resume: () -> Void

    init(snapshot: NSImage, resume: @escaping () -> Void) {
        self.resume = resume
        super.init(frame: .zero)
        let picture = NSImageView(image: snapshot)
        picture.imageScaling = .scaleAxesIndependently
        picture.translatesAutoresizingMaskIntoConstraints = false
        addSubview(picture)
        let badge = NSVisualEffectView()
        badge.material = .hudWindow
        badge.state = .active
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 11
        badge.translatesAutoresizingMaskIntoConstraints = false
        let label = NSTextField(labelWithString: "Paused to save energy · click to resume")
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        badge.addSubview(label)
        addSubview(badge)
        NSLayoutConstraint.activate([
            picture.leadingAnchor.constraint(equalTo: leadingAnchor), picture.trailingAnchor.constraint(equalTo: trailingAnchor),
            picture.topAnchor.constraint(equalTo: topAnchor), picture.bottomAnchor.constraint(equalTo: bottomAnchor),
            label.leadingAnchor.constraint(equalTo: badge.leadingAnchor, constant: 10), label.trailingAnchor.constraint(equalTo: badge.trailingAnchor, constant: -10),
            label.centerYAnchor.constraint(equalTo: badge.centerYAnchor), badge.heightAnchor.constraint(equalToConstant: 22),
            badge.centerXAnchor.constraint(equalTo: centerXAnchor), badge.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
        ])
        setAccessibilityLabel("Paused page. Click to resume.")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func scrollWheel(with event: NSEvent) { resume() }
}

extension NSColor {
    convenience init(hex: String) {
        let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")).prefix(6)
        let value = UInt32(digits, radix: 16) ?? 0x5E5CE6
        self.init(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                  blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }
}
