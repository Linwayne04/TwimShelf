import UIKit

/// Triage mode: one post at a time (a multi-media post as one group, a loose media alone).
/// Swipe up = keep · left = delete the whole post (to the bin). Folders: one tap in the folder bar
/// (as photo-sorting apps' album bar); dragging never files into a folder.
/// Decisions are stored on this device only; a triaged post never comes back unless the triage
/// history is cleared (Settings).
final class TriageViewController: UIViewController {
    private var queue: [Core.TriageUnit] = []
    /// Decided units, newest last, with the direction their card left (undo brings it back from there).
    private var undoStack: [(unit: Core.TriageUnit, dir: TriageCard.Direction)] = []
    private var filter = Core.TriageFilter.saved
    private var card: TriageCard?
    private let countLabel = UILabel()
    private let emptyLabel = UILabel()
    private let toast = ToastView()
    private let folderBar = TriageFolderBar()
    /// Enabled only while there is something to undo.
    private var undoButton: UIButton!
    private var observer: NSObjectProtocol?
    private var loading = false
    private var reloadGeneration = 0
    private var rng = SystemRandomNumberGenerator()

    override func viewDidLoad() {
        super.viewDidLoad()
        // a plain background: the home page's animated backdrop made the buttons hard to read
        view.backgroundColor = .systemBackground
        view.accessibilityIdentifier = "triage"

        let title = UILabel()
        title.text = "整理模式"
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        countLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        countLabel.textColor = .secondaryLabel
        countLabel.accessibilityIdentifier = "triageCount"
        let exit = UIButton(configuration: .plain(), primaryAction: UIAction(title: "退出整理") { _ in LibraryPrefs.triageMode = false })
        exit.accessibilityIdentifier = "triageExit"
        let head = UIStackView(arrangedSubviews: [UIStackView(arrangedSubviews: [title, countLabel]), UIView(), exit])
        (head.arrangedSubviews[0] as! UIStackView).axis = .vertical
        head.alignment = .center

        emptyLabel.numberOfLines = 0
        emptyLabel.textAlignment = .center
        emptyLabel.textColor = .secondaryLabel
        emptyLabel.font = .preferredFont(forTextStyle: .body)
        emptyLabel.isHidden = true

        // Glass buttons (iOS 26): the symbol carries the colour, the title stays in the label
        // colour, so no button looks greyed out unless it really is unavailable.
        func button(_ title: String, _ symbol: String, _ color: UIColor, _ id: String, _ action: @escaping () -> Void) -> UIButton {
            var c: UIButton.Configuration
            if #available(iOS 26.0, *) { c = .glass() } else { c = .gray(); c.cornerStyle = .large }
            c.title = title
            // the colour is part of the symbol image (glass buttons tint images with the title colour)
            c.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold))?
                .withTintColor(color, renderingMode: .alwaysOriginal)
            c.baseForegroundColor = .label
            c.imagePlacement = .top
            c.imagePadding = 5
            let b = UIButton(configuration: c, primaryAction: UIAction { _ in action() })
            // disabled (撤销 with nothing to undo): the symbol greys out with the title
            let symbolImage = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold))
            b.configurationUpdateHandler = { b in
                guard var c = b.configuration else { return }
                c.image = symbolImage?.withTintColor(b.isEnabled ? color : .tertiaryLabel, renderingMode: .alwaysOriginal)
                b.configuration = c
            }
            b.accessibilityIdentifier = id
            return b
        }
        undoButton = button("撤销", "arrow.uturn.backward", .systemBlue, "triageUndo") { [weak self] in self?.undo() }
        undoButton.isEnabled = false
        let actions = UIStackView(arrangedSubviews: [
            undoButton,
            button("删除", "arrow.left", .systemRed, "triageDelete") { [weak self] in self?.decide(.delete) },
            button("保留", "arrow.up", .systemGreen, "triageKeep") { [weak self] in self?.decide(.keep) },
            button("筛选", "line.3.horizontal.decrease.circle", .systemIndigo, "triageFilter") { [weak self] in self?.openFilter() },
        ])
        actions.distribution = .fillEqually
        actions.spacing = 8

        folderBar.onPick = { [weak self] name in self?.file(into: name) }
        folderBar.onNew = { [weak self] in self?.newFolder() }
        folderBar.set(TriageFolders.ordered())
        [head, emptyLabel, folderBar, actions, toast].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; view.addSubview($0) }
        let g = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            head.topAnchor.constraint(equalTo: g.topAnchor, constant: 8),
            head.leadingAnchor.constraint(equalTo: g.leadingAnchor, constant: 20), head.trailingAnchor.constraint(equalTo: g.trailingAnchor, constant: -20),
            actions.leadingAnchor.constraint(equalTo: g.leadingAnchor, constant: 14), actions.trailingAnchor.constraint(equalTo: g.trailingAnchor, constant: -14),
            actions.bottomAnchor.constraint(equalTo: g.bottomAnchor, constant: -8), actions.heightAnchor.constraint(equalToConstant: 62),
            // the folder bar: always there, always this high, right above the buttons
            folderBar.leadingAnchor.constraint(equalTo: view.leadingAnchor), folderBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            folderBar.bottomAnchor.constraint(equalTo: actions.topAnchor, constant: -8), folderBar.heightAnchor.constraint(equalToConstant: 40),
            emptyLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor), emptyLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            emptyLabel.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, constant: -60),
            toast.centerXAnchor.constraint(equalTo: view.centerXAnchor), toast.bottomAnchor.constraint(equalTo: folderBar.topAnchor, constant: -10),
            toast.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, constant: -32),
        ])
        cardTop = head.bottomAnchor
        cardBottom = folderBar.topAnchor
        // New media (import, sync, download) join the queue; removed ones drop out.
        observer = NotificationCenter.default.addObserver(forName: .libraryChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload(keepCurrent: true) }
        }
        reload(keepCurrent: false)
    }
    deinit { observer.map(NotificationCenter.default.removeObserver) }

    private var cardTop: NSLayoutYAxisAnchor!
    private var cardBottom: NSLayoutYAxisAnchor!

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
                // keep the existing order, drop what is gone, add new ones at random places
                var q = self.queue.filter { freshIds.contains($0.postId) }
                for u in fresh where !known.contains(u.postId) { q.insert(u, at: Int.random(in: 0...q.count, using: &self.rng)) }
                if let c = current, let i = q.firstIndex(where: { $0.postId == c }), i != 0 { q.insert(q.remove(at: i), at: 0) }
                // refresh the media lists (posts may have gained or lost media)
                let byId = Dictionary(fresh.map { ($0.postId, $0) }, uniquingKeysWith: { a, _ in a })
                self.queue = q.compactMap { byId[$0.postId] }
                if !keepCurrent { self.queue.shuffle(using: &self.rng) }
                // folders renamed, deleted or made elsewhere: the bar follows (rebuilt only then)
                let names = TriageFolders.refreshed(self.folderBar.names)
                if names != self.folderBar.names { self.folderBar.set(names) }
                self.showTop(animatedFrom: nil)
            }
        }
    }

    private func updateCount() {
        countLabel.text = queue.isEmpty ? "没有要整理的内容" : "剩余 \(queue.count) 个" + (filter.isEmpty ? "" : " · 已筛选")
        if loading { countLabel.text = "正在更新内容…" }
        else if let u = queue.first, u.pendingCount > 0 { countLabel.text = (countLabel.text ?? "") + " · 含 \(u.pendingCount) 个待下载媒体" }
    }

    /// Shows the first unit of the queue. `arriving`: the card comes back in from that side (undo);
    /// otherwise it appears under whatever is still flying away.
    private func showTop(animatedFrom: CGPoint?, arriving: TriageCard.Direction? = nil) {
        updateCount()
        if let top = queue.first, card?.unit.postId == top.postId, card?.unit == top { return }
        let previous = card
        card = nil
        if arriving == nil { previous?.removeFromSuperview() }
        guard let top = queue.first else {
            previous?.removeFromSuperview()
            emptyLabel.text = filter.isEmpty ? "全部整理完了\n\n整理过的内容不会再出现。需要重新整理时，可以在设置里清空整理记录。" : "这个筛选范围里已经整理完了\n点右下角「筛选」换一个范围"
            emptyLabel.isHidden = false
            return
        }
        emptyLabel.isHidden = true
        let c = TriageCard(unit: top)
        c.onSwipe = { [weak self] dir in
            // dragging only keeps or deletes; folders are tapped in the bar
            switch dir { case .up: self?.decide(.keep); case .left: self?.decide(.delete); case .down: break }
        }
        c.onOpen = { [weak self] item in self?.open(item) }
        c.translatesAutoresizingMaskIntoConstraints = false
        view.insertSubview(c, belowSubview: toast)
        NSLayoutConstraint.activate([
            c.topAnchor.constraint(equalTo: cardTop, constant: 10), c.bottomAnchor.constraint(equalTo: cardBottom, constant: -10),
            c.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 20),
            c.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20),
        ])
        card = c
        if let d = arriving {
            // undo: the card comes back from where it left, over the one that was showing
            view.layoutIfNeeded()
            c.transform = TriageCard.offscreen(d)
            c.alpha = 0
            UIView.animate(withDuration: 0.38, delay: 0, usingSpringWithDamping: 0.82, initialSpringVelocity: 0.3, animations: { c.alpha = 1; c.transform = .identity }) { _ in previous?.removeFromSuperview() }
        } else {
            c.alpha = 0
            c.transform = CGAffineTransform(scaleX: 0.94, y: 0.94)
            UIView.animate(withDuration: 0.25, delay: 0, usingSpringWithDamping: 0.85, initialSpringVelocity: 0.4) { c.alpha = 1; c.transform = .identity }
        }
        // warm up the next card's image
        if queue.count > 1, let n = queue[1].items.first { MediaLoader.shared.load(n, maxPixel: MediaPageView.pixelSize * 1.5) { _ in } }
    }

    // MARK: Decisions

    private func decide(_ d: Core.TriageDecision, folder: String? = nil) {
        guard !loading, let unit = queue.first, let c = card, c.unit == unit else { toast.show("正在更新内容，请稍候"); return }
        let applied: Bool
        do { applied = try Core.triageDecide(unit.postId, d, folder: folder, expected: unit.mediaIds) }
        catch { toast.show(error.localizedDescription); reload(keepCurrent: true); return }
        let dir: TriageCard.Direction = d == .keep ? .up : (d == .delete ? .left : .down)
        c.flyAway(dir) { c.removeFromSuperview() }
        card = nil
        queue.removeFirst()
        if applied {
            undoStack.append((unit, dir))
            undoButton.isEnabled = true
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            let what = d == .keep ? "已保留" : (d == .delete ? "已移到回收站" : "已放入「\(folder ?? "")」")
            toast.show(what, action: "撤销") { [weak self] in self?.undo() }
            if d != .keep { notifyLibrary() }
        } else {
            toast.show("这条已经不在或已整理过，跳过")
        }
        showTop(animatedFrom: nil)
        // the card that was acted on stays on top while it flies away; the next one appears under it
        if c.superview != nil { view.insertSubview(c, belowSubview: toast) }
    }

    /// Tells the rest of the app about the change without reloading our own queue mid-swipe.
    private func notifyLibrary() {
        if let o = observer { NotificationCenter.default.removeObserver(o) }
        NotificationCenter.default.post(name: .libraryChanged, object: nil)
        observer = NotificationCenter.default.addObserver(forName: .libraryChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload(keepCurrent: true) }
        }
    }

    private func undo() {
        guard let last = undoStack.popLast() else { toast.show("没有可以撤销的整理"); return }
        undoButton.isEnabled = !undoStack.isEmpty
        guard (try? Core.triageUndo(last.unit.postId)) == true else { toast.show("无法撤销：这条整理记录已经不在了"); return }
        queue.removeAll { $0.postId == last.unit.postId }
        queue.insert(last.unit, at: 0)
        showTop(animatedFrom: nil, arriving: last.dir)
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        toast.show("已撤销")
        notifyLibrary()
        // the post may have changed meanwhile (media restored from the bin): refresh, keeping it first
        reload(keepCurrent: true)
    }

    /// Files the whole post into a folder of the bar (nil: there is none yet, make one).
    private func file(into name: String?) {
        guard card != nil else { return }
        guard let name else { newFolder(); return }
        TriageFolders.used(name)
        decide(.folder, folder: name)
    }

    /// A new folder (centred alert): created, the post filed into it, and it joins the bar at the end.
    private func newFolder() {
        guard card != nil else { return }
        card?.resetPosition()
        let n = UIAlertController(title: "新建文件夹", message: "这个帖子（所有媒体）会放进去，并算作已整理。", preferredStyle: .alert)
        n.addTextField { $0.placeholder = "文件夹名称" }
        n.addAction(UIAlertAction(title: "取消", style: .cancel))
        n.addAction(UIAlertAction(title: "创建并放入", style: .default) { [weak self] _ in
            let name = (n.textFields?.first?.text ?? "").trimmingCharacters(in: .whitespaces)
            guard let self, !name.isEmpty else { return }
            self.file(into: name)
            self.folderBar.set(TriageFolders.refreshed(self.folderBar.names))
        })
        present(n, animated: true)
    }

    private func open(_ item: FeedItem) {
        let group = queue.first?.items ?? [item]
        let vc = PhotoViewController(items: group, index: group.firstIndex { $0.mediaId == item.mediaId } ?? 0)
        vc.modalPresentationStyle = .fullScreen
        present(vc, animated: true)
    }

    private func openFilter() {
        let vc = TriageFilterViewController(filter: filter) { [weak self] f in
            self?.filter = f
            Core.TriageFilter.saved = f
            self?.queue = []
            self?.card?.removeFromSuperview(); self?.card = nil
            self?.reload(keepCurrent: false)
        }
        let nav = UINavigationController(rootViewController: vc)
        nav.sheetPresentationController?.detents = [.medium(), .large()]
        present(nav, animated: true)
    }
}

/// One post (or loose media) to decide: the picture, the small pictures of the post's other media,
/// and its text, on the page's own background. The picture floats with a soft shadow and hugs the
/// media (no box around it); the strip and the text sit at the foot of the card, so they never
/// move with the picture's shape. Drag to decide; the stamp shows what letting go will do.
final class TriageCard: UIView {
    enum Direction { case up, left, down }
    let unit: Core.TriageUnit
    var onSwipe: ((Direction) -> Void)?
    var onOpen: ((FeedItem) -> Void)?
    private let holder = UIView()
    private let image = UIImageView()
    private let play = UIImageView(image: UIImage(systemName: "play.fill"))
    private let stamp = PaddedLabel()
    private let who = UILabel()
    private let words = UILabel()
    private let stripScroll = UIScrollView()
    private var page = 0
    private var thumbs: [UIButton] = []
    private static let captionHeight: CGFloat = 62
    private static let stripHeight: CGFloat = 44

    init(unit: Core.TriageUnit) {
        self.unit = unit
        super.init(frame: .zero)
        backgroundColor = .clear
        isAccessibilityElement = false
        accessibilityIdentifier = "triageCard"

        holder.layer.shadowColor = UIColor.black.cgColor
        holder.layer.shadowOpacity = 0.16
        holder.layer.shadowRadius = 14
        holder.layer.shadowOffset = CGSize(width: 0, height: 5)
        image.contentMode = .scaleToFill       // the frame already has the media's shape
        image.backgroundColor = .tertiarySystemFill
        image.clipsToBounds = true
        image.layer.cornerRadius = 14
        image.layer.cornerCurve = .continuous
        image.isUserInteractionEnabled = true
        image.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
        image.accessibilityIdentifier = "triageMedia"
        image.isAccessibilityElement = true
        play.tintColor = .white
        play.contentMode = .center
        play.preferredSymbolConfiguration = .init(pointSize: 20, weight: .semibold)
        play.backgroundColor = UIColor.black.withAlphaComponent(0.45)
        play.layer.cornerRadius = 25
        play.clipsToBounds = true

        let first = unit.items[0]
        who.font = .systemFont(ofSize: UIFont.preferredFont(forTextStyle: .subheadline).pointSize, weight: .semibold)
        who.textColor = .label
        words.font = .preferredFont(forTextStyle: .subheadline)
        words.textColor = .secondaryLabel
        words.numberOfLines = 2
        if first.isLoose {
            who.text = "散装媒体"
            words.text = "不属于任何帖子，每个文件单独整理"
        } else {
            who.text = [first.authorName, first.screenName.map { "@\($0)" }].compactMap { $0 }.joined(separator: "  ")
            words.text = first.text
        }
        let strip = UIStackView()
        strip.spacing = 8
        if unit.items.count > 1 {
            for (i, it) in unit.items.enumerated() {
                let b = UIButton(type: .custom)
                b.imageView?.contentMode = .scaleAspectFill
                b.clipsToBounds = true
                b.layer.cornerRadius = 8
                b.layer.cornerCurve = .continuous
                b.layer.borderColor = UIColor.tintColor.cgColor
                b.backgroundColor = .tertiarySystemFill
                b.widthAnchor.constraint(equalToConstant: Self.stripHeight).isActive = true
                b.heightAnchor.constraint(equalToConstant: Self.stripHeight).isActive = true
                b.addAction(UIAction { [weak self] _ in self?.show(i) }, for: .touchUpInside)
                b.accessibilityLabel = "第 \(i + 1) 个媒体"
                MediaLoader.shared.load(it, maxPixel: 140) { [weak b] img in b?.setImage(img, for: .normal) }
                thumbs.append(b)
                strip.addArrangedSubview(b)
            }
        }
        stripScroll.showsHorizontalScrollIndicator = false
        stripScroll.addSubview(strip)
        strip.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            strip.topAnchor.constraint(equalTo: stripScroll.contentLayoutGuide.topAnchor), strip.bottomAnchor.constraint(equalTo: stripScroll.contentLayoutGuide.bottomAnchor),
            strip.leadingAnchor.constraint(equalTo: stripScroll.contentLayoutGuide.leadingAnchor), strip.trailingAnchor.constraint(equalTo: stripScroll.contentLayoutGuide.trailingAnchor),
            strip.heightAnchor.constraint(equalTo: stripScroll.frameLayoutGuide.heightAnchor),
        ])

        stamp.font = .systemFont(ofSize: 22, weight: .bold)
        stamp.textColor = .white
        stamp.layer.cornerRadius = 10
        stamp.layer.cornerCurve = .continuous
        stamp.clipsToBounds = true
        stamp.alpha = 0
        stamp.insets = UIEdgeInsets(top: 5, left: 12, bottom: 5, right: 12)

        addSubview(holder)
        holder.addSubview(image)
        for v in [play, stamp] { v.translatesAutoresizingMaskIntoConstraints = false; image.addSubview(v) }
        [stripScroll, who, words].forEach { addSubview($0) }
        NSLayoutConstraint.activate([
            play.centerXAnchor.constraint(equalTo: image.centerXAnchor), play.centerYAnchor.constraint(equalTo: image.centerYAnchor),
            play.widthAnchor.constraint(equalToConstant: 50), play.heightAnchor.constraint(equalToConstant: 50),
            stamp.centerXAnchor.constraint(equalTo: image.centerXAnchor), stamp.topAnchor.constraint(equalTo: image.topAnchor, constant: 22),
        ])
        addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(pan(_:))))
        show(0)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// The picture takes the room above the strip and the text, in the shape of the media.
    override func layoutSubviews() {
        super.layoutSubviews()
        let multi = unit.items.count > 1
        let below = Self.captionHeight + 12 + (multi ? Self.stripHeight + 12 : 0)
        let room = CGRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - below))
        guard room.width > 0, room.height > 0 else { return }
        let a: CGFloat = { guard let s = image.image?.size, s.width > 0, s.height > 0 else { return 0.75 }; return s.width / s.height }()
        var w = room.width, h = room.width / a
        if h > room.height { h = room.height; w = h * a }
        // the picture, the strip and the text are one block, centred in the card: the text stays
        // right under the picture whatever its shape (the buttons below the card never move)
        let block = h + 12 + (multi ? Self.stripHeight + 12 : 0) + Self.captionHeight
        let top = max(0, ((bounds.height - block) / 2).rounded())
        let frame = CGRect(x: (room.midX - w / 2).rounded(), y: top, width: w.rounded(), height: h.rounded())
        holder.frame = frame
        image.frame = holder.bounds
        holder.layer.shadowPath = UIBezierPath(roundedRect: holder.bounds, cornerRadius: 14).cgPath
        var y = frame.maxY + 12
        if multi {
            stripScroll.frame = CGRect(x: 0, y: y, width: bounds.width, height: Self.stripHeight)
            // centred while it fits
            let inset = max(0, (bounds.width - stripScroll.contentSize.width) / 2)
            stripScroll.contentInset = UIEdgeInsets(top: 0, left: inset, bottom: 0, right: inset)
            y = stripScroll.frame.maxY + 12
        }
        let textX = max(0, min(frame.minX, bounds.width - 280))
        let textW = bounds.width - 2 * textX
        who.frame = CGRect(x: textX, y: y, width: textW, height: who.font.lineHeight.rounded(.up))
        words.frame = CGRect(x: textX, y: who.frame.maxY + 2, width: textW, height: Self.captionHeight - who.frame.height - 2)
        words.sizeToFit()
        words.frame.size.width = textW
        words.frame.size.height = min(words.frame.height, Self.captionHeight - who.frame.height - 2)
    }

    private func show(_ i: Int) {
        page = i
        let it = unit.items[i]
        play.isHidden = it.kind != .video
        image.accessibilityLabel = (it.kind == .video ? "视频" : "照片") + (unit.items.count > 1 ? "，第 \(i + 1)/\(unit.items.count) 个" : "")
        for (k, b) in thumbs.enumerated() { b.layer.borderWidth = k == i ? 2.5 : 0; b.alpha = k == i ? 1 : 0.65 }
        image.image = MediaLoader.shared.cached(it, maxPixel: MediaPageView.pixelSize * 1.5)
        setNeedsLayout()
        MediaLoader.shared.load(it, maxPixel: MediaPageView.pixelSize * 1.5) { [weak self] img in
            guard self?.page == i else { return }
            self?.image.image = img
            self?.setNeedsLayout()
        }
    }

    @objc private func tapped() { onOpen?(unit.items[page]) }

    private func direction(_ t: CGPoint) -> Direction? {
        if -t.y > 110 && abs(t.x) < abs(t.y) { return .up }
        if -t.x > 110 && abs(t.x) > abs(t.y) { return .left }
        return nil
    }

    @objc private func pan(_ g: UIPanGestureRecognizer) {
        let t = g.translation(in: superview)
        switch g.state {
        case .changed:
            transform = CGAffineTransform(translationX: t.x, y: t.y).rotated(by: t.x / 900)
            let d = direction(t)
            stamp.text = d == .up ? "保留" : (d == .left ? "删除" : nil)
            stamp.backgroundColor = d == .up ? .systemGreen : (d == .left ? .systemRed : .systemTeal)
            stamp.alpha = d == nil ? 0 : 0.95
        case .ended, .cancelled:
            if let d = direction(t), g.state == .ended { stamp.alpha = 0; onSwipe?(d) } else { resetPosition() }
        default: break
        }
    }

    func resetPosition() {
        UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.75, initialSpringVelocity: 0.5) { self.transform = .identity; self.stamp.alpha = 0 }
    }

    /// Where a card goes when it leaves in a direction (and comes back from on undo).
    static func offscreen(_ d: Direction) -> CGAffineTransform {
        switch d {
        case .up: CGAffineTransform(translationX: 0, y: -900)
        case .left: CGAffineTransform(translationX: -900, y: 40).rotated(by: -0.3)
        case .down: CGAffineTransform(translationX: 0, y: 900).scaledBy(x: 0.6, y: 0.6)
        }
    }

    func flyAway(_ d: Direction, done: @escaping () -> Void) {
        isUserInteractionEnabled = false
        UIView.animate(withDuration: 0.28, delay: 0, options: .curveEaseIn, animations: { self.transform = Self.offscreen(d); self.alpha = 0 }) { _ in done() }
    }
}

/// What to triage: folders, tags, posts vs loose media, photos vs videos.
final class TriageFilterViewController: FormViewController {
    private var filter: Core.TriageFilter
    private let done: (Core.TriageFilter) -> Void
    private let kind = UISegmentedControl(items: ["全部", "帖子", "散装媒体"])
    private let media = UISegmentedControl(items: ["全部", "照片", "视频"])

    init(filter: Core.TriageFilter, done: @escaping (Core.TriageFilter) -> Void) { self.filter = filter; self.done = done; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "整理范围"
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in
            guard let self else { return }
            self.done(self.filter); self.dismiss(animated: true) })
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: "全部重置", primaryAction: UIAction { [weak self] _ in
            self?.filter = Core.TriageFilter(); self?.build() })
        kind.addAction(UIAction { [weak self] _ in guard let self else { return }; self.filter.kind = [.all, .posts, .loose][self.kind.selectedSegmentIndex] }, for: .valueChanged)
        media.addAction(UIAction { [weak self] _ in guard let self else { return }; self.filter.media = [.all, .photo, .video][self.media.selectedSegmentIndex] }, for: .valueChanged)
        build()
    }

    private func build() {
        kind.selectedSegmentIndex = [Core.TriageFilter.Kind.all, .posts, .loose].firstIndex(of: filter.kind) ?? 0
        media.selectedSegmentIndex = [Core.TriageFilter.Media.all, .photo, .video].firstIndex(of: filter.media) ?? 0
        let folders = Core.folders()
        let tags = Core.allTags().prefix(300)
        sections = [
            Section(id: "kind", header: "类型", rows: [.custom("kind", kind), .custom("media", media),
                .toggle("只看最近添加", filter.recentOnly, icon: .init("clock.badge.checkmark", .systemOrange), id: "recent") { [weak self] on in self?.filter.recentOnly = on }]),
            Section(id: "folders", header: "文件夹", footer: "都不选＝不限；选了就只整理其中任一文件夹里的内容。", rows: folders.isEmpty ? [.value("还没有文件夹", nil)] : folders.map { f in
                .toggle("\(f.name)（\(f.count)）", filter.folders.contains(f.name), icon: .init("folder", .systemTeal), id: "f:" + f.name) { [weak self] on in
                    if on { self?.filter.folders.append(f.name) } else { self?.filter.folders.removeAll { $0 == f.name } }
                }
            }),
            Section(id: "tags", header: "标签", footer: "都不选＝不限；选了就只整理带有其中任一标签的内容。", rows: tags.isEmpty ? [.value("还没有标签", nil)] : tags.map { t in
                .toggle("\(t.label)（\(t.count)）", filter.labels.contains(t.label), icon: .init("tag", .systemBlue), id: "t:" + t.label) { [weak self] on in
                    if on { self?.filter.labels.append(t.label) } else { self?.filter.labels.removeAll { $0 == t.label } }
                }
            }),
        ]
        reloadForm()
    }
}

/// The folders above the buttons, after a "放入" label: one tap files the post into that folder.
/// Scrolls sideways when there are many; its height never changes.
final class TriageFolderBar: UIView {
    var onPick: ((String) -> Void)?
    var onNew: (() -> Void)?
    private(set) var names: [String] = []
    private let scroll = UIScrollView()
    private let row = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        scroll.showsHorizontalScrollIndicator = false
        scroll.alwaysBounceHorizontal = true
        scroll.contentInset = UIEdgeInsets(top: 0, left: 14, bottom: 0, right: 14)
        row.axis = .horizontal
        row.spacing = 8
        row.alignment = .center
        [scroll, row].forEach { $0.translatesAutoresizingMaskIntoConstraints = false }
        addSubview(scroll)
        scroll.addSubview(row)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor), scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor), scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor), row.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            row.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor), row.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            row.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
        ])
        accessibilityIdentifier = "triageFolderBar"
    }
    required init?(coder: NSCoder) { fatalError() }

    func set(_ list: [String]) {
        names = list
        row.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let lead = UILabel()
        lead.text = "放入"
        lead.font = .systemFont(ofSize: 15, weight: .semibold)
        lead.textColor = .secondaryLabel
        lead.isAccessibilityElement = false
        row.addArrangedSubview(lead)
        for n in list {
            var c: UIButton.Configuration
            if #available(iOS 26.0, *) { c = .glass() } else { c = .gray() }
            c.title = n
            c.image = UIImage(systemName: "folder")
            c.imagePadding = 5
            c.cornerStyle = .capsule
            c.buttonSize = .medium
            c.titleLineBreakMode = .byTruncatingTail
            let b = UIButton(configuration: c, primaryAction: UIAction { [weak self] _ in self?.onPick?(n) })
            b.accessibilityIdentifier = "triageFolder-\(n)"
            b.accessibilityLabel = "放入「\(n)」"
            b.widthAnchor.constraint(lessThanOrEqualToConstant: 220).isActive = true
            row.addArrangedSubview(b)
        }
        var c: UIButton.Configuration
        if #available(iOS 26.0, *) { c = .glass() } else { c = .tinted() }
        c.title = "新建文件夹"
        c.image = UIImage(systemName: "folder.badge.plus")
        c.imagePadding = 5
        c.cornerStyle = .capsule
        c.buttonSize = .medium
        let add = UIButton(configuration: c, primaryAction: UIAction { [weak self] _ in self?.onNew?() })
        add.accessibilityIdentifier = "triageNewFolder"
        add.accessibilityLabel = "新建文件夹并放入"
        row.addArrangedSubview(add)
    }
}
