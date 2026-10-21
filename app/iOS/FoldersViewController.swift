import UIKit

// MARK: - Tabs inside the home bar

/// The "浏览 / 文件夹" switch at the left of the home's floating bar. It looks and behaves like
/// a system tab bar (symbol over a short title, tinted when selected, a soft capsule behind the
/// selected one), but it is part of the home's own bar, next to its switch and buttons.
final class HomeTabs: UIView {
    private(set) var selectedIndex = 0
    var onChange: ((Int) -> Void)?
    private var items: [HomeTabItem] = []
    private let indicator = UIView()
    private var indicatorConstraints: [NSLayoutConstraint] = []

    init(_ tabs: [(title: String, symbol: String, id: String)]) {
        super.init(frame: .zero)
        indicator.backgroundColor = .tertiarySystemFill
        indicator.layer.cornerCurve = .continuous
        indicator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(indicator)
        let stack = UIStackView()
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        for (i, t) in tabs.enumerated() {
            let item = HomeTabItem(title: t.title, symbol: t.symbol, id: t.id)
            item.addAction(UIAction { [weak self] _ in self?.select(i, animated: true, notify: true) }, for: .touchUpInside)
            items.append(item)
            stack.addArrangedSubview(item)
        }
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        select(0, animated: false, notify: false)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        indicator.layer.cornerRadius = indicator.bounds.height / 2
    }

    func select(_ i: Int, animated: Bool, notify: Bool) {
        guard items.indices.contains(i) else { return }
        let changed = i != selectedIndex
        selectedIndex = i
        for (k, item) in items.enumerated() { item.isSelected = k == i }
        NSLayoutConstraint.deactivate(indicatorConstraints)
        let t = items[i]
        indicatorConstraints = [indicator.topAnchor.constraint(equalTo: t.topAnchor), indicator.bottomAnchor.constraint(equalTo: t.bottomAnchor),
                                indicator.leadingAnchor.constraint(equalTo: t.leadingAnchor), indicator.trailingAnchor.constraint(equalTo: t.trailingAnchor)]
        NSLayoutConstraint.activate(indicatorConstraints)
        if animated {
            UIView.animate(withDuration: 0.35, delay: 0, usingSpringWithDamping: 0.82, initialSpringVelocity: 0.4) { self.layoutIfNeeded() }
        }
        if notify && changed {
            UISelectionFeedbackGenerator().selectionChanged()
            onChange?(i)
        }
    }
}

final class HomeTabItem: UIControl {
    private let symbol: String
    private let icon = UIImageView()
    private let label = UILabel()

    init(title: String, symbol: String, id: String) {
        self.symbol = symbol
        super.init(frame: .zero)
        icon.contentMode = .scaleAspectFit
        icon.preferredSymbolConfiguration = .init(pointSize: 17, weight: .medium)
        label.text = title
        label.font = .systemFont(ofSize: 10, weight: .semibold)
        label.adjustsFontForContentSizeCategory = false
        let st = UIStackView(arrangedSubviews: [icon, label])
        st.axis = .vertical
        st.alignment = .center
        st.spacing = 2
        st.isUserInteractionEnabled = false
        st.translatesAutoresizingMaskIntoConstraints = false
        addSubview(st)
        NSLayoutConstraint.activate([
            st.centerXAnchor.constraint(equalTo: centerXAnchor), st.centerYAnchor.constraint(equalTo: centerYAnchor),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 50), widthAnchor.constraint(greaterThanOrEqualTo: st.widthAnchor, constant: 14),
            heightAnchor.constraint(equalToConstant: 44), icon.heightAnchor.constraint(equalToConstant: 22),
        ])
        isAccessibilityElement = true
        accessibilityLabel = title
        accessibilityIdentifier = id
        update()
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isSelected: Bool { didSet { update() } }
    override var isHighlighted: Bool { didSet { UIView.animate(withDuration: 0.12, delay: 0, usingSpringWithDamping: 0.86, initialSpringVelocity: 0) { self.alpha = self.isHighlighted ? 0.55 : 1 } } }

    private func update() {
        let color: UIColor = isSelected ? .tintColor : .secondaryLabel
        icon.image = UIImage(systemName: isSelected ? symbol + ".fill" : symbol) ?? UIImage(systemName: symbol)
        icon.tintColor = color
        label.textColor = color
        accessibilityTraits = isSelected ? [.button, .selected] : [.button]
    }
}

// MARK: - Folders page

/// The "文件夹" tab, laid out like the Photos app's Collections: the folders as large covers in
/// a sideways-scrolling shelf (two rows once there are more than four), the media types, and a
/// list of the other collections (recently added, loose media, unreviewed, damaged, bin).
final class FoldersViewController: UIViewController, UICollectionViewDelegate {
    enum Section: Int { case folders, kinds, more }
    enum More: String { case recent, loose, unreviewed, bad, trash }
    enum Item: Hashable {
        case folder(FolderOverview.Folder)
        case newFolder
        case empty
        case kind(MediaKind, Int)
        case more(More, String?)
    }

    /// "在浏览中查看": the home shows the timeline with this filter.
    var onShowInTimeline: ((FeedFilter) -> Void)?
    private var overview: FolderOverview?
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!
    private var observers: [NSObjectProtocol] = []
    private var loading = false

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "文件夹"
        view.backgroundColor = .systemGroupedBackground
        navigationItem.largeTitleDisplayMode = .always
        let add = UIBarButtonItem(image: UIImage(systemName: "plus"), primaryAction: UIAction { [weak self] _ in self?.createFolder() })
        add.accessibilityLabel = "新建文件夹"
        add.accessibilityIdentifier = "newFolder"
        navigationItem.rightBarButtonItem = add
        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: makeLayout())
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.backgroundColor = .clear
        collectionView.delegate = self
        collectionView.accessibilityIdentifier = "foldersPage"
        view.addSubview(collectionView)
        configureDataSource()
        let nc = NotificationCenter.default
        observers = [Notification.Name.libraryChanged, ActivityCenter.changed].map {
            nc.addObserver(forName: $0, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.reload() } }
        }
        reload()
    }
    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reload()
    }

    // MARK: Layout

    private func makeLayout() -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout { [weak self] idx, env in
            guard let self, let section = self.dataSource?.sectionIdentifier(for: idx) else { return nil }
            let width = env.container.effectiveContentSize.width
            let side: CGFloat = width > 700 ? 28 : 20
            let header = NSCollectionLayoutBoundarySupplementaryItem(layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .estimated(44)),
                                                                     elementKind: UICollectionView.elementKindSectionHeader, alignment: .top)
            switch section {
            case .folders:
                let n = self.dataSource.snapshot().numberOfItems(inSection: .folders)
                if self.dataSource.snapshot().itemIdentifiers(inSection: .folders).first == .empty {
                    let item = NSCollectionLayoutItem(layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .estimated(120)))
                    let group = NSCollectionLayoutGroup.vertical(layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .estimated(120)), subitems: [item])
                    let s = NSCollectionLayoutSection(group: group)
                    s.contentInsets = .init(top: 4, leading: side, bottom: 24, trailing: side)
                    s.boundarySupplementaryItems = [header]
                    return s
                }
                // a little more than two covers per screen on a phone: the next one peeks in
                let w = width > 700 ? 190 : floor((width - side * 2 - 14) / 2.18)
                let rows = n > 4 ? 2 : 1
                let cellH = w + 46
                let item = NSCollectionLayoutItem(layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .absolute(cellH)))
                let group = NSCollectionLayoutGroup.vertical(layoutSize: .init(widthDimension: .absolute(w), heightDimension: .absolute(cellH * CGFloat(rows) + CGFloat(rows - 1) * 14)),
                                                             repeatingSubitem: item, count: rows)
                group.interItemSpacing = .fixed(14)
                let s = NSCollectionLayoutSection(group: group)
                s.orthogonalScrollingBehavior = .continuousGroupLeadingBoundary
                s.interGroupSpacing = 14
                s.contentInsets = .init(top: 4, leading: side, bottom: 24, trailing: side)
                s.boundarySupplementaryItems = [header]
                return s
            case .kinds:
                let item = NSCollectionLayoutItem(layoutSize: .init(widthDimension: .fractionalWidth(0.5), heightDimension: .absolute(76)))
                let group = NSCollectionLayoutGroup.horizontal(layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .absolute(76)), repeatingSubitem: item, count: 2)
                group.interItemSpacing = .fixed(12)
                let s = NSCollectionLayoutSection(group: group)
                s.contentInsets = .init(top: 4, leading: side, bottom: 24, trailing: side)
                s.boundarySupplementaryItems = [header]
                return s
            case .more:
                var cfg = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
                cfg.headerMode = .supplementary
                cfg.backgroundColor = .clear
                let s = NSCollectionLayoutSection.list(using: cfg, layoutEnvironment: env)
                s.contentInsets.bottom = 24
                return s
            }
        }
    }

    private func configureDataSource() {
        let folderCell = UICollectionView.CellRegistration<FolderCoverCell, Item> { cell, _, item in
            switch item {
            case .folder(let f): cell.configure(f)
            case .newFolder: cell.configureNew()
            default: break
            }
        }
        let emptyCell = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { cell, _, _ in
            var c = UIListContentConfiguration.subtitleCell()
            c.image = UIImage(systemName: "folder.badge.plus")
            c.imageProperties.tintColor = .systemTeal
            c.text = "还没有文件夹"
            c.secondaryText = "长按浏览里的卡片 →「加入文件夹」，或者点右上角的 + 新建。"
            c.secondaryTextProperties.color = .secondaryLabel
            cell.contentConfiguration = c
            var bg = UIBackgroundConfiguration.listGroupedCell()
            bg.cornerRadius = 14
            cell.backgroundConfiguration = bg
        }
        let kindCell = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { cell, _, item in
            guard case let .kind(k, n) = item else { return }
            var c = UIListContentConfiguration.subtitleCell()
            c.image = UIImage(systemName: k == .video ? "video.fill" : "photo.fill")
            c.imageProperties.tintColor = k == .video ? .systemPink : .systemBlue
            c.text = k == .video ? "视频" : "图片"
            c.textProperties.font = .preferredFont(forTextStyle: .headline)
            c.secondaryText = "\(n)"
            c.secondaryTextProperties.color = .secondaryLabel
            cell.contentConfiguration = c
            var bg = UIBackgroundConfiguration.listGroupedCell()
            bg.cornerRadius = 14
            cell.backgroundConfiguration = bg
            cell.accessibilityIdentifier = "kind-" + k.rawValue
        }
        let moreCell = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { cell, _, item in
            guard case let .more(m, detail) = item else { return }
            var c = UIListContentConfiguration.valueCell()
            let (title, symbol, color) = Self.moreInfo(m)
            c.text = title
            c.secondaryText = detail
            c.image = UIImage(systemName: symbol)
            c.imageProperties.tintColor = color
            cell.contentConfiguration = c
            cell.accessories = [.disclosureIndicator()]
            cell.accessibilityIdentifier = "more-" + m.rawValue
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { cv, ip, item in
            switch item {
            case .folder, .newFolder: cv.dequeueConfiguredReusableCell(using: folderCell, for: ip, item: item)
            case .empty: cv.dequeueConfiguredReusableCell(using: emptyCell, for: ip, item: item)
            case .kind: cv.dequeueConfiguredReusableCell(using: kindCell, for: ip, item: item)
            case .more: cv.dequeueConfiguredReusableCell(using: moreCell, for: ip, item: item)
            }
        }
        let header = UICollectionView.SupplementaryRegistration<FoldersSectionHeader>(elementKind: UICollectionView.elementKindSectionHeader) { [weak self] v, _, ip in
            guard let self, let s = self.dataSource.sectionIdentifier(for: ip.section) else { return }
            switch s {
            case .folders:
                let n = self.overview?.folders.count ?? 0
                v.configure(title: "我的文件夹", detail: n > 0 ? "\(n)" : nil, action: n > 4 ? "全部" : nil) { [weak self] in self?.showAllFolders() }
            case .kinds: v.configure(title: "媒体类型", detail: nil, action: nil, nil)
            case .more: v.configure(title: "更多", detail: nil, action: nil, nil)
            }
            v.listInsets = s == .more
        }
        dataSource.supplementaryViewProvider = { cv, kind, ip in cv.dequeueConfiguredReusableSupplementary(using: header, for: ip) }
    }

    private static func moreInfo(_ m: More) -> (String, String, UIColor) {
        switch m {
        case .recent: ("最近添加", "clock.badge.checkmark", .systemOrange)
        case .loose: ("散装媒体", "square.dashed", .systemIndigo)
        case .unreviewed: ("未认可", "seal", .systemOrange)
        case .bad: ("损坏或丢失", "exclamationmark.triangle", .systemRed)
        case .trash: ("回收站", "trash", .systemGray)
        }
    }

    // MARK: Data

    func reload() {
        guard !loading else { return }
        loading = true
        Task.detached(priority: .userInitiated) {
            let o = Core.folderOverview()
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.loading = false
                self.apply(o)
            }
        }
    }

    private var lastApplied: [Item] = []

    private func apply(_ o: FolderOverview?) {
        let countChanged = o?.folders.count != overview?.folders.count
        overview = o
        var snap = NSDiffableDataSourceSnapshot<Section, Item>()
        snap.appendSections([.folders, .kinds, .more])
        let folders = o?.folders ?? []
        snap.appendItems(folders.isEmpty ? [.empty] : folders.map(Item.folder) + [.newFolder], toSection: .folders)
        snap.appendItems([.kind(.photo, o?.photos ?? 0), .kind(.video, o?.videos ?? 0)], toSection: .kinds)
        let stats = ActivityCenter.shared.stats
        var more: [Item] = [.more(.recent, nil), .more(.loose, nil), .more(.unreviewed, nil)]
        if (stats?.bad ?? 0) > 0 { more.append(.more(.bad, "\(stats?.bad ?? 0)")) }
        let trashed = stats?.trashed ?? 0
        more.append(.more(.trash, trashed > 0 ? "\(trashed)" : nil))
        snap.appendItems(more, toSection: .more)
        // progress updates arrive every second: only touch the page when something changed
        guard snap.itemIdentifiers != lastApplied || countChanged else { return }
        lastApplied = snap.itemIdentifiers
        // the header shows the count (and "全部"): refresh it when the number of folders changed
        if countChanged && dataSource.snapshot().numberOfSections > 0 { snap.reloadSections([.folders]) }
        dataSource.apply(snap, animatingDifferences: view.window != nil)
    }

    // MARK: Actions

    func collectionView(_ cv: UICollectionView, didSelectItemAt ip: IndexPath) {
        cv.deselectItem(at: ip, animated: true)
        guard let item = dataSource.itemIdentifier(for: ip) else { return }
        switch item {
        case .folder(let f): open(MediaGridViewController(title: f.name, filter: FeedFilter(folder: f.name), folder: f.name))
        case .newFolder, .empty: createFolder()
        case .kind(let k, _): open(MediaGridViewController(title: k == .video ? "视频" : "图片", filter: FeedFilter(kind: k)))
        case .more(let m, _):
            switch m {
            case .recent: open(MediaGridViewController(title: "最近添加", filter: FeedFilter(recentOnly: true)))
            case .loose: open(MediaGridViewController(title: "散装媒体", filter: FeedFilter(looseOnly: true)))
            case .unreviewed: open(MediaGridViewController(title: "未认可", filter: FeedFilter(review: .unreviewed)))
            case .bad: open(MediaGridViewController(title: "损坏或丢失", filter: FeedFilter(badOnly: true)))
            case .trash: open(MediaGridViewController(title: "回收站", filter: FeedFilter(), bin: true))
            }
        }
    }

    private func open(_ vc: MediaGridViewController) {
        vc.onShowInTimeline = onShowInTimeline
        navigationController?.pushViewController(vc, animated: true)
    }

    private func showAllFolders() {
        let vc = AllFoldersViewController(folders: overview?.folders ?? [])
        vc.onOpen = { [weak self] f in self?.open(MediaGridViewController(title: f.name, filter: FeedFilter(folder: f.name), folder: f.name)) }
        navigationController?.pushViewController(vc, animated: true)
    }

    func collectionView(_ cv: UICollectionView, contextMenuConfigurationForItemsAt ips: [IndexPath], point: CGPoint) -> UIContextMenuConfiguration? {
        guard let ip = ips.first, case .folder(let f)? = dataSource.itemIdentifier(for: ip) else { return nil }
        return UIContextMenuConfiguration(actionProvider: { [weak self] _ in self?.folderMenu(f.name) })
    }

    func folderMenu(_ name: String) -> UIMenu {
        UIMenu(children: [
            UIAction(title: "在浏览中查看", image: UIImage(systemName: "rectangle.stack")) { [weak self] _ in self?.onShowInTimeline?(FeedFilter(folder: name)) },
            UIAction(title: "导出纯媒体 ZIP…", image: UIImage(systemName: "doc.zipper")) { [weak self] _ in self?.exportFolderZip(name) },
            UIAction(title: "重命名…", image: UIImage(systemName: "pencil")) { [weak self] _ in self?.renameFolder(name) { _ in self?.reload() } },
            UIMenu(options: .displayInline, children: [
                UIAction(title: "删除文件夹…", image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in self?.confirmDeleteFolder(name) },
            ]),
        ])
    }

    private func createFolder() {
        let a = UIAlertController(title: "新建文件夹", message: nil, preferredStyle: .alert)
        a.addTextField { $0.placeholder = "文件夹名称"; $0.accessibilityIdentifier = "folderName" }
        a.addAction(UIAlertAction(title: "取消", style: .cancel))
        a.addAction(UIAlertAction(title: "创建", style: .default) { [weak self] _ in
            let n = (a.textFields?.first?.text ?? "").trimmingCharacters(in: .whitespaces)
            guard !n.isEmpty else { return }
            _ = try? Core.createFolder(n)
            NotificationCenter.default.post(name: .libraryChanged, object: nil)
            self?.reload()
        })
        present(a, animated: true)
    }
}

extension UIViewController {
    /// Renames a folder; a name that is already taken merges the two (asked first). `done` gets
    /// the new name.
    func renameFolder(_ name: String, done: ((String) -> Void)? = nil) {
        let a = UIAlertController(title: "重命名文件夹", message: nil, preferredStyle: .alert)
        a.addTextField { $0.text = name; $0.placeholder = "文件夹名称"; $0.clearButtonMode = .whileEditing }
        a.addAction(UIAlertAction(title: "取消", style: .cancel))
        a.addAction(UIAlertAction(title: "重命名", style: .default) { [weak self] _ in
            let new = (a.textFields?.first?.text ?? "").trimmingCharacters(in: .whitespaces)
            guard !new.isEmpty, new != name else { return }
            let apply = {
                do { try Core.renameFolder(name, to: new); NotificationCenter.default.post(name: .libraryChanged, object: nil); done?(new) }
                catch {
                    let e = UIAlertController(title: "无法重命名", message: error.localizedDescription, preferredStyle: .alert)
                    e.addAction(UIAlertAction(title: "好", style: .default))
                    self?.present(e, animated: true)
                }
            }
            if Core.folders().contains(where: { $0.name == new }) {
                let m = UIAlertController(title: "合并到「\(new)」？", message: "已经有一个叫「\(new)」的文件夹。「\(name)」里的媒体会放进它，「\(name)」随后删除。", preferredStyle: .alert)
                m.addAction(UIAlertAction(title: "取消", style: .cancel))
                m.addAction(UIAlertAction(title: "合并", style: .default) { _ in apply() })
                self?.present(m, animated: true)
            } else { apply() }
        })
        present(a, animated: true)
    }

    /// Deletes a folder after a confirmation (its media stay in the library).
    func confirmDeleteFolder(_ name: String, done: (() -> Void)? = nil) {
        let a = UIAlertController(title: "删除文件夹「\(name)」？", message: "只删除文件夹，里面的媒体仍在资料库中。", preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "取消", style: .cancel))
        a.addAction(UIAlertAction(title: "删除文件夹", style: .destructive) { _ in
            try? Core.deleteFolder(name)
            NotificationCenter.default.post(name: .libraryChanged, object: nil)
            done?()
        })
        present(a, animated: true)
    }

    /// Exports one folder's media as a plain zip (readable without this app) and offers to share it.
    func exportFolderZip(_ name: String) {
        exportAndShare(fileName: name.replacingOccurrences(of: "/", with: "_") + ".zip") { out in
            try Core.exportMedia(Core.mediaIds(inFolder: name), options: ExportOptions(tags: false, folders: false, mediaOnly: true), to: out)
        }
    }

    /// Runs an export into a temporary file under a busy overlay, then offers the file for
    /// sharing; anything left out is said first, with each media's reason.
    func exportAndShare(fileName: String, _ work: @escaping (URL) throws -> ExportReport) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("export", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let out = dir.appendingPathComponent(fileName)
        let hud = BusyOverlay(title: "正在导出…")
        hud.onCancel = { Core.cancelExport() }
        let host: UIView = view.window ?? view
        hud.show(in: host)
        let timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            MainActor.assumeIsolated {
                if let p = Core.exportStatus(), p.total > 0 { hud.detail = "\(p.done) / \(p.total) 个媒体" }
            }
        }
        Task.detached(priority: .userInitiated) {
            let r = Result { try work(out) }
            await MainActor.run {
                timer.invalidate()
                hud.dismiss { [weak self] in
                    guard let self else { return }
                    switch r {
                    case .success(let rep):
                        let share = {
                            let sheet = UIActivityViewController(activityItems: [out], applicationActivities: nil)
                            sheet.popoverPresentationController?.sourceView = self.view
                            sheet.popoverPresentationController?.sourceRect = CGRect(x: self.view.bounds.midX, y: self.view.bounds.midY, width: 1, height: 1)
                            sheet.completionWithItemsHandler = { _, _, _, _ in try? FileManager.default.removeItem(at: dir) }
                            self.present(sheet, animated: true)
                        }
                        guard !rep.skippedText.isEmpty else { return share() }
                        let a = UIAlertController(title: "已导出 \(rep.media) 个媒体（有遗漏）", message: rep.skippedText, preferredStyle: .alert)
                        a.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in try? FileManager.default.removeItem(at: dir) })
                        a.addAction(UIAlertAction(title: "继续分享", style: .default) { _ in share() })
                        self.present(a, animated: true)
                    case .failure(let e):
                        try? FileManager.default.removeItem(at: dir)
                        let a = UIAlertController(title: "无法导出", message: e.localizedDescription, preferredStyle: .alert)
                        a.addAction(UIAlertAction(title: "好", style: .default))
                        self.present(a, animated: true)
                    }
                }
            }
        }
    }
}

/// Section title in the Photos style: bold title, a count, and an optional "全部" button.
final class FoldersSectionHeader: UICollectionReusableView {
    private let title = UILabel()
    private let detail = UILabel()
    private let button = UIButton(type: .system)
    private var action: (() -> Void)?
    private var leading: NSLayoutConstraint!
    /// The list section is inset by the list itself: its title lines up with the rows' text.
    var listInsets = false { didSet { leading.constant = listInsets ? 4 : 0 } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        title.font = UIFontMetrics(forTextStyle: .title2).scaledFont(for: .systemFont(ofSize: 22, weight: .bold))
        title.adjustsFontForContentSizeCategory = true
        detail.font = .preferredFont(forTextStyle: .body)
        detail.textColor = .secondaryLabel
        var cfg = UIButton.Configuration.plain()
        cfg.image = UIImage(systemName: "chevron.forward")
        cfg.imagePlacement = .trailing
        cfg.imagePadding = 4
        cfg.preferredSymbolConfigurationForImage = .init(pointSize: 13, weight: .semibold)
        cfg.contentInsets = .init(top: 4, leading: 8, bottom: 4, trailing: 0)
        button.configuration = cfg
        button.addAction(UIAction { [weak self] _ in self?.action?() }, for: .touchUpInside)
        button.accessibilityIdentifier = "allFolders"
        let st = UIStackView(arrangedSubviews: [title, detail, UIView(), button])
        st.spacing = 8
        st.alignment = .firstBaseline
        st.translatesAutoresizingMaskIntoConstraints = false
        addSubview(st)
        leading = st.leadingAnchor.constraint(equalTo: leadingAnchor)
        NSLayoutConstraint.activate([
            st.topAnchor.constraint(equalTo: topAnchor, constant: 6), st.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            leading, st.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(title t: String, detail d: String?, action a: String?, _ act: (() -> Void)?) {
        title.text = t
        detail.text = d
        detail.isHidden = d == nil
        button.configuration?.title = a
        button.isHidden = a == nil
        action = act
        accessibilityElements = [title, button]
    }
}

/// A folder as a large rounded cover with its name and count below (or the "新建文件夹" tile).
final class FolderCoverCell: UICollectionViewCell {
    private let cover = UIImageView()
    private let placeholder = UIImageView()
    private let videoBadge = UIImageView(image: UIImage(systemName: "play.fill"))
    private let name = UILabel()
    private let count = UILabel()
    private let dashed = CAShapeLayer()
    private var token: String?

    override init(frame: CGRect) {
        super.init(frame: frame)
        cover.contentMode = .scaleAspectFill
        cover.clipsToBounds = true
        cover.layer.cornerRadius = 12
        cover.layer.cornerCurve = .continuous
        cover.backgroundColor = .tertiarySystemFill
        placeholder.contentMode = .center
        placeholder.preferredSymbolConfiguration = .init(pointSize: 34, weight: .regular)
        placeholder.tintColor = .tertiaryLabel
        videoBadge.tintColor = .white
        videoBadge.preferredSymbolConfiguration = .init(pointSize: 12, weight: .bold)
        videoBadge.layer.shadowOpacity = 0.4
        videoBadge.layer.shadowRadius = 2
        videoBadge.layer.shadowOffset = .zero
        name.font = .preferredFont(forTextStyle: .subheadline)
        name.adjustsFontForContentSizeCategory = true
        count.font = .preferredFont(forTextStyle: .footnote)
        count.textColor = .secondaryLabel
        dashed.fillColor = nil
        dashed.strokeColor = UIColor.tertiaryLabel.cgColor
        dashed.lineDashPattern = [6, 4]
        dashed.lineWidth = 1.5
        cover.layer.addSublayer(dashed)
        for v in [cover, placeholder, videoBadge, name, count] { v.translatesAutoresizingMaskIntoConstraints = false; contentView.addSubview(v) }
        NSLayoutConstraint.activate([
            cover.topAnchor.constraint(equalTo: contentView.topAnchor),
            cover.leadingAnchor.constraint(equalTo: contentView.leadingAnchor), cover.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            cover.heightAnchor.constraint(equalTo: cover.widthAnchor),
            placeholder.centerXAnchor.constraint(equalTo: cover.centerXAnchor), placeholder.centerYAnchor.constraint(equalTo: cover.centerYAnchor),
            videoBadge.leadingAnchor.constraint(equalTo: cover.leadingAnchor, constant: 8), videoBadge.bottomAnchor.constraint(equalTo: cover.bottomAnchor, constant: -8),
            name.topAnchor.constraint(equalTo: cover.bottomAnchor, constant: 6),
            name.leadingAnchor.constraint(equalTo: contentView.leadingAnchor), name.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor),
            count.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 1),
            count.leadingAnchor.constraint(equalTo: contentView.leadingAnchor), count.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor),
        ])
        isAccessibilityElement = true
        accessibilityTraits = .button
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        dashed.frame = cover.bounds
        dashed.path = UIBezierPath(roundedRect: cover.bounds.insetBy(dx: 0.75, dy: 0.75), cornerRadius: 12).cgPath
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        token = nil
        cover.image = nil
    }

    func configure(_ f: FolderOverview.Folder) {
        name.text = f.name
        count.text = f.videos > 0 && f.videos < f.count ? "\(f.count) · 视频 \(f.videos)" : "\(f.count)"
        dashed.isHidden = true
        placeholder.image = UIImage(systemName: "folder")
        placeholder.isHidden = false
        videoBadge.isHidden = true
        cover.backgroundColor = .tertiarySystemFill
        accessibilityLabel = "\(f.name)，\(f.count) 个媒体"
        accessibilityIdentifier = "folder-" + f.name
        token = f.coverPath
        guard let path = f.coverPath else { return }
        let px = max(bounds.width, 180) * traitCollection.displayScale
        MediaLoader.shared.load(path: path, isVideo: f.coverVideo, maxPixel: px) { [weak self] img in
            guard let self, self.token == path, let img else { return }
            self.cover.image = img
            self.placeholder.isHidden = true
            self.videoBadge.isHidden = !f.coverVideo
        }
    }

    func configureNew() {
        token = nil
        cover.image = nil
        cover.backgroundColor = .clear
        dashed.isHidden = false
        placeholder.image = UIImage(systemName: "plus")
        placeholder.isHidden = false
        videoBadge.isHidden = true
        name.text = "新建文件夹"
        count.text = " "
        accessibilityLabel = "新建文件夹"
        accessibilityIdentifier = "newFolderTile"
    }
}

/// "全部": every folder in a two-column grid (Photos' "See All" for albums).
final class AllFoldersViewController: UIViewController, UICollectionViewDataSource, UICollectionViewDelegate {
    var onOpen: ((FolderOverview.Folder) -> Void)?
    private var folders: [FolderOverview.Folder]
    private var collectionView: UICollectionView!

    init(folders: [FolderOverview.Folder]) { self.folders = folders; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "全部文件夹"
        navigationItem.largeTitleDisplayMode = .never
        view.backgroundColor = .systemGroupedBackground
        let layout = UICollectionViewCompositionalLayout { _, env in
            let width = env.container.effectiveContentSize.width
            let columns = max(2, Int(width / 220))
            let side: CGFloat = 20, gap: CGFloat = 16
            let w = floor((width - side * 2 - gap * CGFloat(columns - 1)) / CGFloat(columns))
            let item = NSCollectionLayoutItem(layoutSize: .init(widthDimension: .absolute(w), heightDimension: .absolute(w + 46)))
            let group = NSCollectionLayoutGroup.horizontal(layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .absolute(w + 46)), repeatingSubitem: item, count: columns)
            group.interItemSpacing = .fixed(gap)
            let s = NSCollectionLayoutSection(group: group)
            s.interGroupSpacing = 18
            s.contentInsets = .init(top: 12, leading: side, bottom: 24, trailing: side)
            return s
        }
        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: layout)
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.backgroundColor = .clear
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(FolderCoverCell.self, forCellWithReuseIdentifier: "f")
        view.addSubview(collectionView)
    }

    func collectionView(_ cv: UICollectionView, numberOfItemsInSection section: Int) -> Int { folders.count }
    func collectionView(_ cv: UICollectionView, cellForItemAt ip: IndexPath) -> UICollectionViewCell {
        let c = cv.dequeueReusableCell(withReuseIdentifier: "f", for: ip) as! FolderCoverCell
        c.configure(folders[ip.item])
        return c
    }
    func collectionView(_ cv: UICollectionView, didSelectItemAt ip: IndexPath) { onOpen?(folders[ip.item]) }
}
