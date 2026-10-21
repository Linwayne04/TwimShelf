import AppKit

/// 整理 on the Mac (a place in the sidebar): one post at a time (a multi-media post as one group, loose media
/// alone). ↑ = keep · ← = delete the whole post (to the bin) · 1–9 or a click = into a folder · ⌘Z = undo,
/// or the buttons below the picture; no trackpad gestures. Decisions stay on this device.
///
/// The look (MacTriageKit) is plain: the picture on the window's own background, its text under
/// it, below that the folders and the buttons. The layout never depends on what is shown: the
/// picture takes the room that is left, the folders and the buttons stay where they are.
final class MacTriageView: NSView {
    private var queue: [Core.TriageUnit] = []
    /// Decided units, newest last, with the decision (undo brings the card back from that side).
    private var undoStack: [(unit: Core.TriageUnit, decision: Core.TriageDecision)] = []
    private var filter = Core.TriageFilter.saved
    private var page = 0
    private let stage = MacTriageStage()
    private var photo: MacTriagePhoto { stage.photo }
    private var thumbs: [MacTriageThumb] = []
    private let emptyIcon = NSImageView()
    private let emptyTitle = NSTextField(labelWithString: "")
    private let emptyDetail = NSTextField(wrappingLabelWithString: "")
    private let emptyBox = NSStackView()
    private let toast = MacToast()
    private let folderBar = MacTriageFolderBar()
    private var undoButton: NSButton!
    private var filterButton: NSButton!
    private var observer: NSObjectProtocol?
    private var loading = false
    private var reloadGeneration = 0
    private var rng = SystemRandomNumberGenerator()
    /// The first picture of the post on screen has not been decoded yet (the picture fades in with it).
    private var awaitingPicture = false
    /// "剩余 N 个", shown as the window's subtitle (the toolbar carries the title).
    private(set) var subtitle = ""
    private var countText = ""
    var onCountChanged: (() -> Void)?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        setAccessibilityIdentifier("triage")
        photo.alphaValue = 0      // shown once the first post has loaded (no empty picture first)
        photo.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(openCurrent)))

        // the decisions are the two larger buttons; undo and the filter sit beside them
        undoButton = MacTriageButtons.make("撤销", symbol: "arrow.uturn.backward", key: "⌘Z", id: "triageUndo") { [weak self] in self?.undo() }
        let delete = MacTriageButtons.make("删除", symbol: "trash", color: .systemRed, key: "←", large: true, id: "triageDelete") { [weak self] in self?.decide(.delete) }
        let keep = MacTriageButtons.make("保留", symbol: "checkmark", color: .systemGreen, key: "↑", large: true, id: "triageKeep") { [weak self] in self?.decide(.keep) }
        filterButton = MacTriageButtons.make("筛选", symbol: "line.3.horizontal.decrease", id: "triageFilter") { [weak self] in self?.openFilter() }
        undoButton.isEnabled = false
        for b in [delete, keep] { b.widthAnchor.constraint(greaterThanOrEqualToConstant: 112).isActive = true }
        let decisions = NSStackView(views: [undoButton, delete, keep])
        decisions.spacing = 12
        decisions.alignment = .centerY
        let actions = NSView()
        for v in [decisions, filterButton!] { v.translatesAutoresizingMaskIntoConstraints = false; actions.addSubview(v) }
        NSLayoutConstraint.activate([
            decisions.centerXAnchor.constraint(equalTo: actions.centerXAnchor), decisions.topAnchor.constraint(equalTo: actions.topAnchor), decisions.bottomAnchor.constraint(equalTo: actions.bottomAnchor),
            filterButton.trailingAnchor.constraint(equalTo: actions.trailingAnchor), filterButton.centerYAnchor.constraint(equalTo: actions.centerYAnchor),
        ])

        emptyIcon.image = NSImage(systemSymbolName: "checkmark.circle", accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 44, weight: .light))
        emptyIcon.contentTintColor = .tertiaryLabelColor
        emptyTitle.font = .systemFont(ofSize: 17, weight: .semibold)
        emptyDetail.alignment = .center
        emptyDetail.textColor = .secondaryLabelColor
        emptyDetail.font = .systemFont(ofSize: 14)
        emptyBox.orientation = .vertical
        emptyBox.alignment = .centerX
        emptyBox.spacing = 10
        [emptyIcon, emptyTitle, emptyDetail].forEach { emptyBox.addArrangedSubview($0) }
        emptyBox.isHidden = true

        folderBar.onPick = { [weak self] name in self?.file(into: name) }
        folderBar.onNew = { [weak self] in self?.newFolder() }
        folderBar.set(TriageFolders.ordered())
        [stage, folderBar, actions, emptyBox, toast].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; addSubview($0) }
        NSLayoutConstraint.activate([
            // The picture and the buttons never depend on what is shown: the stage is as wide as 880 (less
            // only in a narrow window), the picture fits into it, and the folders and the buttons
            // stay where they are for every post and every media of a post, so a pointer resting on
            // 保留 never ends up on 删除.
            stage.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 16), stage.centerXAnchor.constraint(equalTo: centerXAnchor),
            stage.widthAnchor.constraint(lessThanOrEqualToConstant: 880), stage.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -64),
            { let c = stage.widthAnchor.constraint(equalToConstant: 880); c.priority = .init(999); return c }(),
            // the folder bar: always there, always this high, between the picture and the buttons
            stage.bottomAnchor.constraint(equalTo: folderBar.topAnchor, constant: -14),
            folderBar.centerXAnchor.constraint(equalTo: centerXAnchor), folderBar.widthAnchor.constraint(equalTo: stage.widthAnchor),
            folderBar.heightAnchor.constraint(equalToConstant: 30),
            folderBar.bottomAnchor.constraint(equalTo: actions.topAnchor, constant: -16),
            actions.centerXAnchor.constraint(equalTo: centerXAnchor), actions.widthAnchor.constraint(equalTo: stage.widthAnchor),
            actions.heightAnchor.constraint(equalToConstant: 36),
            actions.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -20),
            emptyBox.centerXAnchor.constraint(equalTo: centerXAnchor), emptyBox.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -30),
            emptyBox.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
            toast.centerXAnchor.constraint(equalTo: centerXAnchor), toast.bottomAnchor.constraint(equalTo: folderBar.topAnchor, constant: -16),
        ])
        observer = NotificationCenter.default.addObserver(forName: .libraryChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload(keepCurrent: true) }
        }
        reload(keepCurrent: false)
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { observer.map(NotificationCenter.default.removeObserver) }

    override var acceptsFirstResponder: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor }
    #if DEBUG
    func debugOpenFilter() { openFilter() }
    /// Posts in the queue once it has loaded (nil while loading).
    var debugLoadedCount: Int? { loading || (queue.isEmpty && countText.isEmpty) ? nil : queue.count }
    #endif

    // MARK: Queue

    private func reload(keepCurrent: Bool) {
        reloadGeneration += 1
        let generation = reloadGeneration
        loading = true
        updateCount()
        let f = filter
        DispatchQueue.global(qos: .userInitiated).async {
            let fresh = Core.triageQueue(f)
            DispatchQueue.main.async {
                guard generation == self.reloadGeneration else { return }
                self.loading = false
                let current = keepCurrent ? self.queue.first?.postId : nil
                let known = Set(self.queue.map(\.postId))
                let freshIds = Set(fresh.map(\.postId))
                var q = self.queue.filter { freshIds.contains($0.postId) }
                for u in fresh where !known.contains(u.postId) { q.insert(u, at: Int.random(in: 0...q.count, using: &self.rng)) }
                if let c = current, let i = q.firstIndex(where: { $0.postId == c }), i != 0 { q.insert(q.remove(at: i), at: 0) }
                let byId = Dictionary(fresh.map { ($0.postId, $0) }, uniquingKeysWith: { a, _ in a })
                self.queue = q.compactMap { byId[$0.postId] }
                if !keepCurrent { self.queue.shuffle(using: &self.rng) }
                // folders renamed, deleted or made elsewhere: the bar follows (rebuilt only then)
                let names = TriageFolders.refreshed(self.folderBar.names)
                if names != self.folderBar.names { self.folderBar.set(names) }
                // the post on screen stays as it is (a reload never flashes the picture)
                if keepCurrent, self.shownUnit == self.queue.first { self.updateCount(); return }
                self.showTop()
            }
        }
    }

    /// The post on the picture now.
    private var shownUnit: Core.TriageUnit?

    private func updateCount() {
        countText = queue.isEmpty ? "没有要整理的内容" : "剩余 \(queue.count) 个" + (filter.isEmpty ? "" : " · 已筛选")
        if loading { countText = "正在更新内容…" }
        else if let u = queue.first, u.pendingCount > 0 { countText += " · 当前帖子含 \(u.pendingCount) 个待下载媒体" }
        if subtitle != countText { subtitle = countText; onCountChanged?() }
    }

    private func showTop() {
        updateCount()
        undoButton.isEnabled = !undoStack.isEmpty
        let previous = shownUnit
        let previousID = previous?.items.indices.contains(page) == true ? previous?.items[page].mediaId : nil
        shownUnit = queue.first
        guard let u = queue.first else {
            stage.isHidden = true
            emptyBox.isHidden = false
            emptyTitle.stringValue = filter.isEmpty ? "全部整理完了" : "这个范围里整理完了"
            emptyDetail.stringValue = filter.isEmpty ? "整理过的内容不会再出现。需要重新整理时，可以在「设置」里清空整理记录。" : "点右下角的「筛选」换一个范围。"
            return
        }
        stage.isHidden = false
        emptyBox.isHidden = true
        thumbs.forEach { $0.removeFromSuperview() }
        thumbs = []
        stage.strip.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if u.items.count > 1 {
            for (i, it) in u.items.enumerated() {
                let b = MacTriageThumb()
                b.onClick = { [weak self] in self?.show(i) }
                b.setAccessibilityLabel("第 \(i + 1) 个媒体")
                MacMediaLoader.shared.load(it, maxPixel: 140) { [weak b] img in b?.setImage(img) }
                thumbs.append(b)
                stage.strip.addArrangedSubview(b)
            }
        }
        stage.stripHeight = u.items.count > 1 ? 44 : 0
        stage.caption.configure(u)
        photo.setImage(nil)      // a new post: never the previous post's picture (the picture fades in)
        photo.alphaValue = 0
        awaitingPicture = true
        show(previous?.postId == u.postId ? (u.items.firstIndex { $0.mediaId == previousID } ?? 0) : 0)
        window?.makeFirstResponder(self)
    }

    private func show(_ i: Int) {
        guard let u = queue.first, u.items.indices.contains(i) else { return }
        page = i
        let it = u.items[i]
        photo.setPage(i, of: u.items.count, kind: it.kind)
        for (k, t) in thumbs.enumerated() { t.selectedThumb = k == i }
        // the current picture stays until the next one is decoded (clearing it first flashed)
        MacMediaLoader.shared.load(it, maxPixel: 1400) { [weak self] img in
            guard let self, self.page == i, self.shownUnit == u, self.queue.first == u else { return }
            self.photo.setImage(img)
            if self.awaitingPicture {
                self.awaitingPicture = false
                NSAnimationContext.runAnimationGroup { $0.duration = 0.22; $0.timingFunction = .springy; self.photo.animator().alphaValue = 1 }
            }
        }
    }

    @objc private func openCurrent() {
        guard let it = queue.first?.items[page] else { return }
        NSWorkspace.shared.open(it.fileURL)
    }

    // MARK: Decisions

    private func decide(_ d: Core.TriageDecision, folder: String? = nil) {
        guard !loading, let u = queue.first, shownUnit == u else { toast.show("正在更新内容，请稍候"); return }
        let applied: Bool
        do { applied = try Core.triageDecide(u.postId, d, folder: folder, expected: u.mediaIds) }
        catch { toast.show(error.localizedDescription); reload(keepCurrent: true); return }
        flyOff(d)
        queue.removeFirst()
        if applied {
            undoStack.append((u, d))
            let what = d == .keep ? "已保留" : (d == .delete ? "已移到回收站" : "已放入「\(folder ?? "")」")
            toast.show(what, action: "撤销") { [weak self] in self?.undo() }
            if d != .keep { notifyLibrary() }
        } else {
            toast.show("这条已经不在或已整理过，跳过")
        }
        showTop()
    }

    /// Screen offset of a decision's direction: keep = up, delete = left, folder = down.
    private func offset(_ d: Core.TriageDecision) -> CGVector {
        let up: CGFloat = isFlipped ? -1 : 1
        switch d {
        case .keep: return CGVector(dx: 0, dy: 700 * up)
        case .delete: return CGVector(dx: -900, dy: 0)
        case .folder: return CGVector(dx: 0, dy: -700 * up)
        }
    }

    /// The picture that was decided flies away — a snapshot of it, with its stamp — while the next
    /// post appears underneath (the stamp used to land on the next post).
    private func flyOff(_ d: Core.TriageDecision) {
        photo.showStamp(d == .keep ? "保留" : (d == .delete ? "删除" : "文件夹"),
                        color: d == .keep ? .systemGreen : (d == .delete ? .systemRed : .systemTeal))
        photo.layoutSubtreeIfNeeded()
        defer { photo.hideStamp() }
        guard photo.bounds.width > 0, photo.alphaValue > 0, let rep = photo.bitmapImageRepForCachingDisplay(in: photo.bounds) else { return }
        photo.cacheDisplay(in: photo.bounds, to: rep)
        let img = NSImage(size: photo.bounds.size)
        img.addRepresentation(rep)
        let ghost = NSImageView(frame: convert(photo.bounds, from: photo))
        ghost.image = img
        ghost.imageScaling = .scaleAxesIndependently
        ghost.wantsLayer = true
        ghost.layer?.shadowColor = NSColor.black.cgColor
        ghost.layer?.shadowOpacity = 0.3
        ghost.layer?.shadowRadius = 24
        addSubview(ghost, positioned: .above, relativeTo: stage)
        let v = offset(d)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.28
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            ghost.animator().setFrameOrigin(NSPoint(x: ghost.frame.minX + v.dx, y: ghost.frame.minY + v.dy))
            ghost.animator().alphaValue = 0
        }) { ghost.removeFromSuperview() }
    }

    /// Undo: the picture comes back in from the side it left.
    private func flyIn(_ d: Core.TriageDecision) {
        guard let layer = photo.layer else { return }
        let v = offset(d)
        let a = CABasicAnimation(keyPath: "transform.translation")
        a.fromValue = NSValue(size: NSSize(width: v.dx, height: isFlipped ? -v.dy : v.dy))
        a.toValue = NSValue(size: .zero)
        a.duration = 0.35
        a.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(a, forKey: "undo")
    }

    private func notifyLibrary() {
        if let o = observer { NotificationCenter.default.removeObserver(o) }
        NotificationCenter.default.post(name: .libraryChanged, object: nil)
        observer = NotificationCenter.default.addObserver(forName: .libraryChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload(keepCurrent: true) }
        }
    }

    private func undo() {
        guard let last = undoStack.popLast() else { toast.show("没有可以撤销的整理"); return }
        guard (try? Core.triageUndo(last.unit.postId)) == true else { toast.show("无法撤销：这条整理记录已经不在了"); return }
        queue.removeAll { $0.postId == last.unit.postId }
        queue.insert(last.unit, at: 0)
        notifyLibrary()
        showTop()
        flyIn(last.decision)
        toast.show("已撤销")
        reload(keepCurrent: true)
    }

    /// Files the whole post into a folder of the bar (nil: there is none yet, make one).
    private func file(into name: String?, quiet: Bool = false) {
        guard !queue.isEmpty else { return }
        guard let name else { if !quiet { newFolder() }; return }
        TriageFolders.used(name)
        decide(.folder, folder: name)
    }

    /// A new folder from the bar: created, the post filed into it, and it joins the bar at the end.
    private func newFolder() {
        guard !queue.isEmpty, let w = window else { return }
        macPrompt(w, title: "新建文件夹", message: "这个帖子（所有媒体）会放进去，并算作已整理。", placeholder: "文件夹名称") { [weak self] input in
            let n = input.trimmingCharacters(in: .whitespaces)
            guard let self, !n.isEmpty else { return }
            self.file(into: n)
            self.folderBar.set(TriageFolders.refreshed(self.folderBar.names))
            self.window?.makeFirstResponder(self)
        }
    }

    private func openFilter() {
        let vc = MacTriageFilter(filter: filter) { [weak self] f in
            self?.filter = f
            Core.TriageFilter.saved = f
            self?.queue = []
            self?.reload(keepCurrent: false)
        }
        let pop = NSPopover()
        pop.contentViewController = vc
        pop.behavior = .transient
        pop.show(relativeTo: filterButton.bounds, of: filterButton, preferredEdge: .maxY)
    }

    // MARK: Keyboard and trackpad

    override func keyDown(with e: NSEvent) {
        if e.modifierFlags.contains(.command), e.charactersIgnoringModifiers == "z" { undo(); return }
        switch e.keyCode {
        case 126: decide(.keep)      // ↑
        case 123: decide(.delete)    // ←
        case _ where !e.modifierFlags.contains(.command) && (1...9).contains(Int(e.charactersIgnoringModifiers ?? "") ?? 0):
            // 1–9 = the folders in the bar
            let digit = Int(e.charactersIgnoringModifiers ?? "") ?? 0
            file(into: folderBar.names.indices.contains(digit - 1) ? folderBar.names[digit - 1] : nil, quiet: true)
        case 124: show(min(page + 1, (queue.first?.items.count ?? 1) - 1))   // → next image of the post
        default: super.keyDown(with: e)
        }
    }

    /// No gestures on the Mac: decisions are made with the buttons or the keys only, so a stray
    /// scroll never keeps or deletes a post.
    override func scrollWheel(with e: NSEvent) {}
}

/// Filter popover: posts vs loose, photo vs video, folders, tags.
final class MacTriageFilter: NSViewController {
    private var filter: Core.TriageFilter
    private let done: (Core.TriageFilter) -> Void
    init(filter: Core.TriageFilter, done: @escaping (Core.TriageFilter) -> Void) { self.filter = filter; self.done = done; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let form = MacForm()
        form.translucentGroups = true
        func toggle(_ on: Bool, _ title: String, _ set: @escaping (Bool) -> Void) -> NSView {
            let sw = ClosureSwitch(on: on, changed: set)
            sw.controlSize = .small
            sw.setAccessibilityLabel(title)
            return sw
        }
        let kind = ClosurePopUp(items: [("all", "帖子和散装媒体"), ("posts", "只看帖子"), ("loose", "只看散装媒体")], selected: filter.kind.rawValue) { [weak self] v in self?.filter.kind = .init(rawValue: v) ?? .all }
        let media = ClosurePopUp(items: [("all", "照片和视频"), ("photo", "只看照片"), ("video", "只看视频")], selected: filter.media.rawValue) { [weak self] v in self?.filter.media = .init(rawValue: v) ?? .all }
        form.card("整理范围")
        form.field("内容", [kind])
        form.field("媒体", [media])
        form.field("只看最近添加", detail: "5 天内批量下载的帖子", [toggle(filter.recentOnly, "只看最近添加") { [weak self] on in self?.filter.recentOnly = on }])
        let folders = Core.folders()
        if !folders.isEmpty {
            form.card("文件夹", footer: "都不选＝不限。")
            for f in folders {
                form.field(f.name, detail: "\(f.count) 个", [toggle(filter.folders.contains(f.name), f.name) { [weak self] on in
                    if on { self?.filter.folders.append(f.name) } else { self?.filter.folders.removeAll { $0 == f.name } } }])
            }
        }
        let tags = Core.allTags().prefix(40)
        if !tags.isEmpty {
            form.card("标签", footer: "都不选＝不限。")
            for t in tags {
                form.field(t.label, detail: "\(t.count) 个", [toggle(filter.labels.contains(t.label), t.label) { [weak self] on in
                    if on { self?.filter.labels.append(t.label) } else { self?.filter.labels.removeAll { $0 == t.label } } }])
            }
        }
        form.endSection()
        form.button("全部重置") { [weak self] in self?.filter = Core.TriageFilter(); self?.apply() }
        form.button("应用") { [weak self] in self?.apply() }
        let sc = NSScrollView()
        sc.hasVerticalScroller = true
        sc.drawsBackground = false
        form.translatesAutoresizingMaskIntoConstraints = false
        // as tall as its content (up to 560 pt, then it scrolls): no empty glass under the buttons
        let probe = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 10))
        probe.addSubview(form)
        let w = form.widthAnchor.constraint(equalToConstant: 400)
        w.isActive = true
        let h = min(560, max(200, form.fittingSize.height))
        w.isActive = false
        form.removeFromSuperview()
        sc.documentView = form
        form.widthAnchor.constraint(equalTo: sc.contentView.widthAnchor).isActive = true
        sc.frame = NSRect(x: 0, y: 0, width: 400, height: h)
        view = sc
    }

    private func apply() { done(filter); (view.window?.contentViewController as? NSViewController)?.dismiss(nil); view.window?.close() }
}


/// The folders under the picture, after a "放入" label: one click files the post; the first nine
/// also with 1–9 (shown quietly on each). Scrolls sideways when there are many; its height never
/// changes.
final class MacTriageFolderBar: NSView {
    var onPick: ((String) -> Void)?
    var onNew: (() -> Void)?
    private(set) var names: [String] = []
    private let scroll = NSScrollView()
    private let row = NSStackView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = false
        scroll.hasVerticalScroller = false
        scroll.horizontalScrollElasticity = .allowed
        scroll.verticalScrollElasticity = .none
        row.orientation = .horizontal
        row.spacing = 8
        row.alignment = .centerY
        row.edgeInsets = NSEdgeInsets(top: 0, left: 2, bottom: 0, right: 2)
        row.translatesAutoresizingMaskIntoConstraints = false
        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(row)
        scroll.documentView = doc
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor), scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor), scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            // centred under the picture while it fits, scrolling sideways when it does not
            row.topAnchor.constraint(equalTo: doc.topAnchor), row.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
            row.leadingAnchor.constraint(greaterThanOrEqualTo: doc.leadingAnchor), row.trailingAnchor.constraint(lessThanOrEqualTo: doc.trailingAnchor),
            row.centerXAnchor.constraint(equalTo: doc.centerXAnchor),
            doc.heightAnchor.constraint(equalTo: scroll.contentView.heightAnchor),
            doc.widthAnchor.constraint(greaterThanOrEqualTo: scroll.contentView.widthAnchor),
            doc.widthAnchor.constraint(greaterThanOrEqualTo: row.widthAnchor),
        ])
        setAccessibilityIdentifier("triageFolderBar")
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Sideways scrolling only (a vertical scroll is not a gesture here).
    override func scrollWheel(with e: NSEvent) { if abs(e.scrollingDeltaX) > abs(e.scrollingDeltaY) { scroll.scrollWheel(with: e) } }

    func set(_ list: [String]) {
        names = list
        row.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let lead = NSTextField(labelWithString: "放入")
        lead.font = .systemFont(ofSize: 13, weight: .semibold)
        lead.textColor = .secondaryLabelColor
        lead.setAccessibilityElement(false)
        row.addArrangedSubview(lead)
        for (i, n) in list.enumerated() {
            let c = MacTriageButtons.make(n, symbol: "folder", key: i < 9 ? "\(i + 1)" : nil, id: "triageFolder-\(n)") { [weak self] in self?.onPick?(n) }
            c.toolTip = i < 9 ? "放入「\(n)」（按 \(i + 1)）" : "放入「\(n)」"
            c.setAccessibilityLabel("放入「\(n)」")
            c.controlSize = .small
            row.addArrangedSubview(c)
        }
        let add = MacTriageButtons.make("新建文件夹…", symbol: "folder.badge.plus", id: "triageNewFolder") { [weak self] in self?.onNew?() }
        add.setAccessibilityLabel("新建文件夹并放入")
        add.controlSize = .small
        row.addArrangedSubview(add)
    }

    private final class FlippedView: NSView { override var isFlipped: Bool { true } }
}
