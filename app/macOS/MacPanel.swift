import AppKit
import SwiftUI

/// The settings window: the same iOS-style panel (a grouped list that opens sub-pages, with a
/// back button), in a window of its own next to the main one. ⌘, or the toolbar button opens and
/// closes it; it remembers its size and place. Its pages refresh only while it is open.
final class MacSettingsWindowController: NSWindowController, NSWindowDelegate {
    let panel = MacSettingsPanel()
    static let width: CGFloat = 440

    init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 720),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: true)
        w.title = "设置"
        // the page's own header sits in the title bar, beside the window buttons (the red one
        // closes the window, so the page has no close button of its own)
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        w.titlebarSeparatorStyle = .none
        let bar = NSToolbar(identifier: "settings")
        bar.showsBaselineSeparator = false
        w.toolbar = bar
        w.toolbarStyle = .unified
        w.contentViewController = panel
        w.setContentSize(NSSize(width: Self.width, height: 720))
        w.minSize = NSSize(width: 380, height: 420)
        w.isReleasedWhenClosed = false
        w.setFrameAutosaveName("SettingsWindow")
        super.init(window: w)
        w.delegate = self
        panel.onClose = { [weak self] in self?.close() }
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Set when settings live in the main window's sidebar: opening and closing go there.
    var onEmbed: ((Bool) -> Void)?
    var embeddedOpen = false
    var isPanelOpen: Bool { onEmbed != nil ? embeddedOpen : window?.isVisible == true }
    func togglePanel() { setPanel(open: !isPanelOpen) }

    /// Opens (next to the main window the first time) or closes the settings window.
    func setPanel(open: Bool, animated: Bool = true) {
        if let onEmbed { onEmbed(open); return }
        guard let w = window else { return }
        if open {
            if !w.setFrameUsingName("SettingsWindow"), let main = NSApp.mainWindow ?? NSApp.windows.first(where: { $0 !== w && $0.isVisible }) {
                // first time: beside the main window, on the right when there is room
                let screen = main.screen?.visibleFrame ?? .zero
                var f = w.frame
                f.size.height = min(main.frame.height, screen.height)
                f.origin.y = main.frame.maxY - f.height
                f.origin.x = main.frame.maxX + 12 + f.width <= screen.maxX ? main.frame.maxX + 12 : max(screen.minX, screen.maxX - f.width)
                w.setFrame(f, display: false)
            }
            panel.willShow()
            showWindow(nil)
            w.makeKeyAndOrderFront(nil)
        } else {
            w.performClose(nil)
        }
    }

    func windowWillClose(_ notification: Notification) { panel.didHide() }

    /// The media viewer no longer shares a window with the settings: nothing to do.
    func viewerChanged(open: Bool) {}
}

/// The panel: a header (back, title, close) above the current page; pages push and pop.
final class MacSettingsPanel: NSViewController {
    var onClose: (() -> Void)?
    /// Shown inside the main window (the sidebar's 设置): the header starts at the left edge
    /// instead of leaving room for the window buttons.
    var embedded = false { didSet { if isViewLoaded { applyEmbedded() } } }
    private var head: NSView?, line: NSView?
    private var topUnderHeader: NSLayoutConstraint?, topAtEdge: NSLayoutConstraint?
    private func applyEmbedded() {
        head?.isHidden = embedded
        line?.isHidden = embedded
        topUnderHeader?.isActive = !embedded
        topAtEdge?.isActive = embedded
    }
    private let back = NSButton()
    private let titleLabel = NSTextField(labelWithString: "设置")
    private let content = NSView()
    private var stack: [(NSViewController, String)] = []
    private var root: SettingsHost?

    override func loadView() {
        // an ordinary opaque settings surface (a vibrant sidebar material dims text and controls to gray)
        let v = MacOpaqueView(color: .windowBackgroundColor)
        v.frame = NSRect(x: 0, y: 0, width: MacSettingsWindowController.width, height: 720)
        back.bezelStyle = .accessoryBarAction
        back.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "返回")
        back.imagePosition = .imageLeading
        back.target = self
        back.action = #selector(pop)
        back.setAccessibilityIdentifier("panelBack")
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        let close = NSButton(image: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "关闭设置")!, target: self, action: #selector(closeClicked))
        close.isBordered = false
        close.contentTintColor = .secondaryLabelColor
        close.symbolConfiguration = .init(pointSize: 16, weight: .regular)
        close.setAccessibilityIdentifier("panelClose")
        close.toolTip = "关闭设置（⌘,）"
        _ = close
        let head = NSStackView(views: [back, titleLabel, NSView()])
        head.spacing = 8
        head.edgeInsets = NSEdgeInsets(top: 0, left: embedded ? 12 : 84, bottom: 0, right: 16)   // clear of the window buttons
        let line = NSBox(); line.boxType = .separator
        [head, line, content].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; v.addSubview($0) }
        NSLayoutConstraint.activate([
            head.topAnchor.constraint(equalTo: v.topAnchor), head.heightAnchor.constraint(equalToConstant: 52),   // the unified title bar's height
            head.leadingAnchor.constraint(equalTo: v.leadingAnchor), head.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            line.topAnchor.constraint(equalTo: head.bottomAnchor), line.leadingAnchor.constraint(equalTo: v.leadingAnchor), line.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            // in the main window the page title and back button are the window's (toolbar), so
            // the panel's own header is not shown
            content.bottomAnchor.constraint(equalTo: v.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: v.leadingAnchor), content.trailingAnchor.constraint(equalTo: v.trailingAnchor),
        ])
        self.head = head; self.line = line
        topUnderHeader = content.topAnchor.constraint(equalTo: line.bottomAnchor)
        topAtEdge = content.topAnchor.constraint(equalTo: v.topAnchor)
        applyEmbedded()
        view = v
        let r = MacSettingsPages.root()
        r.panel = self
        root = r
        show(r, title: "设置")
        stack = [(r, "设置")]
        updateHeader()
    }

    /// Opens a sub-page.
    func push(_ vc: NSViewController, title: String) {
        if let p = vc as? FormPane { p.panel = self }
        if let p = vc as? SettingsHost { p.panel = self }
        if let t = vc as? MacTagsPage { t.panel = self }
        stack.append((vc, title))
        show(vc, title: title)
        updateHeader()
    }

    @objc func pop() {
        guard stack.count > 1 else { return }
        let (old, _) = stack.removeLast()
        old.view.removeFromSuperview()
        old.removeFromParent()
        show(stack.last!.0, title: stack.last!.1)
        updateHeader()
    }

    func popToRoot() { while stack.count > 1 { pop() } }

    private func show(_ vc: NSViewController, title: String) {
        content.subviews.forEach { $0.removeFromSuperview() }
        if vc.parent == nil { addChild(vc) }
        vc.view.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(vc.view)
        NSLayoutConstraint.activate([vc.view.topAnchor.constraint(equalTo: content.topAnchor), vc.view.bottomAnchor.constraint(equalTo: content.bottomAnchor),
                                     vc.view.leadingAnchor.constraint(equalTo: content.leadingAnchor), vc.view.trailingAnchor.constraint(equalTo: content.trailingAnchor)])
    }

    private func updateHeader() {
        back.isHidden = stack.count < 2
        back.title = stack.count >= 2 ? stack[stack.count - 2].1 : ""
        titleLabel.stringValue = stack.last?.1 ?? "设置"
        onStackChanged?()
    }

    /// The page shown, and the one Back returns to (the main window's toolbar shows them).
    var onStackChanged: (() -> Void)?
    var currentTitle: String { stack.last?.1 ?? "设置" }
    var backTitle: String? { stack.count >= 2 ? stack[stack.count - 2].1 : nil }

    @objc private func closeClicked() { onClose?() }

    /// Pages refresh only while the panel is open (they own timers and observers).
    private(set) var isShown = false
    func willShow() { isShown = true; (stack.last?.0 as? FormPane)?.resume() }
    func didHide() { isShown = false; stack.forEach { ($0.0 as? FormPane)?.pause() } }
}

/// Every tag as a card (SwiftUI, hosted here): its name, how many media carry it, and a bar that
/// splits those media into yours, the AI's and both. Click a card to see only that tag on the
/// home screen; right-click for the rest (put its media into a folder, rename or merge, delete).
final class MacTagsPage: NSViewController {
    weak var panel: MacSettingsPanel?
    private let model = TagsModel()

    override func loadView() {
        model.window = { [weak self] in self?.view.window }
        model.openRenames = { [weak self] in self?.panel?.push(MacSettingsPages.renames(), title: "改名记录") }
        let host = NSHostingView(rootView: TagCardsView(model: model))
        host.setAccessibilityIdentifier("tagCards")
        view = host
        view.frame = NSRect(x: 0, y: 0, width: 680, height: 560)
        model.load()
    }
}

/// The page's state and the actions behind its menus (alerts and sheets belong to the window).
@MainActor
final class TagsModel: ObservableObject {
    enum Sort: String, CaseIterable { case count = "媒体数", ai = "AI 标签数", mine = "我的标签数", name = "名称" }
    enum Show: String, CaseIterable { case all = "全部", mine = "我的", ai = "AI", both = "共同" }

    @Published var all: [TagCount] = []
    @Published var query = ""
    @Published var sort = Sort.count
    @Published var show = Show.all
    @Published var loaded = false
    var window: () -> NSWindow? = { nil }
    var openRenames: () -> Void = {}

    func load() {
        DispatchQueue.global(qos: .userInitiated).async {
            let tags = Core.allTags()
            DispatchQueue.main.async { self.all = tags; self.loaded = true }
        }
    }

    /// Media with both your tag and the AI's: the two overlap by this much.
    static func common(_ t: TagCount) -> Int { max(0, t.user + t.ai - t.count) }

    var shown: [TagCount] {
        let k = query.trimmingCharacters(in: .whitespaces).lowercased()
        var v = k.isEmpty ? all : all.filter { $0.label.contains(k) }
        switch show {
        case .all: break
        case .mine: v = v.filter { $0.user > 0 }
        case .ai: v = v.filter { $0.ai > 0 }
        case .both: v = v.filter { Self.common($0) > 0 }
        }
        switch sort {
        case .count: return v.sorted { ($0.count, $1.label) > ($1.count, $0.label) }
        case .ai: return v.sorted { ($0.ai, $1.label) > ($1.ai, $0.label) }
        case .mine: return v.sorted { ($0.user, $1.label) > ($1.user, $0.label) }
        case .name: return v.sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
        }
    }

    func showOnHome(_ label: String) { NotificationCenter.default.post(name: MacFeedViewController.showLabelNote, object: label) }

    /// Every AI tag goes; tags I added or endorsed stay.
    func confirmRemoveAI() {
        let n = all.reduce(0) { $0 + $1.ai }
        guard n > 0 else { return macAlert(window(), "没有 AI 标签", "") }
        macChoose(window(), title: "删除全部 \(n) 个 AI 标签？", message: "只有 AI 加的标签会消失；你认可过的会保留为你的标签。会同步到其他设备，无法撤销。AI 不会自动重新分析这些媒体，需要时可以在「AI 模型」里重新标记。", options: ["删除 AI 标签"]) { [weak self] _ in
            do {
                try Core.removeAITags()
                NotificationCenter.default.post(name: .libraryChanged, object: nil)
                self?.load()
            } catch { macAlert(self?.window(), "无法删除 AI 标签", error.localizedDescription) }
        }
    }

    func rename(_ t: TagCount) {
        macPrompt(window(), title: "重命名「\(t.label)」", message: "改成已有的标签名即为合并，可以在「改名记录」里撤销。", placeholder: t.label, initial: t.label) { [weak self] to in
            let to = to.trimmingCharacters(in: .whitespaces)
            guard !to.isEmpty, to != t.label else { return }
            _ = try? Core.renameTag(t.label, to: to)
            NotificationCenter.default.post(name: .libraryChanged, object: nil)
            self?.load()
        }
    }

    func delete(_ t: TagCount) {
        macChoose(window(), title: "删除标签「\(t.label)」？",
                  message: "会从 \(t.count) 个媒体上去掉这个标签（我加的和 AI 加的都去掉），并同步到其他设备。媒体本身不会删除。",
                  options: ["删除标签"]) { [weak self] _ in
            do {
                try Core.deleteTag(t.label)
                NotificationCenter.default.post(name: .libraryChanged, object: nil)
                self?.load()
            } catch { macAlert(self?.window(), "无法删除标签", error.localizedDescription) }
        }
    }

    func toFolder(_ t: TagCount) {
        macChooseFolder(window(), title: "把「\(t.label)」的 \(t.count) 个媒体放入文件夹", suggested: t.label, message: "资料库里带有这个标签的每个媒体都会放进去（回收站里的不会）。") { [weak self] folder in
            guard let folder else { return }
            do {
                let n = try Core.tagToFolder(t.label, folder: folder)
                NotificationCenter.default.post(name: .libraryChanged, object: nil)
                macAlert(self?.window(), "已放入「\(folder)」", n == t.count ? "\(n) 个媒体" : "新加入 \(n) 个媒体（其余的已经在里面）")
            } catch { macAlert(self?.window(), "没有完成", error.localizedDescription) }
        }
    }
}

private extension Color {
    static let tagMine = Color.blue
    static let tagAI = Color.purple
    static let tagBoth = Color.green
}

struct TagCardsView: View {
    @ObservedObject var model: TagsModel
    private let columns = [GridItem(.adaptive(minimum: 190, maximum: 260), spacing: 14, alignment: .top)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                toolbar
                let tags = model.shown
                if !model.loaded {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 60)
                } else if tags.isEmpty {
                    emptyState
                } else {
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(tags, id: \.label) { t in TagCard(tag: t, model: model) }
                    }
                }
            }
            .frame(maxWidth: 900)
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity)
        }
    }

    private var toolbar: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("筛选标签", text: $model.query).textFieldStyle(.plain)
                    if !model.query.isEmpty {
                        Button { model.query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }.buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(.quaternary.opacity(0.6), in: Capsule())
                Menu {
                    Picker("排序", selection: $model.sort) { ForEach(TagsModel.Sort.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                } label: { Label("按" + model.sort.rawValue, systemImage: "arrow.up.arrow.down") }
                    .menuStyle(.borderlessButton).fixedSize()
                Menu {
                    Button("改名记录…") { model.openRenames() }
                    Divider()
                    Button("删除全部 AI 标签…", role: .destructive) { model.confirmRemoveAI() }
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).fixedSize()
            }
            HStack(spacing: 14) {
                Picker("", selection: $model.show) { ForEach(TagsModel.Show.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 230)
                Spacer()
                legend
            }
            Text(summary).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var summary: String {
        let n = model.shown.count
        return model.all.isEmpty ? "" : "共 \(model.all.count) 个标签" + (n == model.all.count ? "" : "，显示 \(n) 个") + " · 点一下卡片，在浏览里只看这个标签；右键有更多操作"
    }

    private var legend: some View {
        HStack(spacing: 12) {
            ForEach([("我的", Color.tagMine), ("AI", Color.tagAI), ("共同", Color.tagBoth)], id: \.0) { name, c in
                HStack(spacing: 5) { Circle().fill(c).frame(width: 8, height: 8); Text(name).font(.caption).foregroundStyle(.secondary) }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: model.all.isEmpty ? "tag" : "magnifyingglass").font(.system(size: 34)).foregroundStyle(.tertiary)
            Text(model.all.isEmpty ? "还没有标签" : "没有符合的标签").font(.headline)
            Text(model.all.isEmpty ? "给媒体加标签，或让 AI 自动标记，它们会出现在这里。" : "换个词，或者把上面的筛选改成「全部」。").font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity).padding(.top, 60)
    }
}

/// One tag: its name, the number of media, and who tagged them (a bar: yours, the AI's, both).
struct TagCard: View {
    let tag: TagCount
    @ObservedObject var model: TagsModel
    @State private var hovering = false

    private var common: Int { TagsModel.common(tag) }
    private var onlyMine: Int { tag.user - common }
    private var onlyAI: Int { tag.ai - common }

    var body: some View {
        Button { model.showOnHome(tag.label) } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text(tag.label).font(.system(size: 16, weight: .semibold)).lineLimit(2, reservesSpace: true).multilineTextAlignment(.leading)
                    Spacer(minLength: 4)
                    Image(systemName: "arrow.up.right").font(.caption.weight(.bold)).foregroundStyle(.tint)
                        .opacity(hovering ? 1 : 0)
                }
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("\(tag.count)").font(.system(size: 30, weight: .bold, design: .rounded)).monospacedDigit()
                    Text("个媒体").font(.callout).foregroundStyle(.secondary)
                }
                bar
                HStack(spacing: 10) {
                    if tag.user > 0 { stat("我的", tag.user, .tagMine) }
                    if tag.ai > 0 { stat("AI", tag.ai, .tagAI) }
                    if common > 0 { stat("共同", common, .tagBoth) }
                }
                .font(.caption)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .background { cardBackground }
        .scaleEffect(hovering ? 1.015 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: hovering)
        .onHover { hovering = $0 }
        .contextMenu {
            Button("在浏览里只看「\(tag.label)」") { model.showOnHome(tag.label) }
            Button("把 \(tag.count) 个媒体全部加入文件夹…") { model.toFolder(tag) }
            Divider()
            Button("重命名或合并…") { model.rename(tag) }
            Button("删除标签…", role: .destructive) { model.delete(tag) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(tag.label)，\(tag.count) 个媒体，我的 \(tag.user)，AI \(tag.ai)")
        .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder private var cardBackground: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        if #available(macOS 26.0, *) {
            Color.clear.glassEffect(.regular, in: shape)
        } else {
            shape.fill(.regularMaterial).overlay(shape.strokeBorder(.separator))
        }
    }

    private func stat(_ name: String, _ n: Int, _ c: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(c).frame(width: 7, height: 7)
            Text("\(name) \(n)").foregroundStyle(.secondary).monospacedDigit()
        }
    }

    /// One capsule split in yours (blue), both (green) and the AI's (purple); wide enough to see
    /// even a tiny share.
    private var bar: some View {
        GeometryReader { g in
            let total = max(tag.count, 1)
            let parts: [(Int, Color)] = [(onlyMine, .tagMine), (common, .tagBoth), (onlyAI, .tagAI)].filter { $0.0 > 0 }
            let gaps = CGFloat(max(parts.count - 1, 0)) * 2
            HStack(spacing: 2) {
                ForEach(Array(parts.enumerated()), id: \.offset) { _, p in
                    Capsule().fill(p.1.gradient).frame(width: max(5, (g.size.width - gaps) * CGFloat(p.0) / CGFloat(total)))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 8)
        .background(Capsule().fill(.quaternary.opacity(0.5)))
    }
}

/// A plain view filled with a (dynamic) color.
final class MacOpaqueView: NSView {
    private let color: NSColor
    init(color: NSColor) { self.color = color; super.init(frame: .zero); wantsLayer = true }
    required init?(coder: NSCoder) { fatalError() }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = color.cgColor }
}
