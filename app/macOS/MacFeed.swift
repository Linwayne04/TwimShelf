import AppKit
import AVFoundation

/// One card: media pager above the caption (author, text, link, tags).
final class FeedCard: NSCollectionViewItem {
    static let id = NSUserInterfaceItemIdentifier("FeedCard")
    static let mediaRatio: CGFloat = 1.25

    var onOpen: ((FeedItem) -> Void)?
    var onTag: ((String) -> Void)?
    var onAddTag: ((FeedCard, NSView, NSRect) -> Void)?
    var onRecent: (() -> Void)?
    var onPage: (() -> Void)?
    /// Right-click menu of a tag pill.
    var menuForTag: ((TagView, FeedItem) -> NSMenu?)?
    private(set) var items: [FeedItem] = []
    private(set) var page = 0

    let mediaView = SwipeMediaView()
    let mediaImage = ImageLayerView()
    let playerLayer = AVPlayerLayer()
    private let playBadge = NSImageView()
    private let badBadge = NSTextField(labelWithString: " ⚠︎ 文件已损坏 ")
    private let counter = NSTextField(labelWithString: "")
    private let prevButton = NSButton()
    private let nextButton = NSButton()
    private let author = NSTextField(labelWithString: "")
    private let body = NSTextField(wrappingLabelWithString: "")
    private let link = NSButton()
    let tagScroll = MacHScroll()
    private var tags: TagStripView { tagScroll.strip }

    var current: FeedItem? { items.indices.contains(page) ? items[page] : nil }

    override func loadView() {
        let root = MacCardView()
        view = root

        mediaView.wantsLayer = true
        // a quiet neutral behind images that do not fill the frame (black bars looked like a broken image)
        mediaView.layer?.backgroundColor = MacCardView.mediaFill.cgColor
        playerLayer.videoGravity = .resizeAspect
        mediaView.layer?.addSublayer(playerLayer)
        playBadge.image = NSImage(systemSymbolName: "play.circle.fill", accessibilityDescription: "视频")
        playBadge.symbolConfiguration = .init(pointSize: 40, weight: .regular)
        playBadge.contentTintColor = .white.withAlphaComponent(0.9)
        counter.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        counter.textColor = .white
        counter.wantsLayer = true
        counter.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        counter.layer?.cornerRadius = 8
        for (b, sym, sel) in [(prevButton, "chevron.left.circle.fill", #selector(prev)), (nextButton, "chevron.right.circle.fill", #selector(next))] {
            b.isBordered = false
            b.image = NSImage(systemSymbolName: sym, accessibilityDescription: nil)
            b.symbolConfiguration = .init(pointSize: 22, weight: .regular)
            b.contentTintColor = .white.withAlphaComponent(0.85)
            b.target = self; b.action = sel
        }
        badBadge.font = .systemFont(ofSize: 11, weight: .bold)
        badBadge.textColor = .white
        badBadge.wantsLayer = true
        badBadge.layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(0.85).cgColor
        badBadge.layer?.cornerRadius = 8
        badBadge.isHidden = true
        badBadge.setAccessibilityIdentifier("badBadge")
        [mediaImage, playBadge, counter, prevButton, nextButton, badBadge].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; mediaView.addSubview($0) }

        author.font = .systemFont(ofSize: 13, weight: .semibold)
        author.lineBreakMode = .byTruncatingTail
        body.font = .systemFont(ofSize: 13)
        body.maximumNumberOfLines = 3
        body.lineBreakMode = .byWordWrapping
        body.cell?.truncatesLastVisibleLine = true
        // Long text yields first: it may lose lines, the tag row never does.
        body.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        link.isBordered = false
        link.contentTintColor = .linkColor
        link.font = .systemFont(ofSize: 11)
        link.alignment = .left
        link.lineBreakMode = .byTruncatingMiddle
        link.target = self; link.action = #selector(openLink)
        tags.sideInset = 14
        tags.onTag = { [weak self] l in self?.onTag?(l) }
        tags.onRecent = { [weak self] in self?.onRecent?() }
        tags.onAdd = { [weak self] v, r in if let self { self.onAddTag?(self, v, r) } }
        tags.menuForTag = { [weak self] t in self?.current.flatMap { it in self?.menuForTag?(t, it) } }
        let caption = NSStackView(views: [author, body, link])
        caption.orientation = .vertical
        caption.alignment = .leading
        caption.spacing = 5
        [mediaView, caption, tagScroll].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; root.addSubview($0) }
        NSLayoutConstraint.activate([
            mediaView.topAnchor.constraint(equalTo: root.topAnchor),
            mediaView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            mediaView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            mediaView.heightAnchor.constraint(equalTo: mediaView.widthAnchor, multiplier: Self.mediaRatio),
            mediaImage.topAnchor.constraint(equalTo: mediaView.topAnchor), mediaImage.bottomAnchor.constraint(equalTo: mediaView.bottomAnchor),
            mediaImage.leadingAnchor.constraint(equalTo: mediaView.leadingAnchor), mediaImage.trailingAnchor.constraint(equalTo: mediaView.trailingAnchor),
            playBadge.centerXAnchor.constraint(equalTo: mediaView.centerXAnchor), playBadge.centerYAnchor.constraint(equalTo: mediaView.centerYAnchor),
            counter.topAnchor.constraint(equalTo: mediaView.topAnchor, constant: 10), counter.trailingAnchor.constraint(equalTo: mediaView.trailingAnchor, constant: -10),
            badBadge.topAnchor.constraint(equalTo: mediaView.topAnchor, constant: 10), badBadge.leadingAnchor.constraint(equalTo: mediaView.leadingAnchor, constant: 10),
            prevButton.leadingAnchor.constraint(equalTo: mediaView.leadingAnchor, constant: 8), prevButton.centerYAnchor.constraint(equalTo: mediaView.centerYAnchor),
            nextButton.trailingAnchor.constraint(equalTo: mediaView.trailingAnchor, constant: -8), nextButton.centerYAnchor.constraint(equalTo: mediaView.centerYAnchor),
            caption.topAnchor.constraint(equalTo: mediaView.bottomAnchor, constant: 10),
            caption.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            caption.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            body.widthAnchor.constraint(equalTo: caption.widthAnchor),
            // Tags follow the text (no gap under a short caption) and can never be pushed out
            // of the card by a long one.
            // the row scrolls sideways when the tags are wider than the card
            // the row spans the card; the strip leaves the margin itself, so scrolled pills end at
            // the card's edge rather than at a line 14 pt inside it
            tagScroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            tagScroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            tagScroll.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -14),
            { let c = tagScroll.topAnchor.constraint(equalTo: caption.bottomAnchor, constant: 8); c.priority = .defaultHigh; return c }(),
            tagScroll.heightAnchor.constraint(equalToConstant: 20),
            caption.bottomAnchor.constraint(lessThanOrEqualTo: tagScroll.topAnchor, constant: -6),
            link.widthAnchor.constraint(lessThanOrEqualTo: caption.widthAnchor),
        ])
        mediaView.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(clicked)))
        // Two-finger horizontal swipe over the media flips through a post's pages.
        mediaView.onSwipe = { [weak self] forward in
            guard let self, self.items.count > 1 else { return false }
            if forward { self.next() } else { self.prev() }
            return true
        }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        playerLayer.frame = mediaView.bounds
        view.effectiveAppearance.performAsCurrentDrawingAppearance { mediaView.layer?.backgroundColor = MacCardView.mediaFill.cgColor }
        CATransaction.commit()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        playerLayer.player = nil
        mediaImage.image = nil
        MacMediaLoader.shared.cancel(imageToken); imageToken = nil
        tagScroll.scrollToStart()
        // forget what was shown: a reused card must load its image again (refresh() keeps the
        // image only for a card that is still on screen)
        items = []
    }

    static let decodePixels: CGFloat = 900
    private var imageToken: MacMediaLoader.Token?

    func configure(_ items: [FeedItem]) {
        self.items = items
        tagScroll.scrollToStart()
        page = 0
        show()
    }

    /// Same media as shown: update tags, text and badges in place (no image reload; the page and
    /// an inline video keep going). Otherwise a full configure.
    #if DEBUG
    var debugHasImage: Bool { mediaImage.image != nil }
    #endif

    func refresh(_ items: [FeedItem]) {
        guard !items.isEmpty, items.map(\.mediaId) == self.items.map(\.mediaId) else { return configure(items) }
        self.items = items
        if let it = current { badBadge.isHidden = it.bad == nil; badBadge.stringValue = " \(it.badText ?? "") " }
        showCaption()
    }

    var showsInlineVideo = false { didSet { playBadge.isHidden = current?.kind != .video || showsInlineVideo } }

    private func show() {
        guard let it = current else { return }
        playerLayer.player = nil
        showsInlineVideo = false
        MacMediaLoader.shared.cancel(imageToken)
        let id = it.mediaId
        badBadge.isHidden = it.bad == nil
        badBadge.stringValue = " \(it.badText ?? "") "
        // a decoded picture is shown in the same frame; one decoded later fades in, instead of
        // popping onto an empty card
        let cached = MacMediaLoader.shared.isCached(it, maxPixel: Self.decodePixels)
        mediaImage.image = nil
        imageToken = MacMediaLoader.shared.load(it, maxPixel: Self.decodePixels) { [weak self] img in
            if img == nil { MacMediaLoader.shared.reportIfBroken(it) }
            guard let self, self.current?.mediaId == id else { return }
            if !cached {
                let fade = CATransition(); fade.type = .fade; fade.duration = 0.15
                self.mediaImage.layer?.add(fade, forKey: "fade")
            }
            self.mediaImage.image = img
            self.imageToken = nil
        }
        showCaption()
    }

    /// The words being searched for: every occurrence in the author, text and tags is highlighted.
    var highlight: [String] = [] { didSet { if highlight != oldValue { showCaption() } } }
    static let highlightAttrs: [NSAttributedString.Key: Any] = [.backgroundColor: NSColor.systemYellow.withAlphaComponent(0.45)]

    private func marked(_ text: String, font: NSFont?, color: NSColor) -> NSAttributedString {
        let a = NSMutableAttributedString(string: text, attributes: [.font: font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize), .foregroundColor: color])
        SearchHighlight.apply(highlight, to: a, Self.highlightAttrs)
        return a
    }

    /// Counter, page buttons, author, text, link and tags of the current media.
    private func showCaption() {
        guard let it = current else { return }
        let multi = items.count > 1
        counter.isHidden = !multi
        counter.stringValue = " \(page + 1)/\(items.count) "
        prevButton.isHidden = !multi || page == 0
        nextButton.isHidden = !multi || page == items.count - 1
        var a = it.authorName ?? ""
        if let sn = it.screenName { a += (a.isEmpty ? "" : "  ") + "@\(sn)" }
        if it.isLoose { a = "◌ 散装媒体" }
        author.attributedStringValue = marked(a, font: author.font, color: it.isLoose ? .systemIndigo : .labelColor)
        author.isHidden = a.isEmpty
        body.isSelectable = true   // the text can be selected and copied
        body.attributedStringValue = marked(it.text ?? "", font: body.font, color: body.textColor ?? .labelColor)
        body.isHidden = (it.text ?? "").isEmpty
        link.title = it.url ?? ""
        link.isHidden = it.url == nil
        tags.set(it.tags, recent: it.isRecent, highlight: highlight)
        tagScroll.needsLayout = true
    }

    @objc private func prev() { if page > 0 { page -= 1; slide(forward: false); show(); onPage?() } else { bounce() } }
    @objc private func next() { if page < items.count - 1 { page += 1; slide(forward: true); show(); onPage?() } else { bounce() } }

    private func slide(forward: Bool) {
        let t = CATransition()
        t.type = .push
        t.subtype = forward ? .fromRight : .fromLeft
        t.duration = 0.22
        t.timingFunction = CAMediaTimingFunction(name: .easeOut)
        mediaView.layer?.add(t, forKey: "page")
    }

    /// At the first/last page: a small shake instead of nothing.
    private func bounce() {
        guard items.count > 1 else { return }
        let a = CAKeyframeAnimation(keyPath: "transform.translation.x")
        a.values = [0, -8, 6, -3, 0]
        a.duration = 0.25
        mediaImage.layer?.add(a, forKey: "bounce")
    }
    @objc private func clicked() { if let c = current { onOpen?(c) } }
    @objc private func openLink() { if let s = current?.url, let u = URL(string: s) { NSWorkspace.shared.open(u) } }

    /// Every card has the same height (media 4:5 + a fixed caption block: author, ≤3 lines of
    /// text, link, tags), so the grid never has to measure text while laying out or resizing.
    static let captionHeight: CGFloat = 10 + 17 + 5 + 17 * 3 + 5 + 16 + 5 + 20 + 14
    static func height(width: CGFloat) -> CGFloat { (width * mediaRatio).rounded() + captionHeight }
}

/// Main window content: highlighted search chips, then the random, endlessly looping card grid.
final class MacFeedViewController: NSViewController, NSCollectionViewDataSource, NSCollectionViewDelegate, NSMenuDelegate {
    /// Settings asks the feed to show one folder (object: name, or nil for everything).
    static let showFolderNote = Notification.Name("MacShowFolder")
    /// object = a tag label: show only media with that tag.
    static let showLabelNote = Notification.Name("MacShowLabel")
    private var allItems: [FeedItem] = []
    private var entries: [[FeedItem]] = []
    /// The search, from the toolbar's token field (as on iOS): texts, tag source, fields, and
    /// the conditions 文件夹 / 最近 / 外部导入.
    private(set) var terms: [String] = [] { didSet { collection.visibleItems().forEach { ($0 as? FeedCard)?.highlight = terms } } }
    private(set) var scope: SearchScope = .both
    private(set) var fields = SearchFields()
    private var tokenFolder: String?
    private var tokenRecent = false
    private var tokenExternal = false
    private var tokenKind: MediaKind?
    /// Settings → 语义模糊搜索.
    var fuzzy: Bool { LibraryPrefs.fuzzySearch }
    /// A tag clicked on a card (or "搜索此标签") goes into the toolbar's search field.
    var onSearchTag: ((String) -> Void)?
    /// A tag was renamed: the search field's capsule follows.
    var onRenameTerm: ((String, String) -> Void)?
    var grouped = UserDefaults.standard.object(forKey: "grouped") as? Bool ?? true {
        didSet { UserDefaults.standard.set(grouped, forKey: "grouped"); rebuildEntries(); passes = initialPasses(); collection.reloadData(); updateInline() }
    }
    /// Random order from the system RNG; ranks survive reloads until the next reshuffle.
    private var order = FeedOrder()
    /// "Only this author" / "only this tag" filters set from the right-click menus.
    private var filter = FeedFilter()
    /// Looping: each pass over all entries is one section with an "again from the top" footer;
    /// another pass is appended when the user nears the end, so the collection only ever holds a
    /// few passes instead of a huge virtual item count.
    private var passes = 1
    private var sectionCount: Int { entries.isEmpty ? 0 : passes }
    private let toast = MacToast()
    /// Position in the unfiltered feed before a search/filter, restored when it is closed.
    private var savedBrowse: (origin: NSPoint, passes: Int)?
    private var lastUnfiltered = true
    /// The player or photo viewer covering the feed (nil when browsing).
    private var viewer: NSView?
    /// A player that went to picture in picture: kept alive while its floating window plays.
    private var pipPlayer: MacPlayerView?

    private let scroll = NSScrollView()
    private let collection = NSCollectionView()
    private let chipBar = NSStackView()
    private let emptyLabel = NSTextField(labelWithString: "")
    private let statsLabel = NSTextField(labelWithString: "")
    private let activityPanel = MacActivityPanel()
    private let inlinePlayer = AVPlayer()
    private weak var inlineCard: FeedCard?
    private var generation = 0

    override func loadView() {
        // one background from the window's top edge down, under the toolbar and the chip row
        let root = MacOpaqueView(color: MacCardView.feedBackground)
        let layout = NSCollectionViewFlowLayout()
        layout.minimumLineSpacing = 18
        layout.minimumInteritemSpacing = 16
        layout.sectionInset = NSEdgeInsets(top: 12, left: 20, bottom: 24, right: 20)
        collection.collectionViewLayout = layout
        layout.itemSize = NSSize(width: 320, height: FeedCard.height(width: 320))
        collection.dataSource = self
        collection.delegate = self
        collection.backgroundColors = [MacCardView.feedBackground]
        collection.register(FeedCard.self, forItemWithIdentifier: FeedCard.id)
        collection.register(MacLoopSeparator.self, forSupplementaryViewOfKind: NSCollectionView.elementKindSectionFooter, withIdentifier: MacLoopSeparator.id)
        layout.footerReferenceSize = NSSize(width: 0, height: 56)
        let menu = NSMenu()
        menu.delegate = self
        collection.menu = menu
        scroll.documentView = collection
        scroll.hasVerticalScroller = true
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: scroll.contentView)

        statsLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        statsLabel.textColor = .secondaryLabelColor
        statsLabel.stringValue = ActivityCenter.shared.statsLine
        statsLabel.isHidden = true      // the window's subtitle shows it now
        NotificationCenter.default.addObserver(forName: ActivityCenter.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.statsLabel.stringValue = ActivityCenter.shared.statsLine }
        }
        chipBar.orientation = .horizontal
        chipBar.spacing = 8
        chipBar.edgeInsets = NSEdgeInsets(top: 8, left: 20, bottom: 8, right: 20)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.font = .systemFont(ofSize: 15)
        [chipBar, scroll, emptyLabel, statsLabel, activityPanel, toast].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; root.addSubview($0) }
        NSLayoutConstraint.activate([
            chipBar.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            chipBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            chipBar.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: chipBar.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: root.centerXAnchor), emptyLabel.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            statsLabel.centerYAnchor.constraint(equalTo: chipBar.centerYAnchor),
            statsLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            chipBar.trailingAnchor.constraint(lessThanOrEqualTo: statsLabel.leadingAnchor, constant: -10),
            activityPanel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            activityPanel.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -18),
            toast.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            toast.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -24),
        ])
        view = root
        inlinePlayer.isMuted = true
        NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] n in
            guard let self, (n.object as? AVPlayerItem) === self.inlinePlayer.currentItem else { return }
            self.inlinePlayer.seek(to: .zero); self.inlinePlayer.play()
        }
        NotificationCenter.default.addObserver(self, selector: #selector(libraryChanged), name: .libraryChanged, object: nil)
        NotificationCenter.default.addObserver(forName: LibraryPrefs.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.renderChips(); self?.reload() }
        }
        NotificationCenter.default.addObserver(forName: Self.showLabelNote, object: nil, queue: .main) { [weak self] n in
            MainActor.assumeIsolated {
                guard let self, let l = n.object as? String else { return }
                self.filter.labels = [l]
                self.renderChips(); self.reload()
            }
        }
        NotificationCenter.default.addObserver(forName: Self.showFolderNote, object: nil, queue: .main) { [weak self] n in
            MainActor.assumeIsolated { self?.showFolder(n.object as? String); self?.view.window?.makeKeyAndOrderFront(nil) }
        }
        NotificationCenter.default.addObserver(forName: SyncService.warning, object: nil, queue: .main) { [weak self] n in
            MainActor.assumeIsolated {
                guard let self, let text = n.userInfo?["text"] as? String else { return }
                if n.userInfo?["settings"] as? Bool == true {
                    self.toast.show(text, action: "打开系统设置") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork")!) }
                } else { self.toast.show(text) }
            }
        }
        renderChips()
        reload()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        updateItemSize()
    }

    private var flow: NSCollectionViewFlowLayout { collection.collectionViewLayout as! NSCollectionViewFlowLayout }

    /// Recomputes the uniform card size only when the column width actually changes.
    private func updateItemSize() {
        let w = columnWidth
        guard w > 0 else { return }
        let size = NSSize(width: w, height: FeedCard.height(width: w))
        if flow.itemSize != size { flow.itemSize = size }
    }

    /// Browsing loops endlessly; search results are shown once and end with a footer.
    private var loops: Bool { terms.isEmpty }
    private func entryKey(_ e: [FeedItem]) -> String { (grouped ? e.first?.postId : e.first?.mediaId) ?? "" }

    /// After a change in the library, updates the grid without reloading it: removed cards fade
    /// out in every pass, changed cards update in place (no flash, no lost position). False when
    /// cards were added or reordered; the caller then reloads.
    private func incrementalUpdate(from old: [[FeedItem]]) -> Bool {
        guard !old.isEmpty, !entries.isEmpty, collection.numberOfSections == passes,
              (0..<passes).allSatisfy({ collection.numberOfItems(inSection: $0) == old.count }) else { return false }
        let oldKeys = old.map(entryKey), newKeys = entries.map(entryKey)
        let keep = Set(newKeys)
        guard oldKeys.filter({ keep.contains($0) }) == newKeys else { return false }
        let removed = oldKeys.indices.filter { !keep.contains(oldKeys[$0]) }
        if !removed.isEmpty {
            let ips = Set((0..<passes).flatMap { s in removed.map { IndexPath(item: $0, section: s) } })
            collection.animator().performBatchUpdates({ collection.deleteItems(at: ips) })
        }
        let oldByKey = Dictionary(old.map { (entryKey($0), $0) }, uniquingKeysWith: { a, _ in a })
        for ip in collection.indexPathsForVisibleItems() where ip.item < entries.count && oldByKey[entryKey(entries[ip.item])] != entries[ip.item] {
            (collection.item(at: ip) as? FeedCard)?.refresh(entries[ip.item])
        }
        return true
    }

    private func initialPasses() -> Int { entries.isEmpty || !loops ? 1 : max(2, min(20, 400 / entries.count)) }

    // MARK: Data

    func reload(keepPosition: Bool = false) {
        generation += 1
        let gen = generation
        var f = filter
        if LibraryPrefs.badOnly { f.badOnly = true }
        if let d = tokenFolder { f.folder = d }
        if tokenRecent { f.recentOnly = true }
        if tokenExternal { f.looseOnly = true }
        if let k = tokenKind { f.kind = k }
        let activeFilter = f
        var req = FeedRequest(terms: terms, scope: scope, fuzzy: fuzzy, fields: fields, filter: activeFilter)
        let wantsVectors = fuzzy && (fields.tags || fields.text || !fields.author) && !terms.isEmpty && ModelStore.shared.activeEmbedderId != nil
        Task {
            if wantsVectors, let q = await AIEngine.shared.queryVectors(terms) { req.termVectors = q.vectors; req.embedModel = q.model }
            let items = await Task.detached(priority: .userInitiated) { (try? Core.feed(req)) ?? [] }.value
            guard gen == self.generation else { return }
            self.shownGeneration = gen
            let nowUnfiltered = self.terms.isEmpty && activeFilter.isEmpty
            if self.lastUnfiltered && !nowUnfiltered { self.savedBrowse = (self.scroll.contentView.bounds.origin, self.passes) }
            let restore = !self.lastUnfiltered && nowUnfiltered ? self.savedBrowse : nil
            if restore != nil { self.savedBrowse = nil }
            self.lastUnfiltered = nowUnfiltered
            let oldEntries = self.entries
            self.allItems = self.order.apply(items)
            self.rebuildEntries()
            if keepPosition, restore == nil, self.incrementalUpdate(from: oldEntries) {
                self.emptyLabel.isHidden = !items.isEmpty
                DispatchQueue.main.async { self.updateInline() }
                return
            }
            if let r = restore { self.passes = max(r.passes, self.initialPasses()) } else if !keepPosition || !self.loops { self.passes = self.initialPasses() }
            let origin = self.scroll.contentView.bounds.origin
            self.collection.reloadData()
            if let r = restore { self.collection.layoutSubtreeIfNeeded(); self.scroll.contentView.scroll(to: r.origin); self.scroll.reflectScrolledClipView(self.scroll.contentView) }
            else if keepPosition { self.scroll.contentView.scroll(to: origin) } else { self.collection.scroll(.zero) }
            self.emptyLabel.stringValue = self.terms.isEmpty && activeFilter.isEmpty ? "资料库是空的 — 用工具栏右侧的「管理」导入或下载帖子" : "没有匹配的媒体"
            self.emptyLabel.isHidden = !items.isEmpty
            DispatchQueue.main.async { self.updateInline() }
        }
    }

    func reshuffle() { order.reshuffle(); savedBrowse = nil; reload() }

    private func rebuildEntries() {
        guard grouped else { entries = allItems.map { [$0] }; return }
        entries = order.posts(allItems)
    }

    /// The media of everything the current search shows (all of it, not only what is on screen),
    /// and whether that is already the answer to the latest search.
    var resultMediaIds: [String] { allItems.map(\.mediaId) }
    var resultsAreCurrent: Bool { shownGeneration == generation }
    private var shownGeneration = -1

    private var pendingReload: DispatchWorkItem?
    @objc private func libraryChanged() {
        pendingReload?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.reload(keepPosition: true) }
        pendingReload = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: w)
    }

    // MARK: Chips

    /// The toolbar's search changed.
    func applyQuery(_ q: TokenQuery) {
        guard q.terms != terms || q.scope != scope || q.searchFields != fields || q.folder != tokenFolder || q.recent != tokenRecent || q.external != tokenExternal || q.kind != tokenKind else { return }
        terms = q.terms
        scope = q.scope
        fields = q.searchFields
        tokenFolder = q.folder
        tokenRecent = q.recent
        tokenExternal = q.external
        tokenKind = q.kind
        renderChips()
        reload()
    }

    /// A tag to search for, from a card: it becomes a capsule in the toolbar's search field.
    func addTerm(_ raw: String) { onSearchTag?(raw) }

    private func chip(_ title: String, color: NSColor, id: String, remove: @escaping () -> Void) -> NSButton {
        let b = ClosureButton(title: title, action: remove)
        b.isBordered = false
        b.wantsLayer = true
        b.layer?.cornerRadius = 12
        b.layer?.backgroundColor = color.cgColor
        b.attributedTitle = NSAttributedString(string: "  \(title)  ✕  ", attributes: [.foregroundColor: NSColor.white, .font: NSFont.systemFont(ofSize: 13, weight: .semibold)])
        b.heightAnchor.constraint(equalToConstant: 24).isActive = true
        b.setAccessibilityIdentifier(id)
        return b
    }

    private func renderChips() {
        chipBar.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if let k = filter.kind { chipBar.addArrangedSubview(chip(k == .video ? "仅视频" : "仅图片", color: .systemBlue, id: "chip-kind") { [weak self] in self?.filter.kind = nil; self?.renderChips(); self?.reload() }) }
        if filter.review == .unreviewed { chipBar.addArrangedSubview(chip("未认可", color: .systemOrange, id: "chip-review") { [weak self] in self?.filter.review = .any; self?.renderChips(); self?.reload() }) }
        if let a = filter.author {
            chipBar.addArrangedSubview(chip("只看 \(a.hasPrefix("@") ? a : "@" + a)", color: .systemIndigo, id: "chip-author") { [weak self] in self?.filter.author = nil; self?.renderChips(); self?.reload() })
        }
        for l in filter.labels {
            chipBar.addArrangedSubview(chip("仅 #\(l)", color: .systemGreen, id: "chip-label") { [weak self] in self?.filter.labels.removeAll { $0 == l }; self?.renderChips(); self?.reload() })
        }
        if filter.looseOnly { chipBar.addArrangedSubview(chip("散装媒体", color: .systemIndigo, id: "chip-loose") { [weak self] in self?.filter.looseOnly = false; self?.renderChips(); self?.reload() }) }
        if filter.recentOnly { chipBar.addArrangedSubview(chip("最近添加", color: .systemOrange, id: "chip-recent") { [weak self] in self?.filter.recentOnly = false; self?.renderChips(); self?.reload() }) }
        if let f = filter.folder { chipBar.addArrangedSubview(chip("文件夹：\(f)", color: .systemTeal, id: "chip-folder") { [weak self] in self?.showFolder(nil) }) }
        if LibraryPrefs.badOnly { chipBar.addArrangedSubview(chip("已损坏", color: .systemRed, id: "chip-bad") { LibraryPrefs.badOnly = false }) }
        // the search itself shows as capsules in the toolbar's search field
        onChipsChanged?()
    }

    /// A filter chip is on (a tag from the tags page, 仅视频, 未认可…): that is a search too.
    var hasChipFilter: Bool { !filter.isEmpty || LibraryPrefs.badOnly }
    var onChipsChanged: (() -> Void)?

    // MARK: Collection

    func numberOfSections(in cv: NSCollectionView) -> Int { sectionCount }

    func collectionView(_ cv: NSCollectionView, numberOfItemsInSection section: Int) -> Int { entries.count }

    func collectionView(_ cv: NSCollectionView, viewForSupplementaryElementOfKind kind: NSCollectionView.SupplementaryElementKind, at ip: IndexPath) -> NSView {
        let v = cv.makeSupplementaryView(ofKind: kind, withIdentifier: MacLoopSeparator.id, for: ip) as! MacLoopSeparator
        v.configure(count: entries.count, grouped: grouped, end: !loops)
        return v
    }

    func collectionView(_ cv: NSCollectionView, itemForRepresentedObjectAt ip: IndexPath) -> NSCollectionViewItem {
        #if DEBUG
        let t0 = CACurrentMediaTime(); defer { debugConfigureTime += CACurrentMediaTime() - t0; debugConfigures += 1 }
        #endif
        let card = cv.makeItem(withIdentifier: FeedCard.id, for: ip) as! FeedCard
        card.menuForTag = { [weak self] t, item in self?.tagMenu(t, item: item) }
        card.highlight = terms
        card.refresh(entries[ip.item % entries.count])
        card.onOpen = { [weak self] it in self?.open(it) }
        card.onTag = { [weak self] l in self?.addTerm(l) }
        card.onRecent = { [weak self] in guard let self, !self.filter.recentOnly else { return }; self.toggleRecentOnly() }
        card.onAddTag = { [weak self] card, anchor, rect in self?.showTagPicker(card, anchor: anchor, rect: rect) }
        card.onPage = { [weak self] in self?.updateInline() }
        return card
    }

    private var columnWidth: CGFloat {
        let w = scroll.contentSize.width - 40
        let cols = max(1, min(6, Int(w / 300)))
        return floor((w - CGFloat(cols - 1) * 16) / CGFloat(cols))
    }

    /// A card came on screen: re-check which video plays (a short result list never scrolls).
    private var pendingInline: DispatchWorkItem?
    func collectionView(_ cv: NSCollectionView, willDisplay item: NSCollectionViewItem, forRepresentedObjectAt ip: IndexPath) {
        pendingInline?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.updateInline() }
        pendingInline = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: w)
    }

    func collectionView(_ cv: NSCollectionView, didEndDisplaying item: NSCollectionViewItem, forRepresentedObjectAt ip: IndexPath) {
        if item === inlineCard { detachInline() }
    }

    /// While scrolling: load pictures a screen ahead, and choose the autoplay video only once the
    /// scroll pauses (swapping players at every scroll event during a fling cost frames and made
    /// cards flash between poster and video).
    @objc private func scrolled() {
        appendPassIfNearEnd()
        prefetchAhead()
        pendingInline?.cancel()
        if let card = inlineCard, !card.view.frame.intersects(scroll.contentView.documentVisibleRect) { detachInline() }
        let w = DispatchWorkItem { [weak self] in self?.updateInline() }
        pendingInline = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: w)
    }

    private var lastPrefetchY: CGFloat = .nan
    private func prefetchAhead() {
        let visible = scroll.contentView.documentVisibleRect
        let y = visible.minY
        if abs(y - lastPrefetchY) < visible.height / 4 { return }   // at most every quarter screen
        let down = lastPrefetchY.isNaN || y >= lastPrefetchY
        lastPrefetchY = y
        let ahead = down ? NSRect(x: visible.minX, y: visible.maxY, width: visible.width, height: visible.height)
                         : NSRect(x: visible.minX, y: visible.minY - visible.height, width: visible.width, height: visible.height)
        guard !entries.isEmpty, let attrs = collection.collectionViewLayout?.layoutAttributesForElements(in: ahead) else { return }
        // nearest first: the loader decodes the newest request first
        let ips = attrs.filter { $0.representedElementCategory == .item }.compactMap(\.indexPath)
            .sorted { down ? $0 > $1 : $0 < $1 }
        MacMediaLoader.shared.prefetch(ips.compactMap { entries[$0.item % entries.count].first }, maxPixel: FeedCard.decodePixels)
    }

    /// Endless loop: when within two screens of the bottom, append one more pass.
    private func appendPassIfNearEnd() {
        guard !entries.isEmpty, loops else { return }
        let visible = scroll.contentView.documentVisibleRect
        guard collection.frame.height - visible.maxY < visible.height * 2 else { return }
        guard collection.numberOfSections == sectionCount else { return }   // view synced with the data
        let start = passes
        passes += 1
        collection.insertSections(IndexSet(integer: start))
    }

    /// Muted autoplay for the most visible video card.
    private func updateInline() {
        // not while a collection covers the timeline
        if covered { detachInline(); return }
        let visible = scroll.contentView.documentVisibleRect
        var best: (FeedCard, CGFloat)?
        for case let card as FeedCard in collection.visibleItems() where card.current?.kind == .video {
            let f = card.view.frame.intersection(visible)
            let r = f.isNull ? 0 : (f.width * f.height) / max(card.view.frame.width * card.view.frame.height, 1)
            if r > 0.6, r > (best?.1 ?? 0) { best = (card, r) }
        }
        guard let card = best?.0, let item = card.current else { detachInline(); return }
        if card === inlineCard, (inlinePlayer.currentItem?.asset as? AVURLAsset)?.url == item.fileURL { return }
        detachInline()
        #if DEBUG
        debugInlineSwaps += 1
        #endif
        inlinePlayer.replaceCurrentItem(with: AVPlayerItem(url: item.fileURL))
        card.playerLayer.player = inlinePlayer
        card.showsInlineVideo = true
        inlineCard = card
        inlinePlayer.play()
    }

    private func detachInline() {
        inlinePlayer.pause()
        inlineCard?.playerLayer.player = nil
        inlineCard?.showsInlineVideo = false
        inlineCard = nil
    }

    /// Opens a media inside the main window (never a new window): the player or photo viewer
    /// covers the feed until it is closed.
    /// Opens a media of another list (a grid of the 文件夹 page): ← → goes through that list.
    func openMedia(_ item: FeedItem, in list: [FeedItem]) { open(item, list: list) }

    private func open(_ item: FeedItem, list: [FeedItem]? = nil) {
        let t = inlineCard?.current?.mediaId == item.mediaId ? inlinePlayer.currentTime() : .zero
        detachInline()
        if let p = pipPlayer { p.teardown(); pipPlayer = nil }
        let v: NSView
        if item.kind == .video, list == nil, entries.allSatisfy({ !$0.contains { $0.mediaId == item.mediaId } }) {
            // a video on its own (not in any list here): the player alone, with picture in picture
            let p = MacPlayerView(url: item.fileURL, startAt: t)
            p.onClose = { [weak self, weak p] in p?.teardown(); self?.closeViewer() }
            p.onPiPStart = { [weak self, weak p] in self?.pipPlayer = p; self?.closeViewer(keepPlayer: true) }
            p.onPiPRestore = { [weak self, weak p] in if let p { self?.showViewer(p) } }
            p.onPiPEnd = { [weak self, weak p] in
                guard let self, let p, self.pipPlayer === p else { return }
                if self.viewer !== p { p.teardown() }
                self.pipPlayer = nil
            }
            v = p
        } else {
            // every media of the list in its order, so ← → goes on past the post into the next
            // (a video included: it plays as a page of the viewer)
            let listed = list ?? entries.flatMap { $0 }
            let group = listed.contains { $0.mediaId == item.mediaId } ? listed : allItems.filter { $0.postId == item.postId }.sorted { $0.ordinal < $1.ordinal }
            // photos and videos alike: the viewer shows a video as a page, playing from where it was
            let ph = MacPhotoView(items: group.isEmpty ? [item] : group, index: group.firstIndex { $0.mediaId == item.mediaId } ?? 0, videoStart: t)
            ph.onClose = { [weak self, weak ph] in ph?.teardown(); self?.closeViewer() }
            v = ph
        }
        showViewer(v)
    }

    private func showViewer(_ v: NSView) {
        viewer?.removeFromSuperview()
        viewer = v
        v.translatesAutoresizingMaskIntoConstraints = false
        // the whole window (over the sidebar too), not only the timeline's pane
        let host = viewerHost?() ?? view
        host.addSubview(v)
        NSLayoutConstraint.activate([v.topAnchor.constraint(equalTo: host.topAnchor), v.bottomAnchor.constraint(equalTo: host.bottomAnchor),
                                     v.leadingAnchor.constraint(equalTo: host.leadingAnchor), v.trailingAnchor.constraint(equalTo: host.trailingAnchor)])
        v.alphaValue = 0
        NSAnimationContext.runAnimationGroup { $0.duration = 0.18; $0.timingFunction = .springy; v.animator().alphaValue = 1 }
        // Media gets the whole window: hide the toolbar (it overlapped the viewer's close button)
        // and the undo toast; the viewer itself covers the rest of the feed.
        setImmersive(true)
        toast.isHidden = true
        view.window?.makeFirstResponder(v)
    }

    private func closeViewer(keepPlayer: Bool = false) {
        guard let v = viewer else { return }
        viewer = nil
        setImmersive(false)
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.15; $0.timingFunction = .springy; v.animator().alphaValue = 0 }) { v.removeFromSuperview() }
        view.window?.makeFirstResponder(responderAfterViewer?() ?? collection)
        DispatchQueue.main.async { self.updateInline() }
    }

    var isShowingViewer: Bool { viewer != nil }

    /// Viewer mode: no toolbar, no traffic lights, transparent title bar — the media fills the
    /// whole window. Leaving restores the normal window chrome.
    /// The media viewer opened (true) or closed (false); the settings panel steps aside.
    var onViewer: ((Bool) -> Void)?

    private func setImmersive(_ on: Bool) {
        onViewer?(on)
        guard let w = view.window else { return }
        w.toolbar?.isVisible = !on
        // the title bar is always see-through: the feed background runs under the toolbar
        w.titlebarAppearsTransparent = true
        w.titlebarSeparatorStyle = .none
        // the window title would otherwise show over the media's top-left corner
        w.titleVisibility = on ? .hidden : .visible
        for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { w.standardWindowButton(b)?.isHidden = on }
    }

    #if DEBUG
    /// Sends synthetic trackpad gestures (with phases) to the first multi-page card.
    func debugSwipeTest() -> String {
        guard let card = collection.visibleItems().compactMap({ $0 as? FeedCard }).first(where: { $0.items.count > 1 }) else { return "no multi-page card visible" }
        func gesture(dx: Int32, dy: Int32, momentum: Bool = false) {
            for (i, phase) in [1, 2, 2, 2, 4].enumerated() {
                guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: i == 4 ? 0 : dy, wheel2: i == 4 ? 0 : dx, wheel3: 0) else { continue }
                cg.setIntegerValueField(CGEventField(rawValue: 88)!, value: 1)            // continuous (trackpad)
                cg.setIntegerValueField(CGEventField(rawValue: 99)!, value: momentum ? 0 : Int64(phase))   // scroll phase
                cg.setIntegerValueField(CGEventField(rawValue: 123)!, value: momentum ? Int64(phase) : 0)  // momentum phase
                if let e = NSEvent(cgEvent: cg) { card.mediaView.scrollWheel(with: e) }
            }
        }
        var log: [String] = []
        let y0 = scroll.contentView.bounds.origin.y
        log.append("start page=\(card.page) of \(card.items.count)")
        gesture(dx: -30, dy: 0); log.append("after swipe one way page=\(card.page)")
        gesture(dx: 30, dy: 0); log.append("after swipe back page=\(card.page)")
        gesture(dx: -30, dy: 0, momentum: true); log.append("after momentum-only page=\(card.page)")
        let p = card.page
        gesture(dx: 0, dy: -30); gesture(dx: 0, dy: 30); log.append("after vertical gesture page=\(card.page) unchanged=\(card.page == p) feedScrolled=\(scroll.contentView.bounds.origin.y != y0)")
        // control: the same synthetic vertical gesture straight to the scroll view
        let y1 = scroll.contentView.bounds.origin.y
        for (i, phase) in [1, 2, 2, 2, 4].enumerated() {
            guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: i == 4 ? 0 : -30, wheel2: 0, wheel3: 0) else { continue }
            cg.setIntegerValueField(CGEventField(rawValue: 88)!, value: 1); cg.setIntegerValueField(CGEventField(rawValue: 99)!, value: Int64(phase))
            if let e = NSEvent(cgEvent: cg) { scroll.scrollWheel(with: e) }
        }
        log.append("control: scroll view itself scrolled=\(scroll.contentView.bounds.origin.y != y1)")
        // realistic gestures: (dx, dy) per event, phases began, changed…, ended
        func path(_ steps: [(Int32, Int32)], began: Bool = true) {
            for (i, st) in steps.enumerated() {
                guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: st.1, wheel2: st.0, wheel3: 0) else { continue }
                cg.setIntegerValueField(CGEventField(rawValue: 88)!, value: 1)
                let phase: Int64 = i == steps.count - 1 ? 4 : (i == 0 && began ? 1 : 2)
                cg.setIntegerValueField(CGEventField(rawValue: 99)!, value: phase)
                if let e = NSEvent(cgEvent: cg) { card.mediaView.scrollWheel(with: e) }
            }
        }
        var p0 = card.page
        SwipeMediaView.forwarded = 0
        path([(3, -2), (4, -12), (2, -15), (3, -18), (0, 0)])          // vertical with sideways jitter at the start
        log.append("diagonal-ish vertical: page unchanged=\(card.page == p0) eventsToFeed=\(SwipeMediaView.forwarded)/5")
        p0 = card.page; SwipeMediaView.forwarded = 0
        path([(-1, 0), (-8, -2), (-14, -3), (-20, -2), (-10, 0), (0, 0)])   // sideways with a little vertical drift
        log.append("sideways with drift: paged=\(card.page != p0) eventsToFeed=\(SwipeMediaView.forwarded)/6")
        p0 = card.page; SwipeMediaView.forwarded = 0
        path([(-30, -4), (-30, -4), (0, 0)], began: false)               // a gesture that began elsewhere
        log.append("began elsewhere: page unchanged=\(card.page == p0) eventsToFeed=\(SwipeMediaView.forwarded)/3")
        p0 = card.page; SwipeMediaView.forwarded = 0
        path([(-6, -6), (-6, -6), (0, 0)])                                  // 45°: scrolling wins
        log.append("diagonal 45°: page unchanged=\(card.page == p0) eventsToFeed=\(SwipeMediaView.forwarded)/3")
        p0 = card.page; SwipeMediaView.forwarded = 0
        path([(1, 0), (0, 0)])                                              // a tap-sized twitch: nothing lost
        log.append("tiny: page unchanged=\(card.page == p0) eventsToFeed=\(SwipeMediaView.forwarded)/2")
        return log.joined(separator: "\n")
    }

    func debugOpenFirstPhoto() { if let it = allItems.first(where: { $0.kind == .photo }) { open(it) } }
    /// Opens the first photo of a post with several media; returns the viewer.
    /// Opens the tag adder as the long-press menu's "为整个帖子添加标签…" does; returns its window.
    func debugShowTagPicker() -> NSWindow? {
        guard let card = collection.visibleItems().compactMap({ $0 as? FeedCard }).first(where: { $0.items.count > 1 }) ?? collection.visibleItems().compactMap({ $0 as? FeedCard }).first else { return nil }
        showTagPicker(card, anchor: card.view, rect: card.view.bounds, wholePost: true)
        return tagPopover?.contentViewController?.view.window
    }

    func debugOpenGroupPhoto() -> MacPhotoView? {
        let posts = Dictionary(grouping: allItems, by: \.postId).filter { $0.value.count > 1 }
        guard let it = posts.values.first?.sorted(by: { $0.ordinal < $1.ordinal }).first(where: { $0.kind == .photo }) else { return nil }
        open(it)
        return viewer as? MacPhotoView
    }
    func debugCloseViewer() { closeViewer() }
    /// Scrolls the feed to a fraction of its height (0 = top, 1 = bottom).
    func debugScroll(toFraction f: CGFloat) {
        guard let clip = collection.enclosingScrollView?.contentView else { return }
        let maxY = max(0, collection.frame.height - clip.bounds.height)
        clip.scroll(to: NSPoint(x: 0, y: maxY * f))
        collection.enclosingScrollView?.reflectScrolledClipView(clip)
    }
    /// Gives the first visible card many tags, then sends a sideways and a vertical trackpad
    /// gesture to its tag row: the row must scroll sideways, and the vertical one must scroll the feed.
    /// Step 1 (sideways) and step 2 (vertical, after reading step 1's result): scroll views
    /// apply gestures asynchronously, so each result is read a moment later.
    func debugTagScrollTest(step: Int) -> String {
        guard let card = collection.visibleItems().compactMap({ $0 as? FeedCard }).min(by: { $0.view.frame.minY < $1.view.frame.minY }), let it = card.current else { return "no card" }
        let row = card.tagScroll
        func gesture(dx: Int32, dy: Int32) {
            for (i, phase) in [1, 2, 2, 2, 4].enumerated() {
                guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: i == 4 ? 0 : dy, wheel2: i == 4 ? 0 : dx, wheel3: 0) else { continue }
                cg.setIntegerValueField(CGEventField(rawValue: 88)!, value: 1)
                cg.setIntegerValueField(CGEventField(rawValue: 99)!, value: Int64(phase))
                if let e = NSEvent(cgEvent: cg) { row.scrollWheel(with: e) }
            }
        }
        switch step {
        case 1:
            for i in 1...14 { try? Core.addTag("测试标签\(i)", to: it.mediaId) }
            let ids = Set(card.items.map(\.mediaId))
            card.refresh(((try? Core.feed(FeedRequest())) ?? []).filter { ids.contains($0.mediaId) }.sorted { $0.ordinal < $1.ordinal })
            card.view.layoutSubtreeIfNeeded()
            gesture(dx: -60, dy: 0)   // fingers to the left: reveals the tags on the right
            return "tags=\(row.strip.count) content=\(Int(row.strip.frame.width)) row=\(Int(row.contentView.bounds.width))"
        case 2:
            debugMark = (scroll.contentView.bounds.origin.y, row.contentView.bounds.origin.x)
            gesture(dx: 0, dy: -60)
            return "after sideways gesture x=\(Int(row.contentView.bounds.origin.x))"
        default:
            return "after vertical gesture rowX unchanged=\(row.contentView.bounds.origin.x == debugMark.1) feedScrolled=\(scroll.contentView.bounds.origin.y != debugMark.0)"
        }
    }
    private var debugMark: (CGFloat, CGFloat) = (0, 0)
    var debugInlineSwaps = 0
    var debugConfigureTime = 0.0
    var debugConfigures = 0
    /// Visible cards that show a post but no picture.
    func debugBlankCards() -> Int {
        let visible = scroll.contentView.documentVisibleRect
        return collection.visibleItems().compactMap { $0 as? FeedCard }
            .filter { $0.view.frame.intersects(visible) && !$0.items.isEmpty && !$0.debugHasImage }.count
    }
    #endif

    // MARK: Tag menu (right-click)

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let p = collection.convert(view.window?.mouseLocationOutsideOfEventStream ?? .zero, from: nil)
        guard let ip = collection.indexPathForItem(at: p), let card = collection.item(at: ip) as? FeedCard, let item = card.current else { return }
        if !item.isLoose, let key = item.authorKey {
            menu.addItem(ClosureMenuItem("只看 \(item.authorDisplay) 的帖子") { [weak self] in self?.filter.author = key; self?.renderChips(); self?.reload() })
            if let sn = item.screenName, let u = URL(string: "https://x.com/\(sn)") {
                menu.addItem(ClosureMenuItem("在 X 打开 @\(sn) 的主页") { NSWorkspace.shared.open(u) })
            }
            menu.addItem(.separator())
        }
        menu.addItem(ClosureMenuItem("为这张媒体添加标签…") { [weak self] in self?.showTagPicker(card, anchor: card.view, rect: card.view.bounds, wholePost: false) })
        if !item.isLoose { menu.addItem(ClosureMenuItem("为整个帖子添加标签…") { [weak self] in self?.showTagPicker(card, anchor: card.view, rect: card.view.bounds, wholePost: true) }) }
        let pending = item.tags.filter { $0.isAI && !$0.isUser }
        if !pending.isEmpty {
            menu.addItem(ClosureMenuItem("认可全部 AI 标签") { [weak self] in
                pending.forEach { try? Core.addTag($0.label, to: item.mediaId) }; self?.reload(keepPosition: true) })
        }
        let taggers = ModelStore.shared.taggerIds
        if !taggers.isEmpty {
            let ref = Core.MediaRef(mediaId: item.mediaId, path: item.path, kind: item.kind.rawValue, text: item.text)
            let retag = NSMenuItem(title: "AI 重新标记", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for id in taggers {
                let modelMenu = NSMenu()
                modelMenu.addItem(ClosureMenuItem("只添加新标签") { AutoTagger.shared.retag([ref], model: id, replaceOld: false) })
                modelMenu.addItem(ClosureMenuItem("替换未认可的旧 AI 标签") { AutoTagger.shared.retag([ref], model: id, replaceOld: true) })
                let mi = NSMenuItem(title: (id == ModelStore.shared.activeTaggerId ? "★ " : "") + ModelStore.shared.displayName(id) + "　提示词：" + PromptSets.name(forModel: id), action: nil, keyEquivalent: "")
                mi.submenu = modelMenu
                sub.addItem(mi)
            }
            retag.submenu = sub
            menu.addItem(retag)
        }
        if !item.tags.isEmpty { menu.addItem(ClosureMenuItem("标签来源…") { [weak self] in self?.showSources(item) }) }
        if !item.tags.isEmpty { menu.addItem(.separator()) }
        for t in item.tags {
            let mi = NSMenuItem(title: (t.isAI ? (t.isUser ? "✓ " : "✦ ") : "") + t.label, action: nil, keyEquivalent: "")
            mi.submenu = tagMenu(t, item: item)
            menu.addItem(mi)
        }
        menu.addItem(.separator())
        menu.addItem(folderMenuItem("加入文件夹", media: [item.mediaId]))
        menu.addItem(folderMenuItem("整个帖子加入文件夹", posts: [item.postId]))
        let inFolders = Core.mediaFolders(item.mediaId)
        if !inFolders.isEmpty {
            let out = NSMenuItem(title: "移出文件夹", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for f in inFolders {
                sub.addItem(ClosureMenuItem("「\(f)」：只移出这张媒体") { [weak self] in _ = try? Core.removeFromFolder(f, media: [item.mediaId]); self?.reload(keepPosition: true) })
                sub.addItem(ClosureMenuItem("「\(f)」：移出整个帖子") { [weak self] in _ = try? Core.removeFromFolder(f, posts: [item.postId]); self?.reload(keepPosition: true) })
            }
            out.submenu = sub
            menu.addItem(out)
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(item.bad == nil ? "重新下载此媒体" : "重新下载（文件已损坏）") { [weak self] in self?.repair(item) })
        menu.addItem(.separator())
        if !item.tags.isEmpty {
            let del = NSMenuItem(title: "删除标签", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for t in item.tags { sub.addItem(ClosureMenuItem(t.label) { [weak self] in self?.deleteTag(t, from: item) }) }
            del.submenu = sub
            menu.addItem(del)
        }
        menu.addItem(ClosureMenuItem("删除这张媒体") { [weak self] in self?.deleteMedia([item]) })
        menu.addItem(ClosureMenuItem("删除整个帖子（含筛选隐藏及待下载媒体）") { [weak self] in self?.deletePost(item) })
    }

    /// Menu for one tag of one media (card menu and right-click on a tag pill).
    private func tagMenu(_ t: TagView, item: FeedItem) -> NSMenu {
        let sub = NSMenu()
        sub.addItem(ClosureMenuItem("仅看此标签") { [weak self] in
            guard let self else { return }
            if !self.filter.labels.contains(t.label) { self.filter.labels.append(t.label) }
            self.renderChips(); self.reload()
        })
        sub.addItem(ClosureMenuItem("搜索此标签") { [weak self] in self?.addTerm(t.label) })
        if t.isAI && !t.isUser { sub.addItem(ClosureMenuItem("认可") { [weak self] in try? Core.addTag(t.label, to: item.mediaId); self?.reload(keepPosition: true) }) }
        sub.addItem(ClosureMenuItem("重命名此标签…") { [weak self] in self?.renameTag(t.label) })
        sub.addItem(.separator())
        sub.addItem(ClosureMenuItem("删除标签") { [weak self] in self?.deleteTag(t, from: item) })
        return sub
    }

    // MARK: Folders

    /// Where the media viewer goes (the window's root view: over the sidebar too).
    var viewerHost: (() -> NSView)?
    /// What gets the keyboard when the viewer closes (the grid it was opened from).
    var responderAfterViewer: (() -> NSResponder?)?
    /// A collection covers the timeline (the sidebar chose something else): no inline video.
    private(set) var covered = false
    func setCovered(_ on: Bool) {
        covered = on
        // hidden, not only covered: its tooltips and tracking areas must not act under the page
        view.isHidden = on
        if on { detachInline() } else { updateInline() }
    }

    /// Shows a collection's media in the timeline (its 在时间线中查看): its filter as chips.
    func showFromFolders(_ f: FeedFilter, title: String) {
        filter = f
        renderChips()
        reload()
    }

    func showFolder(_ name: String?) {
        filter.folder = name
        renderChips()
        reload()
    }

    func toggleLooseOnly() { filter.looseOnly.toggle(); renderChips(); reload() }
    var looseOnly: Bool { filter.looseOnly }
    func toggleRecentOnly() { filter.recentOnly.toggle(); renderChips(); reload() }
    var recentOnly: Bool { filter.recentOnly }
    func showMessage(_ text: String) { toast.show(text) }
    var currentFolder: String? { filter.folder }

    private func folderMenuItem(_ title: String, media: [String] = [], posts: [String] = []) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for f in Core.folders() { sub.addItem(ClosureMenuItem(f.name) { [weak self] in self?.addToFolder(f.name, media: media, posts: posts) }) }
        if !sub.items.isEmpty { sub.addItem(.separator()) }
        sub.addItem(ClosureMenuItem("新建文件夹…") { [weak self] in
            macPrompt(self?.view.window, title: "新建文件夹", placeholder: "文件夹名称") { n in
                let n = n.trimmingCharacters(in: .whitespaces)
                if !n.isEmpty { self?.addToFolder(n, media: media, posts: posts) } }
        })
        mi.submenu = sub
        return mi
    }

    private func addToFolder(_ name: String, media: [String], posts: [String]) {
        do {
            let receipt = try Core.action(.folderAdd, media: media, posts: posts, folder: name)
            let n = receipt.count
            NotificationCenter.default.post(name: .libraryChanged, object: nil)
            toast.show(n == 0 ? "已经在「\(name)」里了" : "已将 \(n) 个媒体加入「\(name)」", action: n == 0 ? nil : "撤销") { [weak self] in
                do { self?.toast.show(try Core.undo(receipt)) } catch { self?.toast.show(error.localizedDescription) }
                NotificationCenter.default.post(name: .libraryChanged, object: nil)
                self?.reload(keepPosition: true)
            }
        } catch { macAlert(view.window, "无法加入文件夹", error.localizedDescription) }
    }

    // MARK: Renaming

    /// Renames a tag on every media (merges into an existing tag of the new name); undoable.
    func renameTag(_ old: String) {
        let count = Core.allTags().first { $0.label == old }?.count ?? 0
        macPrompt(view.window, title: "重命名标签「\(old)」", message: "所有 \(count) 个带这个标签的媒体都会改用新名字；新名字已存在时两者合并。正在进行的 AI 标记和其他设备也会自动使用新名字，之后可以撤销。", placeholder: old) { [weak self] text in
            let new = text.trimmingCharacters(in: .whitespaces)
            guard let self, !new.isEmpty, new.lowercased() != old else { return }
            do {
                let name = try Core.renameTag(old, to: new)
                self.onRenameTerm?(old, name)
                if let i = self.filter.labels.firstIndex(of: old) { self.filter.labels[i] = name }
                self.renderChips()
                NotificationCenter.default.post(name: .libraryChanged, object: nil)
                self.reload(keepPosition: true)
                self.toast.show("已将「\(old)」改名为「\(name)」", action: "撤销") { [weak self] in
                    try? Core.undoRename(old)
                    NotificationCenter.default.post(name: .libraryChanged, object: nil)
                    self?.reload(keepPosition: true)
                }
            } catch { macAlert(self.view.window, "无法重命名", error.localizedDescription) }
        }
    }

    // MARK: Deletion and repair

    private func deleteTag(_ t: TagView, from item: FeedItem) {
        try? Core.removeTag(t.label, from: item.mediaId)
        reload(keepPosition: true)
        toast.show("已删除标签「\(t.label)」", action: "撤销") { [weak self] in
            if t.isAI { try? Core.addTag(t.label, to: item.mediaId, ai: true) }
            if t.isUser { try? Core.addTag(t.label, to: item.mediaId) }
            self?.reload(keepPosition: true)
        }
    }

    private func deleteMedia(_ items: [FeedItem]) {
        do { afterDelete(try Core.action(.trash, media: items.map(\.mediaId))) }
        catch { toast.show(error.localizedDescription) }
    }

    private func deletePost(_ item: FeedItem) {
        do { afterDelete(try Core.action(.trash, posts: [item.postId])) }
        catch { toast.show(error.localizedDescription) }
    }

    private func afterDelete(_ receipt: Core.ActionReceipt) {
        guard receipt.count > 0 else { return }
        NotificationCenter.default.post(name: .libraryChanged, object: nil)
        reload(keepPosition: true)
        toast.show("已将 \(receipt.count) 个媒体移到回收站", action: "撤销") { [weak self] in
            do { self?.toast.show(try Core.undo(receipt)) } catch { self?.toast.show(error.localizedDescription) }
            NotificationCenter.default.post(name: .libraryChanged, object: nil)
            self?.reload(keepPosition: true)
        }
    }

    private func repair(_ item: FeedItem) {
        toast.show("正在重新下载…")
        DispatchQueue.global(qos: .userInitiated).async {
            let r = Result { try Core.repair(item.mediaId) }
            DispatchQueue.main.async {
                switch r {
                case .success(.replaced): self.toast.show("已重新下载，文件已修复")
                case .success(.replacedNew): macAlert(self.view.window, "已重新下载", "来源上的文件已经变化：新文件已放在原来的位置，并带上了原来的标签；旧文件移到了回收站。")
                case .success(.fromPeers): macAlert(self.view.window, "将从其他设备获取", "这条帖子没有链接，无法从网络下载。下次与其他设备同步时，会自动取回一份完好的副本。")
                case .failure(let e): self.toast.hide(); macAlert(self.view.window, "无法重新下载", e.localizedDescription)
                }
                MacMediaLoader.shared.forget()
                NotificationCenter.default.post(name: .libraryChanged, object: nil)
                self.reload(keepPosition: true)
            }
        }
    }

    private func showSources(_ item: FeedItem) {
        let lines = item.tags.map { t -> String in
            let who = t.isUser && t.isAI ? "我和 AI 共同" : (t.isAI ? "AI" : "我")
            let models = t.models.map { ModelStore.shared.displayName($0) }
            return "\(t.label)　·　\(who)" + (models.isEmpty ? "" : "（\(models.joined(separator: "、"))）")
        }
        macAlert(view.window, "标签来源", lines.joined(separator: "\n"))
    }

    private var tagPopover: NSPopover?
    /// The tag adder, from the "+" pill and from the menu's "添加标签" items alike.
    private func showTagPicker(_ card: FeedCard, anchor: NSView, rect: NSRect, wholePost: Bool = false) {
        guard let item = card.current else { return }
        guard let scope = try? Core.postScope(item.postId) else { macAlert(view.window, "无法读取帖子", "请重试"); return }
        let vc = MacTagPicker(media: item, scope: scope, wholePost: wholePost) { [weak self] in self?.reload(keepPosition: true) }
        let pop = NSPopover()
        pop.contentViewController = vc
        pop.behavior = .transient
        pop.animates = true
        pop.show(relativeTo: rect, of: anchor, preferredEdge: .maxY)
        tagPopover = pop
        // released when it closes (it holds the picker and the whole tag list)
        var token: NSObjectProtocol?
        token = NotificationCenter.default.addObserver(forName: NSPopover.didCloseNotification, object: pop, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if self?.tagPopover === pop { self?.tagPopover = nil } }
            if let token { NotificationCenter.default.removeObserver(token) }
        }
    }

}

final class ClosureMenuItem: NSMenuItem {
    private var handler: () -> Void = {}
    convenience init(_ title: String, _ handler: @escaping () -> Void) {
        self.init(title: title, action: #selector(fire), keyEquivalent: "")
        self.handler = handler
        target = self
    }
    @objc private func fire() { handler() }
}

/// Popover opened by the "+" pill: type to filter existing tags or create one; Enter adds.
final class MacTagPicker: NSViewController, NSSearchFieldDelegate {
    private let media: FeedItem
    private var postScope: Core.MediaScope
    private let onChange: () -> Void
    private let field = NSSearchField()
    private let list = NSStackView()
    private let scope = NSSegmentedControl()
    private let all = Core.allTags()
    private var added: [String] = []

    private let wholePost: Bool
    init(media: FeedItem, scope: Core.MediaScope, wholePost: Bool = false, onChange: @escaping () -> Void) {
        self.media = media; self.postScope = scope; self.onChange = onChange; self.wholePost = wholePost
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        field.placeholderString = "输入或选择标签，回车添加"
        field.delegate = self
        field.target = self
        field.action = #selector(enter)
        field.sendsWholeSearchString = true
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 4
        var views: [NSView] = [field]
        if postScope.pendingCount > 0 { views.append(NSTextField(labelWithString: "含 \(postScope.pendingCount) 个待下载媒体")) }
        if !media.isLoose {
            scope.segmentCount = 2
            scope.setLabel("这张媒体", forSegment: 0)
            scope.setLabel(postScope.title, forSegment: 1)
            scope.target = self; scope.action = #selector(scopeChanged)
            scope.selectedSegment = wholePost ? 1 : 0
            views.append(scope)
        }
        views.append(list)
        let st = NSStackView(views: views)
        st.orientation = .vertical
        st.alignment = .leading
        st.spacing = 10
        st.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        field.widthAnchor.constraint(equalToConstant: 260).isActive = true
        view = st
        render()
    }

    override func viewDidAppear() { super.viewDidAppear(); view.window?.makeFirstResponder(field) }

    func controlTextDidChange(_ obj: Notification) { render() }

    private var targetIDs: [String] { scope.selectedSegment == 1 ? postScope.ids : [media.mediaId] }
    private var existing: Set<String> { postScope.commonTags(targetIDs) }
    @objc private func scopeChanged() { added = []; render() }

    private func render() {
        list.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let q = field.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        for a in added { list.addArrangedSubview(NSTextField(labelWithString: "✓ \(a)")) }
        if !q.isEmpty, !all.contains(where: { $0.label == q }), !existing.contains(q) {
            list.addArrangedSubview(ClosureButton(title: "添加「\(q)」") { [weak self] in self?.add(q) })
        }
        for t in all.filter({ !existing.contains($0.label) && (q.isEmpty || $0.label.contains(q)) }).userFirst.prefix(10) {
            let b = ClosureButton(title: "\(t.label)  \(postScope.taggedCount(t.label, ids: targetIDs))/\(targetIDs.count) 已添加") { [weak self] in self?.add(t.label) }
            b.bezelStyle = .recessed
            list.addArrangedSubview(b)
        }
    }

    @objc private func enter() {
        let q = field.stringValue.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty { add(q) }
    }

    private func add(_ label: String) {
        let l = label.lowercased()
        guard !existing.contains(l) else { return }
        do { try Core.action(.tag, media: scope.selectedSegment == 1 ? [] : [media.mediaId], posts: scope.selectedSegment == 1 ? [media.postId] : [], label: l) }
        catch { macAlert(view.window, "无法添加标签", error.localizedDescription); return }
        if let refreshed = try? Core.postScope(media.postId) { postScope = refreshed }
        if scope.segmentCount > 1 { scope.setLabel(postScope.title, forSegment: 1) }
        added.append(l)
        field.stringValue = ""
        render()
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .default)
        onChange()
        NotificationCenter.default.post(name: .libraryChanged, object: nil)
    }
}

/// Full-width divider between two passes of the looping feed.
final class MacLoopSeparator: NSView, NSCollectionViewElement {
    static let id = NSUserInterfaceItemIdentifier("MacLoopSeparator")
    private let label = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        let left = NSBox(), right = NSBox()
        [left, right].forEach { $0.boxType = .separator; $0.translatesAutoresizingMaskIntoConstraints = false; addSubview($0) }
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        setAccessibilityIdentifier("loopSeparator")
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor), label.centerYAnchor.constraint(equalTo: centerYAnchor),
            left.centerYAnchor.constraint(equalTo: centerYAnchor), right.centerYAnchor.constraint(equalTo: centerYAnchor),
            left.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24), left.trailingAnchor.constraint(equalTo: label.leadingAnchor, constant: -12),
            right.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 12), right.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(count: Int, grouped: Bool, end: Bool = false) {
        if end { label.stringValue = "✓  共 \(count) \(grouped ? "条帖子" : "个媒体")，已经到底"; return }
        label.stringValue = "↺  已看完全部 \(count) \(grouped ? "条帖子" : "个媒体")，从头再来"
    }
}

/// Short message at the bottom of the feed with an optional action (e.g. undo).
final class MacToast: NSVisualEffectView {
    private let label = NSTextField(labelWithString: "")
    private let button = NSButton()
    private var action: (() -> Void)?
    private var hideWork: DispatchWorkItem?

    init() {
        super.init(frame: .zero)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 14
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .white
        button.isBordered = false
        button.target = self
        button.action = #selector(fire)
        button.setAccessibilityIdentifier("toastAction")
        let st = NSStackView(views: [label, button])
        st.spacing = 14
        st.edgeInsets = NSEdgeInsets(top: 10, left: 16, bottom: 10, right: 14)
        st.translatesAutoresizingMaskIntoConstraints = false
        addSubview(st)
        NSLayoutConstraint.activate([st.topAnchor.constraint(equalTo: topAnchor), st.bottomAnchor.constraint(equalTo: bottomAnchor),
                                     st.leadingAnchor.constraint(equalTo: leadingAnchor), st.trailingAnchor.constraint(equalTo: trailingAnchor)])
        alphaValue = 0
        isHidden = true
        setAccessibilityIdentifier("toast")
    }
    required init?(coder: NSCoder) { fatalError() }

    func show(_ text: String, action title: String? = nil, _ action: (() -> Void)? = nil) {
        label.stringValue = text
        button.isHidden = title == nil
        button.attributedTitle = NSAttributedString(string: title ?? "", attributes: [.foregroundColor: NSColor.systemYellow, .font: NSFont.systemFont(ofSize: 13, weight: .bold)])
        self.action = action
        hideWork?.cancel()
        isHidden = false
        layer?.zPosition = 100
        NSAnimationContext.runAnimationGroup { $0.duration = 0.2; $0.timingFunction = .springy; animator().alphaValue = 1 }
        let w = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: w)
    }

    func hide() {
        hideWork?.cancel()
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.2; $0.timingFunction = .springy; animator().alphaValue = 0 }) { [weak self] in self?.isHidden = true; self?.action = nil }
    }

    @objc private func fire() { action?(); hide() }
}

/// Media area of a card that turns two-finger horizontal trackpad swipes into page flips, while
/// vertical scrolling keeps scrolling the feed. One flip per gesture; momentum is ignored.
/// Which way a two-finger gesture goes, decided once per gesture from its first movement.
enum SwipeAxis {
    case horizontal, vertical
    /// Movement needed before deciding (pt), and how much more horizontal than vertical a
    /// gesture must be to page instead of scroll. Scrolling wins every doubtful case.
    static let decideAfter: CGFloat = 10
    static let ratio: CGFloat = 2
    /// nil = not enough movement yet.
    static func decide(dx: CGFloat, dy: CGFloat) -> SwipeAxis? {
        let (ax, ay) = (abs(dx), abs(dy))
        guard ax + ay >= decideAfter else { return nil }
        return ax >= ay * ratio ? .horizontal : .vertical
    }
}

/// The media area of a card. A two-finger gesture that starts on it is held back until it has
/// moved 10 pt; then it either pages (clearly sideways: twice as much horizontal as vertical
/// movement) or is handed to the feed in full, buffered events included, so a vertical scroll
/// never loses its start and never flips a page. A gesture that began elsewhere (the feed
/// scrolled the card under the pointer) always scrolls. Momentum after a page flip is swallowed.
final class SwipeMediaView: NSView {
    /// forward = next page. Returns false when there is nothing to flip (the event then scrolls the feed).
    var onSwipe: ((Bool) -> Bool)?
    private enum State { case idle, deciding, horizontal, vertical }
    private var state = State.idle
    private var buffer: [NSEvent] = []
    private var dx: CGFloat = 0, dy: CGFloat = 0
    private var accum: CGFloat = 0
    private var fired = false
    private var lastWasPage = false
    #if DEBUG
    /// Events handed on to the feed (self-test).
    static var forwarded = 0
    #endif
    private func forward(_ e: NSEvent) {
        #if DEBUG
        Self.forwarded += 1
        #endif
        super.scrollWheel(with: e)
    }

    override func scrollWheel(with e: NSEvent) {
        // Mouse wheels (no phases) always scroll the feed.
        guard e.hasPreciseScrollingDeltas, onSwipe != nil else { return forward(e) }
        if !e.momentumPhase.isEmpty { if lastWasPage { return }; return forward(e) }
        if e.phase == .mayBegin { return forward(e) }
        if e.phase == .began { state = .deciding; buffer = []; dx = 0; dy = 0; accum = 0; fired = false; lastWasPage = false }
        let ending = e.phase == .ended || e.phase == .cancelled
        switch state {
        case .idle, .vertical:
            forward(e)
        case .deciding:
            buffer.append(e)
            dx += e.scrollingDeltaX; dy += e.scrollingDeltaY
            if let axis = SwipeAxis.decide(dx: dx, dy: dy) {
                if axis == .horizontal { state = .horizontal; lastWasPage = true; page(by: dx, e); buffer = [] }
                else { state = .vertical; flush() }
            } else if ending { flush() }   // too small to mean anything: let the feed have it
        case .horizontal:
            page(by: e.scrollingDeltaX, e)
        }
        if ending { state = .idle; buffer = [] }
    }

    /// Hands the held-back events to the feed, in order.
    private func flush() {
        let held = buffer
        buffer = []
        for h in held { forward(h) }
    }

    private func page(by delta: CGFloat, _ e: NSEvent) {
        // finger direction: with natural scrolling the deltas already follow the fingers
        accum += e.isDirectionInvertedFromDevice ? delta : -delta
        if !fired, abs(accum) > 40 {
            fired = true
            // fingers moving left = next page (like Photos); nothing to flip → the feed scrolls
            if onSwipe?(accum < 0) == false { state = .vertical; lastWasPage = false }
        }
    }
}

/// A feed card: a lighter surface with a hairline edge, so cards stand apart from the feed
/// background in light and dark mode (the system control and window colors are nearly equal).
final class MacCardView: NSView {
    static func dynamic(light: CGFloat, dark: CGFloat) -> NSColor {
        NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: dark, alpha: 1) : NSColor(white: light, alpha: 1) }
    }
    static let feedBackground = dynamic(light: 0.90, dark: 0.07)
    static let fill = dynamic(light: 1.0, dark: 0.16)
    static let mediaFill = dynamic(light: 0.95, dark: 0.11)
    static let edge = NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 1, alpha: 0.10) : NSColor(white: 0, alpha: 0.10) }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 18
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 1
    }
    required init?(coder: NSCoder) { fatalError() }
    override var wantsUpdateLayer: Bool { true }
    // resolved here, so a light/dark switch recolors cards (a cgColor set once would not)
    override func updateLayer() {
        layer?.backgroundColor = Self.fill.cgColor
        layer?.borderColor = Self.edge.cgColor
    }
}

/// A one-line row that scrolls sideways (trackpad, or Shift + mouse wheel) when its content is
/// wider than the row. Vertical scrolling passes through to the feed, so the row never traps it.
final class MacHScroll: NSScrollView {
    let strip = TagStripView()
    private var passing = false

    init() {
        super.init(frame: .zero)
        drawsBackground = false
        hasHorizontalScroller = false
        hasVerticalScroller = false
        verticalScrollElasticity = .none
        horizontalScrollElasticity = .allowed
        documentView = strip
        strip.onResize = { [weak self] in self?.tile() }
    }
    required init?(coder: NSCoder) { fatalError() }

    /// The strip is as wide as its pills (sized by hand: no constraints to solve while scrolling).
    override func tile() {
        super.tile()
        let f = NSRect(x: 0, y: 0, width: max(strip.contentWidth, contentView.bounds.width), height: contentView.bounds.height)
        if strip.frame != f { strip.frame = f }
    }

    func scrollToStart() {
        contentView.scroll(to: .zero)
        reflectScrolledClipView(contentView)
    }

    override func scrollWheel(with e: NSEvent) {
        // decide once per gesture (and per wheel click): mostly vertical → the feed scrolls
        if e.phase == .began || e.phase == .mayBegin || (e.phase.isEmpty && e.momentumPhase.isEmpty) {
            passing = abs(e.scrollingDeltaY) >= abs(e.scrollingDeltaX) || strip.frame.width <= contentView.bounds.width + 0.5
        }
        if passing { (superview?.enclosingScrollView ?? nextResponder)?.scrollWheel(with: e); return }
        // moved by hand: a scroll view without a horizontal scroller ignores sideways scrolling
        let maxX = max(0, strip.frame.width - contentView.bounds.width)
        let dx = e.hasPreciseScrollingDeltas ? e.scrollingDeltaX : e.scrollingDeltaX * 10
        let x = min(maxX, max(0, contentView.bounds.origin.x - dx))
        contentView.scroll(to: NSPoint(x: x, y: 0))
        reflectScrolledClipView(contentView)
    }
}

/// The tags of a card, drawn as pills by one view: no subviews, layers or constraints, so a card
/// coming on screen costs a few text measurements instead of a dozen buttons to lay out (that
/// was most of the time per frame while scrolling fast). Click a pill to search for the tag,
/// right-click for its menu, "+" to add a tag.
final class TagStripView: NSView, NSViewToolTipOwner {
    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        pills.first { $0.rect.contains(point) }.flatMap(Self.tip) ?? ""
    }

    var onTag: ((String) -> Void)?
    var onRecent: (() -> Void)?
    var onAdd: ((NSView, NSRect) -> Void)?
    var menuForTag: ((TagView) -> NSMenu?)?
    var onResize: (() -> Void)?
    /// Room before the first and after the last pill (the card's margin).
    var sideInset: CGFloat = 0

    private enum Kind { case recent, tag(TagView), add }
    private struct Pill { let kind: Kind; let text: NSAttributedString?; var rect: NSRect }
    private var pills: [Pill] = []
    private(set) var contentWidth: CGFloat = 0
    var count: Int { pills.count }
    private static let height: CGFloat = 20, gap: CGFloat = 5, pad: CGFloat = 7
    private static let font = NSFont.systemFont(ofSize: 12, weight: .medium)
    private static let boldFont = NSFont.systemFont(ofSize: 12, weight: .bold)

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    func set(_ tags: [TagView], recent: Bool, highlight: [String] = []) {
        var list: [Pill] = []
        if recent { list.append(Pill(kind: .recent, text: NSAttributedString(string: "◷ 最近添加", attributes: [.font: Self.boldFont, .foregroundColor: NSColor.white]), rect: .zero)) }
        for t in tags {
            let prefix = t.isAI ? (t.isUser ? "✓ " : "✦ ") : ""
            let text = NSMutableAttributedString(string: prefix + t.label, attributes: [.font: Self.font, .foregroundColor: NSColor.tagColor(t)])
            SearchHighlight.apply(highlight, to: text, FeedCard.highlightAttrs)
            list.append(Pill(kind: .tag(t), text: text, rect: .zero))
        }
        list.append(Pill(kind: .add, text: nil, rect: .zero))
        var x: CGFloat = sideInset
        for i in list.indices {
            let w = list[i].text.map { ceil($0.size().width) + Self.pad * 2 } ?? 24
            list[i].rect = NSRect(x: x, y: 0, width: w, height: Self.height)
            x += w + Self.gap
        }
        pills = list
        contentWidth = max(0, x - Self.gap + sideInset)
        // The strip itself owns its tooltips: AppKit does not retain a tooltip's owner, and a
        // temporary string as owner was freed before the tooltip showed (a crash).
        removeAllToolTips()
        for p in pills where Self.tip(for: p) != nil { addToolTip(p.rect, owner: self, userData: nil) }
        needsDisplay = true
        onResize?()
    }

    private static func tip(for p: Pill) -> String? {
        switch p.kind {
        case .tag(let t) where !t.models.isEmpty: return "AI：" + t.models.map { ModelStore.shared.displayName($0) }.joined(separator: "、")
        case .recent: return "批量下载的帖子，5 天后自动消失。点一下只看最近添加"
        case .add: return "添加标签"
        default: return nil
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        for p in pills where p.rect.intersects(dirtyRect) {
            let bg: NSColor
            switch p.kind {
            case .recent: bg = .systemOrange
            case .tag(let t): bg = NSColor.tagColor(t).withAlphaComponent(0.16)
            case .add: bg = NSColor.secondaryLabelColor.withAlphaComponent(0.12)
            }
            bg.setFill()
            NSBezierPath(roundedRect: p.rect, xRadius: 10, yRadius: 10).fill()
            if let text = p.text {
                let size = text.size()
                text.draw(at: NSPoint(x: p.rect.minX + Self.pad, y: p.rect.midY - size.height / 2))
            } else {
                let z = Self.plus.size
                Self.plus.draw(in: NSRect(x: p.rect.midX - z.width / 2, y: p.rect.midY - z.height / 2, width: z.width, height: z.height))
            }
        }
    }

    /// "+" in the secondary label color (a palette color resolves when drawn, so it follows light/dark mode).
    private static let plus: NSImage = NSImage(systemSymbolName: "plus", accessibilityDescription: "添加标签")?
        .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .bold).applying(.init(paletteColors: [.secondaryLabelColor]))) ?? NSImage()

    private func pill(at event: NSEvent) -> Pill? {
        let p = convert(event.locationInWindow, from: nil)
        return pills.first { $0.rect.contains(p) }
    }

    // a click on a pill is a click on it; elsewhere it is the card's
    override func hitTest(_ point: NSPoint) -> NSView? {
        let p = convert(point, from: superview)
        return pills.contains { $0.rect.contains(p) } ? self : nil
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        guard let p = pill(at: event) else { return }
        switch p.kind {
        case .recent: onRecent?()
        case .tag(let t): onTag?(t.label)
        case .add: onAdd?(self, p.rect)
        }
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        if case .tag(let t)? = pill(at: event)?.kind { return menuForTag?(t) }
        return nil
    }

    // VoiceOver: each pill is a button
    override func isAccessibilityElement() -> Bool { false }
    override func accessibilityChildren() -> [Any]? {
        pills.map { p in
            let e = NSAccessibilityElement()
            e.setAccessibilityParent(self)
            e.setAccessibilityRole(.button)
            e.setAccessibilityFrameInParentSpace(p.rect)
            switch p.kind {
            case .recent: e.setAccessibilityLabel("最近添加"); e.setAccessibilityIdentifier("recentBadge")
            case .tag(let t): e.setAccessibilityLabel(t.label); e.setAccessibilityIdentifier(t.label)
            case .add: e.setAccessibilityLabel("添加标签"); e.setAccessibilityIdentifier("addTag")
            }
            return e
        }
    }
}

/// Shows a picture as its layer's contents, scaled by the GPU. An NSImageView redraws (and
/// rescales) its image on the main thread whenever a card appears, which during a fast scroll
/// took more time per frame than everything else together.
final class ImageLayerView: NSView {
    var image: NSImage? {
        didSet { layer?.contents = image?.cgImage(forProposedRect: nil, context: nil, hints: nil) }
    }
    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        layer?.contentsGravity = .resizeAspect
    }
    required init?(coder: NSCoder) { fatalError() }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {}
}
