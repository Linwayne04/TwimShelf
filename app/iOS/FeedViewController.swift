import UIKit
import SwiftUI
import AVFoundation

/// Main screen: random, endlessly looping feed with tag search chips on top and view toggles at the bottom.
final class FeedViewController: UIViewController, UICollectionViewDataSource, UICollectionViewDataSourcePrefetching, UICollectionViewDelegate, UITextFieldDelegate, FeedCellDelegate, UIPopoverPresentationControllerDelegate {
    /// Settings asks the feed to show one folder (object: the name, or nil for everything).
    static let showFolderNote = Notification.Name("ShowFolder")
    /// object = a tag label: show only media with that tag.
    static let showLabelNote = Notification.Name("ShowLabel")
    // State
    private var allItems: [FeedItem] = []
    private var entries: [[FeedItem]] = []
    private var terms: [String] = [] { didSet { collectionView?.visibleCells.forEach { ($0 as? FeedCell)?.highlight = terms } } }
    private var scope: SearchScope = .both
    /// Settings → 搜索 → 语义模糊搜索.
    private var fuzzy: Bool { LibraryPrefs.fuzzySearch }
    private var grouped = UserDefaults.standard.object(forKey: "grouped") as? Bool ?? true
    /// Random order from the system RNG; ranks survive reloads until the next reshuffle.
    private var order = FeedOrder()
    /// "Only this author" / "only this tag" filters set from the long-press menus.
    private var filter = FeedFilter()
    /// Endless loop: each pass over all entries is one section, separated by an "again from the
    /// top" footer; another pass is appended when the user nears the end, so the list holds a few
    /// thousand items at most instead of a huge virtual count.
    private var passes = 1
    /// Browsing loops endlessly; search results are shown once and end with a footer.
    private var loops: Bool { terms.isEmpty }
    private func initialPasses() -> Int { entries.isEmpty || !loops ? 1 : max(2, min(20, 400 / entries.count)) }
    private var pendingInline: DispatchWorkItem?

    // Views
    private var collectionView: UICollectionView!
    private let header = FollowedView()
    /// The filter chips (仅 #标签, 文件夹…) float on their own under the search bar, not inside it.
    private let chipBar = UIView()
    private let searchField = UISearchTextField()
    /// The round × beside the search bar (not inside it): ends the search.
    private let exitButton = UIButton(type: .system)
    /// Exports what the search shows; beside the ×, shown while a search or filter is in effect.
    private let exportButton = UIButton(type: .system)
    private var exitShown = false, exportShown = false
    private var headerBesideExport: NSLayoutConstraint!
    private var exportBesideExit: NSLayoutConstraint!
    private var exportAtEdge: NSLayoutConstraint!
    private var headerTrailing: NSLayoutConstraint!
    private var headerBesideExit: NSLayoutConstraint!
    private let searchRow = UIStackView()
    private var fields = SearchFields.saved
    /// The list under the field while searching (suggestions, or filters and scopes).
    private let suggestions = SearchSuggestionsView()
    private var searching = false
    /// Conditions from the field's capsules: a folder, "最近", "外部导入".
    private var tokenFolder: String?
    private var tokenRecent = false
    private var tokenExternal = false
    private var tokenKind: MediaKind?
    /// Tags for the suggestions, read once per search.
    private var tagCache: [TagCount] = []
    private let chipScroll = UIScrollView()
    private let chipStack = UIStackView()
    private let bottomBar = UIView()
    private let groupSwitch = UISwitch()
    private let tabs = HomeTabs([("浏览", "rectangle.stack", "tab-timeline"), ("文件夹", "folder", "tab-folders")])
    private var shuffleButton: UIButton!
    /// The "文件夹" tab: its own navigation stack (folder → media), under the home's bar.
    private var foldersNav: UINavigationController?
    private let emptyLabel = UILabel()
    private let activityPanel = ActivityPanel()
    private let toast = ToastView()
    private let backdrop = HomeBackdropView()

    // Inline autoplay: one shared muted player for the most visible video.
    private let inlinePlayer = AVPlayer()
    private weak var inlineHost: MediaPageView?
    private var loopObserver: NSObjectProtocol?
    /// The inline video's layer shows only once its first frame is ready (the still frame under
    /// it shows until then; an empty video layer is black).
    private var readyObservation: NSKeyValueObservation?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        backdrop.frame = view.bounds
        backdrop.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(backdrop)
        inlinePlayer.isMuted = true
        inlinePlayer.automaticallyWaitsToMinimizeStalling = false
        loopObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] n in
            guard let self, (n.object as? AVPlayerItem) === self.inlinePlayer.currentItem else { return }
            self.inlinePlayer.seek(to: .zero); self.inlinePlayer.play()
        }
        NotificationCenter.default.addObserver(self, selector: #selector(libraryChanged(_:)), name: .libraryChanged, object: nil)
        // in the background the video layer is dropped; back in front, playback is picked up again
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.detachInline() }
        }
        NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateInlinePlayback() }
        }
        NotificationCenter.default.addObserver(forName: Self.showLabelNote, object: nil, queue: .main) { [weak self] n in
            MainActor.assumeIsolated {
                guard let self, let l = n.object as? String else { return }
                self.selectTab(0)
                self.clearTerms()
                self.filter.labels = [l]
                self.renderChips(); self.reload()
            }
        }
        NotificationCenter.default.addObserver(forName: Self.showFolderNote, object: nil, queue: .main) { [weak self] n in
            MainActor.assumeIsolated { self?.selectTab(0); self?.showFolder(n.object as? String) }
        }
        NotificationCenter.default.addObserver(forName: SyncService.warning, object: nil, queue: .main) { [weak self] n in
            MainActor.assumeIsolated {
                guard let self, let text = n.userInfo?["text"] as? String else { return }
                if n.userInfo?["settings"] as? Bool == true {
                    self.toast.show(text, action: "去设置") { UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!) }
                } else { self.toast.show(text) }
            }
        }
        NotificationCenter.default.addObserver(forName: LibraryPrefs.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateTriageMode() }
        }
        NotificationCenter.default.addObserver(forName: LibraryPrefs.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.renderChips(); self?.reload(); if self?.searching == true { self?.rebuildSuggestions() } }
        }
        buildCollection()
        buildHeader()
        buildBottomBar()
        activityPanel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(activityPanel)
        NSLayoutConstraint.activate([
            activityPanel.bottomAnchor.constraint(equalTo: bottomBar.topAnchor, constant: -10),
            activityPanel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            activityPanel.widthAnchor.constraint(lessThanOrEqualToConstant: 520),
            { let c = activityPanel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14); c.priority = .defaultHigh; return c }(),
            activityPanel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 14),
        ])
        NotificationCenter.default.addObserver(forName: ActivityCenter.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if self?.searching == true { self?.updateSuggestionFooter() } }
        }
        if CrashWatch.shared.lastRunAbnormal {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.toast.show("上次运行没有正常结束，已记录原因", action: "导出诊断") { [weak self] in
                    // the settings sheet (with 完成), as from the bar's button; pushing it onto
                    // the home screen, whose navigation bar is hidden, left no way back
                    guard let self else { return }
                    let m = ManageViewController()
                    m.onLibraryChanged = { [weak self] in self?.reload(keepPosition: true) }
                    let nav = UINavigationController(rootViewController: m)
                    nav.modalPresentationStyle = .formSheet
                    self.present(nav, animated: true) { m.exportDiagnostics() }
                }
            }
        }
        NotificationCenter.default.addObserver(forName: ShareInbox.failed, object: nil, queue: .main) { [weak self] n in
            MainActor.assumeIsolated { if let t = n.object as? String { self?.toast.show(t) } }
        }
        NotificationCenter.default.addObserver(forName: ShareInbox.imported, object: nil, queue: .main) { [weak self] n in
            MainActor.assumeIsolated {
                guard let self, let reports = n.object as? [ImportReport] else { return }
                self.toast.show(ShareInbox.summary(reports), action: "导入记录") { [weak self] in
                    self?.navigationController?.pushViewController(ImportHistoryViewController(), animated: true) }
            }
        }
        toast.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(toast)
        NSLayoutConstraint.activate([
            toast.bottomAnchor.constraint(equalTo: bottomBar.topAnchor, constant: -12),
            toast.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            toast.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, constant: -32),
        ])
        reload()
        updateTriageMode()
    }

    // MARK: Triage mode

    private var triage: TriageViewController?

    /// Triage mode replaces the timeline with one post at a time.
    private func updateTriageMode() {
        if LibraryPrefs.triageMode, triage == nil {
            selectTab(0, animated: false)
            detachInline()   // (not just paused: a paused video layer can go black)
            let vc = TriageViewController()
            addChild(vc)
            vc.view.frame = view.bounds
            vc.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.addSubview(vc.view)
            vc.didMove(toParent: self)
            // keep the settings button reachable
            view.bringSubviewToFront(bottomBar)
            bottomBar.isHidden = true
            triage = vc
            vc.view.alpha = 0
            // the triage page is see-through (the backdrop shows): the timeline must go, or its
            // search bar, cards and tags show through underneath
            UIView.animate(withDuration: 0.25, delay: 0, usingSpringWithDamping: 0.86, initialSpringVelocity: 0, animations: {
                vc.view.alpha = 1
                [self.collectionView, self.header, self.emptyLabel].forEach { $0.alpha = 0 }
            }) { _ in if self.triage === vc { self.collectionView.isHidden = true; self.header.isHidden = true } }
        } else if !LibraryPrefs.triageMode, let vc = triage {
            triage = nil
            bottomBar.isHidden = false
            collectionView.isHidden = false
            header.isHidden = false
            UIView.animate(withDuration: 0.2, delay: 0, usingSpringWithDamping: 0.86, initialSpringVelocity: 0, animations: {
                vc.view.alpha = 0
                [self.collectionView, self.header, self.emptyLabel].forEach { $0.alpha = 1 }
            }) { _ in
                vc.willMove(toParent: nil); vc.view.removeFromSuperview(); vc.removeFromParent()
            }
            reload(keepPosition: true)
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(true, animated: animated)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        updateInlinePlayback()
        backdrop.visible = true
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        detachInline()   // (not just paused: a paused video layer can go black)
        backdrop.visible = false
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // the settings panel opens over the cards: the grid starts under the bar (and its chips)
        let last: UIView = chipScroll.isHidden ? searchRow : chipScroll
        let top = last.convert(last.bounds, to: view).maxY + 12 - view.safeAreaInsets.top
        suggestions.topInset = header.frame.maxY + 8
        let keyboardTop = view.keyboardLayoutGuide.layoutFrame.minY
        let below = max(view.bounds.maxY - keyboardTop, view.safeAreaInsets.bottom)
        if suggestions.table.contentInset.bottom != below {
            suggestions.table.contentInset.bottom = below
            suggestions.table.verticalScrollIndicatorInsets.bottom = below
        }
        let bottom = view.bounds.height - bottomBar.frame.minY - view.safeAreaInsets.bottom
        let insets = UIEdgeInsets(top: top + 8, left: 0, bottom: bottom + 12, right: 0)
        if collectionView.contentInset != insets { collectionView.contentInset = insets; collectionView.verticalScrollIndicatorInsets = insets }
    }

    // MARK: Layout

    private func buildCollection() {
        let layout = UICollectionViewCompositionalLayout { _, env in
            let width = env.container.effectiveContentSize.width
            let columns = max(1, min(4, Int(width / 400)))
            let side: CGFloat = width > 700 ? 24 : 12
            let cardWidth = (width - side * 2 - CGFloat(columns - 1) * 14) / CGFloat(columns)
            let h = FeedCell.height(width: cardWidth, traits: env.traitCollection)
            let item = NSCollectionLayoutItem(layoutSize: .init(widthDimension: .fractionalWidth(1.0 / CGFloat(columns)), heightDimension: .absolute(h)))
            let group = NSCollectionLayoutGroup.horizontal(layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .absolute(h)), repeatingSubitem: item, count: columns)
            group.interItemSpacing = .fixed(14)
            let section = NSCollectionLayoutSection(group: group)
            section.interGroupSpacing = 18
            section.contentInsets = .init(top: 0, leading: side, bottom: 0, trailing: side)
            let footer = NSCollectionLayoutBoundarySupplementaryItem(layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .absolute(LoopSeparatorView.height)),
                                                                     elementKind: LoopSeparatorView.kind, alignment: .bottom)
            section.boundarySupplementaryItems = [footer]
            return section
        }
        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: layout)
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.backgroundColor = .clear
        collectionView.contentInsetAdjustmentBehavior = .always
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.keyboardDismissMode = .onDrag
        collectionView.register(FeedCell.self, forCellWithReuseIdentifier: FeedCell.reuseID)
        collectionView.register(LoopSeparatorView.self, forSupplementaryViewOfKind: LoopSeparatorView.kind, withReuseIdentifier: LoopSeparatorView.kind)
        collectionView.prefetchDataSource = self
        view.addSubview(collectionView)

        emptyLabel.textAlignment = .center
        emptyLabel.numberOfLines = 0
        emptyLabel.textColor = .secondaryLabel
        emptyLabel.font = .preferredFont(forTextStyle: .body)
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            emptyLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            emptyLabel.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, multiplier: 0.8),
        ])
    }

    private func glass(_ host: UIView, corner: CGFloat) {
        let effect: UIVisualEffect
        if #available(iOS 26.0, *) { effect = UIGlassEffect() } else { effect = UIBlurEffect(style: .systemChromeMaterial) }
        let v = UIVisualEffectView(effect: effect)
        v.layer.cornerRadius = corner
        v.layer.cornerCurve = .continuous
        v.clipsToBounds = true
        v.translatesAutoresizingMaskIntoConstraints = false
        host.insertSubview(v, at: 0)
        NSLayoutConstraint.activate([v.topAnchor.constraint(equalTo: host.topAnchor), v.bottomAnchor.constraint(equalTo: host.bottomAnchor),
                                     v.leadingAnchor.constraint(equalTo: host.leadingAnchor), v.trailingAnchor.constraint(equalTo: host.trailingAnchor)])
    }

    private func buildHeader() {
        glass(header, corner: 26)
        header.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(header)

        searchField.returnKeyType = .search
        searchField.autocapitalizationType = .none
        searchField.autocorrectionType = .no
        searchField.delegate = self
        searchField.accessibilityIdentifier = "search"
        searchField.allowsDeletingTokens = true
        // one box only: the glass bar is the field's frame (the field's own rounded background
        // inside it looked like a second box)
        searchField.borderStyle = .none
        searchField.backgroundColor = .clear
        searchField.addTarget(self, action: #selector(searchTextChanged), for: .editingChanged)

        var xc: UIButton.Configuration
        if #available(iOS 26.0, *) { xc = .glass() } else { xc = .gray() }
        xc.image = UIImage(systemName: "xmark")
        xc.preferredSymbolConfigurationForImage = .init(pointSize: 17, weight: .medium)
        xc.cornerStyle = .capsule
        xc.baseForegroundColor = .label
        exitButton.configuration = xc
        exitButton.accessibilityIdentifier = "searchExit"
        exitButton.accessibilityLabel = "退出搜索"
        exitButton.addAction(UIAction { [weak self] _ in self?.clearSearch() }, for: .touchUpInside)
        exitButton.isHidden = true
        exitButton.alpha = 0
        exitButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(exitButton)

        var ec: UIButton.Configuration
        if #available(iOS 26.0, *) { ec = .glass() } else { ec = .gray() }
        ec.image = UIImage(systemName: "square.and.arrow.up")
        ec.preferredSymbolConfigurationForImage = .init(pointSize: 17, weight: .medium)
        ec.cornerStyle = .capsule
        ec.baseForegroundColor = .label
        exportButton.configuration = ec
        exportButton.accessibilityIdentifier = "searchExport"
        exportButton.accessibilityLabel = "导出搜索结果"
        exportButton.addAction(UIAction { [weak self] _ in self?.showExport() }, for: .touchUpInside)
        exportButton.isHidden = true
        exportButton.alpha = 0
        exportButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(exportButton)

        chipStack.axis = .horizontal
        chipStack.spacing = 8
        chipScroll.showsHorizontalScrollIndicator = false
        chipScroll.addSubview(chipStack)
        chipStack.translatesAutoresizingMaskIntoConstraints = false
        chipScroll.isHidden = true

        searchRow.addArrangedSubview(searchField)
        searchRow.spacing = 6
        searchRow.alignment = .center

        let stack = UIStackView(arrangedSubviews: [searchRow])
        stack.axis = .vertical
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(stack)
        chipBar.translatesAutoresizingMaskIntoConstraints = false
        chipScroll.translatesAutoresizingMaskIntoConstraints = false
        chipBar.addSubview(chipScroll)
        view.addSubview(chipBar)
        header.follower = chipBar

        headerTrailing = header.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -10)
        headerBesideExit = header.trailingAnchor.constraint(equalTo: exitButton.leadingAnchor, constant: -8)
        headerBesideExport = header.trailingAnchor.constraint(equalTo: exportButton.leadingAnchor, constant: -8)
        exportBesideExit = exportButton.trailingAnchor.constraint(equalTo: exitButton.leadingAnchor, constant: -8)
        exportAtEdge = exportButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -10)
        exportAtEdge.isActive = true
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 6),
            header.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 10),
            headerTrailing,
            exitButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -10),
            exitButton.centerYAnchor.constraint(equalTo: searchRow.centerYAnchor),
            exitButton.widthAnchor.constraint(equalToConstant: 52), exitButton.heightAnchor.constraint(equalToConstant: 52),
            exportButton.centerYAnchor.constraint(equalTo: searchRow.centerYAnchor),
            exportButton.widthAnchor.constraint(equalToConstant: 52), exportButton.heightAnchor.constraint(equalToConstant: 52),
            stack.topAnchor.constraint(equalTo: header.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: header.bottomAnchor, constant: -8),
            stack.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -8),
            searchField.heightAnchor.constraint(equalToConstant: 40),
            chipBar.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
            chipBar.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 2),
            chipBar.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -10),
            chipScroll.topAnchor.constraint(equalTo: chipBar.topAnchor), chipScroll.bottomAnchor.constraint(equalTo: chipBar.bottomAnchor),
            chipScroll.leadingAnchor.constraint(equalTo: chipBar.leadingAnchor), chipScroll.trailingAnchor.constraint(equalTo: chipBar.trailingAnchor),
            chipScroll.heightAnchor.constraint(equalToConstant: 32),
            chipStack.topAnchor.constraint(equalTo: chipScroll.contentLayoutGuide.topAnchor),
            chipStack.bottomAnchor.constraint(equalTo: chipScroll.contentLayoutGuide.bottomAnchor),
            chipStack.leadingAnchor.constraint(equalTo: chipScroll.contentLayoutGuide.leadingAnchor),
            chipStack.trailingAnchor.constraint(equalTo: chipScroll.contentLayoutGuide.trailingAnchor),
            chipStack.heightAnchor.constraint(equalTo: chipScroll.frameLayoutGuide.heightAnchor),
        ])

        // the list under the field while searching: it covers the timeline (the field floats
        // above it) and ends at the keyboard
        suggestions.translatesAutoresizingMaskIntoConstraints = false
        suggestions.isHidden = true
        suggestions.alpha = 0
        view.addSubview(suggestions)
        NSLayoutConstraint.activate([
            suggestions.topAnchor.constraint(equalTo: view.topAnchor),
            suggestions.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            suggestions.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            // the list goes on behind the keyboard (its rounded corners and the space beside
            // them show the list, not the timeline); its rows end above the keyboard
            suggestions.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        view.keyboardLayoutGuide.usesBottomSafeArea = false
        // an invisible view on the keyboard's top edge: the keyboard moving lays the view out
        // again, which updates where the list's rows end
        let probe = UIView()
        probe.isUserInteractionEnabled = false
        probe.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(probe)
        NSLayoutConstraint.activate([probe.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
                                     probe.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                                     probe.widthAnchor.constraint(equalToConstant: 1), probe.heightAnchor.constraint(equalToConstant: 1)])
        view.bringSubviewToFront(header)
        view.bringSubviewToFront(chipBar)
        view.bringSubviewToFront(exitButton)
        view.bringSubviewToFront(exportButton)
        updatePlaceholder()
    }

    private func buildBottomBar() {
        glass(bottomBar, corner: 28)
        bottomBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(bottomBar)

        tabs.onChange = { [weak self] i in self?.selectTab(i) }

        let groupLabel = UILabel()
        groupLabel.text = "按帖子分组"
        groupLabel.font = .systemFont(ofSize: 15, weight: .medium)
        groupLabel.adjustsFontSizeToFitWidth = true
        groupLabel.minimumScaleFactor = 0.85
        groupSwitch.isOn = grouped
        groupSwitch.accessibilityIdentifier = "groupSwitch"
        groupSwitch.addTarget(self, action: #selector(groupChanged), for: .valueChanged)

        var cfg = UIButton.Configuration.plain()
        cfg.image = UIImage(systemName: "shuffle")
        cfg.contentInsets = .init(top: 8, leading: 8, bottom: 8, trailing: 8)
        let shuffle = UIButton(configuration: cfg)
        shuffle.accessibilityLabel = "重新随机"
        shuffle.addTarget(self, action: #selector(reshuffle), for: .touchUpInside)
        shuffleButton = shuffle

        var mcfg = UIButton.Configuration.plain()
        mcfg.image = UIImage(systemName: "square.stack.3d.down.right")
        mcfg.contentInsets = .init(top: 8, leading: 8, bottom: 8, trailing: 8)
        let manage = UIButton(configuration: mcfg)
        manage.accessibilityLabel = "资料库管理"
        manage.accessibilityIdentifier = "manage"
        manage.addTarget(self, action: #selector(openManage), for: .touchUpInside)

        func separator() -> UIView {
            let v = UIView(); v.backgroundColor = .separator
            v.widthAnchor.constraint(equalToConstant: 1).isActive = true
            v.heightAnchor.constraint(equalToConstant: 22).isActive = true
            return v
        }
        let stack = UIStackView(arrangedSubviews: [tabs, separator(), groupLabel, groupSwitch, separator(), shuffle, manage])
        // everything has to fit a phone's width with the two tabs added
        stack.spacing = 8
        stack.setCustomSpacing(4, after: shuffle)
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        bottomBar.addSubview(stack)
        NSLayoutConstraint.activate([
            bottomBar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8),
            bottomBar.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            bottomBar.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 8),
            stack.topAnchor.constraint(equalTo: bottomBar.topAnchor, constant: 6),
            stack.bottomAnchor.constraint(equalTo: bottomBar.bottomAnchor, constant: -6),
            stack.leadingAnchor.constraint(equalTo: bottomBar.leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: bottomBar.trailingAnchor, constant: -6),
        ])
    }

    // MARK: Tabs

    /// Switches between the timeline and the folders. The folders keep their own navigation
    /// (and scroll position) while hidden; the bar stays, only the shuffle button leaves it.
    func selectTab(_ i: Int, animated: Bool = true) {
        if tabs.selectedIndex != i { tabs.select(i, animated: animated, notify: false) }
        let showFolders = i == 1
        if showFolders && foldersNav == nil {
            let vc = FoldersViewController()
            vc.onShowInTimeline = { [weak self] f in self?.showInTimeline(f) }
            let nav = UINavigationController(rootViewController: vc)
            nav.navigationBar.prefersLargeTitles = true
            addChild(nav)
            nav.view.frame = view.bounds
            nav.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.insertSubview(nav.view, aboveSubview: header)
            nav.didMove(toParent: self)
            nav.view.isHidden = true
            foldersNav = nav
        }
        guard let nav = foldersNav else { return }
        // the folders' lists end above the floating bar
        nav.additionalSafeAreaInsets.bottom = bottomBar.bounds.height + 8
        if showFolders == !nav.view.isHidden { return }
        if showFolders {
            detachInline()   // (not just paused: a paused video layer can go black)
            exitSearch()
            searchField.resignFirstResponder()
            nav.view.isHidden = false
            nav.view.alpha = 0
        }
        // the folders' navigation bar is clear at the top: the search bar must go at once, not
        // after the cross-fade (it showed through until then)
        UIView.animate(withDuration: animated ? 0.15 : 0, delay: 0, usingSpringWithDamping: 0.86, initialSpringVelocity: 0) { self.header.alpha = showFolders ? 0 : 1 }
        let work = {
            nav.view.alpha = showFolders ? 1 : 0
            self.shuffleButton.isHidden = showFolders
            self.shuffleButton.alpha = showFolders ? 0 : 1
            self.bottomBar.layoutIfNeeded()
            self.view.layoutIfNeeded()
        }
        let finish = { (_: Bool) in
            if !showFolders { nav.view.isHidden = true; self.updateInlinePlayback() }
            [self.collectionView, self.header].forEach { $0?.isHidden = showFolders }
            self.view.bringSubviewToFront(self.bottomBar)
            self.view.bringSubviewToFront(self.activityPanel)
            self.view.bringSubviewToFront(self.toast)
        }
        if !showFolders { [collectionView, header].forEach { $0?.isHidden = false } }
        if animated {
            UIView.animate(withDuration: 0.32, delay: 0, usingSpringWithDamping: 0.9, initialSpringVelocity: 0.2, animations: work, completion: finish)
        } else { work(); finish(true) }
    }

    /// The folders' selection mode puts its toolbar where the home bar is: the bar slides away
    /// meanwhile, and the folders' lists use the whole height.
    func setHomeBarHidden(_ hidden: Bool) {
        bottomBar.isUserInteractionEnabled = !hidden
        foldersNav?.additionalSafeAreaInsets.bottom = hidden ? 0 : bottomBar.bounds.height + 8
        UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.9, initialSpringVelocity: 0) {
            self.bottomBar.alpha = hidden ? 0 : 1
            self.bottomBar.transform = hidden ? CGAffineTransform(translationX: 0, y: 120) : .identity
        }
    }

    /// "在浏览中查看" from the folders: back to the timeline with that filter.
    private func showInTimeline(_ f: FeedFilter) {
        selectTab(0)
        clearTerms()
        filter = f
        renderChips()
        reload()
    }

    // MARK: Data

    private var reloadGeneration = 0
    /// The generation of the result on screen (an export waits for the latest search).
    private var shownGeneration = -1

    func reload(keepPosition: Bool = false) {
        reloadGeneration += 1
        let gen = reloadGeneration
        var req = FeedRequest(terms: terms, scope: scope, fuzzy: fuzzy, fields: fields, filter: currentFilter)
        let needsVectors = fuzzy && (fields.tags || fields.text || !fields.author) && !terms.isEmpty && ModelStore.shared.activeEmbedderId != nil && AIEngine.isSupported
        Task {
            if needsVectors, let q = await AIEngine.shared.queryVectors(terms) {
                req.termVectors = q.vectors
                req.embedModel = q.model
            }
            let items = await Task.detached(priority: .userInitiated) { () -> [FeedItem] in
                do { return try Core.feed(req) } catch { print("feed error:", error); return [] }
            }.value
            guard gen == self.reloadGeneration else { return }
            self.shownGeneration = gen
            self.apply(items, keepPosition: keepPosition)
            self.updateExitButton()
        }
    }

    /// Long-press filters plus the settings filters (unreviewed only, damaged only).
    private var currentFilter: FeedFilter {
        var f = filter
        if LibraryPrefs.badOnly { f.badOnly = true }
        // conditions from the search field's capsules
        if let d = tokenFolder { f.folder = d }
        if tokenRecent { f.recentOnly = true }
        if tokenExternal { f.looseOnly = true }
        if let k = tokenKind { f.kind = k }
        return f
    }

    /// Where you were in the unfiltered feed before searching or filtering: restored when the
    /// search is closed (the order is stable, so the same position shows the same media).
    private var savedBrowse: (offset: CGPoint, passes: Int)?
    private var lastUnfiltered = true
    private var isUnfiltered: Bool { terms.isEmpty && currentFilter.isEmpty }

    private func apply(_ items: [FeedItem], keepPosition: Bool) {
        let nowUnfiltered = isUnfiltered
        if lastUnfiltered && !nowUnfiltered { savedBrowse = (collectionView.contentOffset, passes) }
        let restore = !lastUnfiltered && nowUnfiltered ? savedBrowse : nil
        if restore != nil { savedBrowse = nil }
        lastUnfiltered = nowUnfiltered
        let oldEntries = entries
        allItems = order.apply(items)
        rebuildEntries()
        if keepPosition, restore == nil, incrementalUpdate(from: oldEntries) {
            emptyLabel.isHidden = !allItems.isEmpty
            DispatchQueue.main.async { self.updateInlinePlayback() }
            return
        }
        if let r = restore {
            passes = max(r.passes, initialPasses())
            collectionView.reloadData()
            collectionView.layoutIfNeeded()
            collectionView.setContentOffset(r.offset, animated: false)
            emptyLabel.isHidden = !allItems.isEmpty
            DispatchQueue.main.async { self.updateInlinePlayback() }
            return
        }
        if !keepPosition || !loops { passes = initialPasses() }
        let offset = collectionView.contentOffset
        collectionView.reloadData()
        if keepPosition {
            collectionView.layoutIfNeeded()
            collectionView.setContentOffset(offset, animated: false)
        } else {
            collectionView.setContentOffset(CGPoint(x: 0, y: -collectionView.adjustedContentInset.top), animated: false)
        }
        if allItems.isEmpty {
            emptyLabel.text = terms.isEmpty && currentFilter.isEmpty ? "资料库是空的\n点右下角的按钮导入或下载帖子" : "没有匹配的媒体"
        }
        emptyLabel.isHidden = !allItems.isEmpty
        DispatchQueue.main.async { self.updateInlinePlayback() }
    }

    private func entryKey(_ e: [FeedItem]) -> String { (grouped ? e.first?.postId : e.first?.mediaId) ?? "" }

    /// After a change in the library (a delete, new tags, an AI result, a sync), updates the
    /// grid without reloading it: removed cards fade out in every pass, changed cards update in
    /// place, everything else stays as it is (no flash, no lost scroll position). Returns false
    /// when cards were added or reordered; the caller then reloads.
    private func incrementalUpdate(from old: [[FeedItem]]) -> Bool {
        guard !old.isEmpty, !entries.isEmpty, collectionView.numberOfSections == passes,
              (0..<passes).allSatisfy({ collectionView.numberOfItems(inSection: $0) == old.count }) else { return false }
        let oldKeys = old.map(entryKey), newKeys = entries.map(entryKey)
        let keep = Set(newKeys)
        guard oldKeys.filter({ keep.contains($0) }) == newKeys else { return false }   // additions or a new order
        let removed = oldKeys.indices.filter { !keep.contains(oldKeys[$0]) }
        if !removed.isEmpty {
            let ips = (0..<passes).flatMap { s in removed.map { IndexPath(item: $0, section: s) } }
            collectionView.performBatchUpdates { collectionView.deleteItems(at: ips) }
        }
        // changed cards: refresh the visible ones in place
        let oldByKey = Dictionary(old.map { (entryKey($0), $0) }, uniquingKeysWith: { a, _ in a })
        let changed = collectionView.indexPathsForVisibleItems.filter { ip in
            ip.item < entries.count && oldByKey[entryKey(entries[ip.item])] != entries[ip.item]
        }
        for ip in changed { (collectionView.cellForItem(at: ip) as? FeedCell)?.refresh(entries[ip.item]) }
        return true
    }

    /// Single mode: one entry per media. Grouped: one entry per post, media in original order.
    private func rebuildEntries() {
        guard grouped else { entries = allItems.map { [$0] }; return }
        entries = order.posts(allItems)
    }

    private func entry(at ip: IndexPath) -> [FeedItem] { entries[ip.item % entries.count] }
    private var sectionCount: Int { entries.isEmpty ? 0 : passes }

    // MARK: Search chips

    func textFieldShouldReturn(_ tf: UITextField) -> Bool {
        commitTypedText()
        exitSearch()
        return true
    }

    func textFieldDidBeginEditing(_ tf: UITextField) { enterSearch() }

    /// A term to search for: a capsule in the field.
    private func addTerm(_ t: String) {
        let t = t.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !t.isEmpty, !terms.contains(t) else { return }
        SearchHistory.add(t)
        insertToken(key: TokenQuery.termKey(t))
        applyTokens()
    }

    private func clearTerms() {
        terms = []
        searchField.tokens = searchField.tokens.filter { !(($0.representedObject as? String)?.hasPrefix("t:") ?? false) }
        updateExitButton()
    }

    /// The × beside the bar: the whole search goes (capsules and text) and the list closes.
    private func clearSearch() {
        searchField.tokens = []
        searchField.text = nil
        applyTokens()
        exitSearch()
        updateExitButton()
    }

    /// A tag was renamed: the search follows the new name.
    private func replaceTerm(_ old: String, with new: String) {
        guard let i = terms.firstIndex(of: old) else { return }
        terms[i] = new
        if let k = searchField.tokens.firstIndex(where: { ($0.representedObject as? String) == TokenQuery.termKey(old) }) {
            searchField.removeToken(at: k)
            searchField.insertToken(makeToken(TokenQuery.termKey(new)), at: k)
        }
    }

    private func filterChip(_ title: String, color: UIColor, id: String, remove: @escaping () -> Void) -> UIButton {
        var cfg = UIButton.Configuration.filled()
        cfg.title = title
        cfg.image = UIImage(systemName: "xmark")
        cfg.imagePlacement = .trailing
        cfg.imagePadding = 6
        cfg.preferredSymbolConfigurationForImage = .init(pointSize: 10, weight: .bold)
        cfg.cornerStyle = .capsule
        cfg.baseBackgroundColor = color
        cfg.contentInsets = .init(top: 6, leading: 10, bottom: 6, trailing: 10)
        let b = UIButton(configuration: cfg, primaryAction: UIAction { _ in remove() })
        b.accessibilityIdentifier = id
        b.accessibilityLabel = "移除筛选 \(title)"
        return b
    }

    private func renderChips() {
        chipStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if let a = filter.author {
            chipStack.addArrangedSubview(filterChip("只看 \(a.hasPrefix("@") ? a : "@" + a)", color: .systemIndigo, id: "chip-author") { [weak self] in
                self?.filter.author = nil; self?.renderChips(); self?.reload() })
        }
        for l in filter.labels {
            chipStack.addArrangedSubview(filterChip("仅 #\(l)", color: .systemGreen, id: "chip-label-\(l)") { [weak self] in
                self?.filter.labels.removeAll { $0 == l }; self?.renderChips(); self?.reload() })
        }
        if filter.looseOnly {
            chipStack.addArrangedSubview(filterChip("散装媒体", color: .systemIndigo, id: "chip-loose") { [weak self] in
                self?.filter.looseOnly = false; self?.renderChips(); self?.reload() })
        }
        if filter.recentOnly {
            chipStack.addArrangedSubview(filterChip("最近添加", color: .systemOrange, id: "chip-recent") { [weak self] in
                self?.filter.recentOnly = false; self?.renderChips(); self?.reload() })
        }
        if let k = filter.kind {
            chipStack.addArrangedSubview(filterChip(k == .video ? "只看视频" : "只看图片", color: .systemPink, id: "chip-kind") { [weak self] in
                self?.filter.kind = nil; self?.renderChips(); self?.reload() })
        }
        if let f = filter.folder {
            chipStack.addArrangedSubview(filterChip("文件夹：\(f)", color: .systemTeal, id: "chip-folder") { [weak self] in
                self?.filter.folder = nil; self?.renderChips(); self?.reload() })
        }
        if LibraryPrefs.badOnly {
            chipStack.addArrangedSubview(filterChip("已损坏", color: .systemRed, id: "chip-bad") { LibraryPrefs.badOnly = false })
        }
        // the chip row is there only when something filters the timeline
        let empty = chipStack.arrangedSubviews.isEmpty
        if chipScroll.isHidden != empty {
            UIView.animate(withDuration: 0.25, delay: 0, usingSpringWithDamping: 0.86, initialSpringVelocity: 0) {
                self.chipScroll.isHidden = empty
                self.chipScroll.alpha = empty ? 0 : 1
                self.view.layoutIfNeeded()
            }
        }
    }

    // MARK: Search mode

    /// Tapping the field: the list of suggestions (or filters) opens under it.
    private func enterSearch() {
        guard !searching else { return }
        searching = true
        detachInline()   // (not just paused: a paused video layer can go black)
        tagCache = Core.allTags()
        rebuildSuggestions()
        suggestions.isHidden = false
        view.bringSubviewToFront(suggestions)
        view.bringSubviewToFront(header)
        view.bringSubviewToFront(exitButton)
        view.bringSubviewToFront(exportButton)
        UIView.animate(withDuration: 0.25, delay: 0, usingSpringWithDamping: 0.86, initialSpringVelocity: 0) { self.suggestions.alpha = 1 }
        updateExitButton()
    }

    /// Return or another tab: the list closes; the search itself stays.
    private func exitSearch() {
        searchField.resignFirstResponder()
        guard searching else { return }
        searching = false
        commitTypedText()
        updateExitButton()
        UIView.animate(withDuration: 0.22, delay: 0, usingSpringWithDamping: 0.86, initialSpringVelocity: 0, animations: {
            self.suggestions.alpha = 0
        }) { _ in
            if !self.searching { self.suggestions.isHidden = true }
            self.view.bringSubviewToFront(self.bottomBar)
            self.view.bringSubviewToFront(self.activityPanel)
            self.view.bringSubviewToFront(self.toast)
            self.updateInlinePlayback()
        }
    }

    @objc private func searchTextChanged() {
        if searchField.markedTextRange == nil {
            // a word followed by a space becomes a capsule (a condition, or text to search for)
            let (keys, rest) = TokenQuery.split(searchField.text ?? "")
            if !keys.isEmpty {
                for k in keys { addKey(k) }
                searchField.text = rest
            }
            applyTokens()
        }
        if searching { rebuildSuggestions() }
    }

    /// A capsule from typed text. A word right after a pending "文件夹" capsule names the folder
    /// (matched to an existing folder regardless of case); a second folder replaces the first.
    private func addKey(_ key: String) {
        var k = key
        if k.hasPrefix("t:"), (searchField.tokens.last?.representedObject as? String) == TokenQuery.pendingFolder {
            searchField.removeToken(at: searchField.tokens.count - 1)
            k = TokenQuery.folderKey(String(k.dropFirst(2)))
        }
        if k.hasPrefix("d:") {
            let typed = String(k.dropFirst(2))
            let name = Core.folders().first { $0.name.lowercased() == typed.lowercased() }?.name ?? typed
            k = TokenQuery.folderKey(name)
            searchField.tokens = searchField.tokens.filter { !(($0.representedObject as? String)?.hasPrefix("d:") ?? false) }
        }
        guard !searchField.tokens.contains(where: { ($0.representedObject as? String) == k }) else { return }
        if k.hasPrefix("t:") {
            let t = String(k.dropFirst(2)).lowercased()
            k = TokenQuery.termKey(t)
            SearchHistory.add(t)
        }
        insertToken(key: k)
    }

    /// Text left in the field when the search closes becomes a capsule too (the last word may
    /// be a condition, or a folder's name after "文件夹", typed without a space after it).
    private func commitTypedText() {
        let t = (searchField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        searchField.text = nil
        if !t.isEmpty { addKey(SearchKeyword.from(t)?.key ?? TokenQuery.termKey(t)) }
        // a "文件夹" capsule still waiting for a name means nothing: it goes
        if (searchField.tokens.last?.representedObject as? String) == TokenQuery.pendingFolder { searchField.removeToken(at: searchField.tokens.count - 1) }
        applyTokens()
    }

    /// What a capsule reads.
    private func tokenTitle(_ key: String) -> String {
        if key.hasPrefix("t:") { return String(key.dropFirst(2)) }
        if key.hasPrefix("d:") { return "文件夹：" + key.dropFirst(2) }
        if key == TokenQuery.pendingFolder { return "文件夹…" }
        return SearchKeyword.all.first { $0.key == key }?.info.word ?? key
    }

    private func makeToken(_ key: String) -> UISearchToken {
        let token: UISearchToken
        if key.hasPrefix("t:") {
            token = UISearchToken(icon: nil, text: String(key.dropFirst(2)))
        } else if key.hasPrefix("d:") {
            token = UISearchToken(icon: UIImage(systemName: "folder"), text: "文件夹：" + key.dropFirst(2))
        } else if key == TokenQuery.pendingFolder {
            token = UISearchToken(icon: UIImage(systemName: "folder"), text: "文件夹…")
        } else if let kw = SearchKeyword.all.first(where: { $0.key == key }) {
            token = UISearchToken(icon: UIImage(systemName: kw.info.symbol), text: kw.info.word)
        } else {
            token = UISearchToken(icon: nil, text: key)
        }
        token.representedObject = key
        return token
    }

    private func insertToken(key: String) {
        searchField.insertToken(makeToken(key), at: searchField.tokens.count)
    }

    /// The capsules decide the search: conditions, then the texts (all must match).
    private func applyTokens() {
        let q = TokenQuery(keys: searchField.tokens.compactMap { $0.representedObject as? String })
        updateExitButton()
        guard q.terms != terms || q.scope != scope || q.searchFields != fields || q.folder != tokenFolder || q.recent != tokenRecent || q.external != tokenExternal || q.kind != tokenKind else { return }
        terms = q.terms
        scope = q.scope
        fields = q.searchFields
        tokenFolder = q.folder
        tokenRecent = q.recent
        tokenExternal = q.external
        tokenKind = q.kind
        reload()
    }

    /// The × shows while searching and while a search is in effect; it also says (to VoiceOver)
    /// what the search is.
    private func updateExitButton() {
        let words = searchField.tokens.compactMap { ($0.representedObject as? String).map(tokenTitle) } + [searchField.text ?? ""].filter { !$0.isEmpty }
        let show = searching || !words.isEmpty
        // exporting is offered while a search or a filter is in effect (not while only typing begins)
        let showExport = !words.isEmpty || !currentFilter.isEmpty
        exitButton.accessibilityValue = words.joined(separator: "、")
        guard show != exitShown || showExport != exportShown else { return }
        exitShown = show; exportShown = showExport
        exitButton.isHidden = false; exportButton.isHidden = false
        // switch the old constraints off before the new ones on (never two required ones at odds)
        [headerTrailing, headerBesideExit, headerBesideExport, exportBesideExit, exportAtEdge].forEach { $0?.isActive = false }
        headerTrailing.isActive = !show && !showExport
        headerBesideExit.isActive = show && !showExport
        headerBesideExport.isActive = showExport
        exportBesideExit.isActive = show
        exportAtEdge.isActive = !show
        UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.85, initialSpringVelocity: 0) {
            for (b, on) in [(self.exitButton, show), (self.exportButton, showExport)] {
                b.alpha = on ? 1 : 0
                b.transform = on ? .identity : CGAffineTransform(scaleX: 0.6, y: 0.6)
            }
            self.view.layoutIfNeeded()
        } completion: { _ in
            if !self.exitShown && self.exitButton.alpha == 0 { self.exitButton.isHidden = true }
            if !self.exportShown && self.exportButton.alpha == 0 { self.exportButton.isHidden = true }
        }
    }

    // MARK: Export of a search

    /// The export button: a small popover (the switches, then 导出) for exactly the media the
    /// search shows now.
    private func showExport() {
        searchField.resignFirstResponder()
        guard shownGeneration == reloadGeneration else { return alert("正在搜索", "等搜索结果出来后再导出。") }
        let ids = allItems.map(\.mediaId)
        let host = UIHostingController(rootView: SearchExportView(count: ids.count) { [weak self] in
            self?.dismiss(animated: true) {
                let options = SearchExportPrefs.options
                self?.exportAndShare(fileName: SearchExportPrefs.fileName()) { out in try Core.exportMedia(ids, options: options, to: out) }
            }
        })
        host.modalPresentationStyle = .popover
        host.sizingOptions = .preferredContentSize
        if let pop = host.popoverPresentationController {
            pop.sourceView = exportButton
            pop.sourceRect = exportButton.bounds
            pop.permittedArrowDirections = [.up, .down]
            pop.delegate = self
        }
        present(host, animated: true)
    }

    /// A real popover on the iPhone too (not a full sheet).
    func adaptivePresentationStyle(for controller: UIPresentationController, traitCollection: UITraitCollection) -> UIModalPresentationStyle { .none }

    private func updatePlaceholder() {
        searchField.placeholder = "搜索标签、贴文、用户、文件夹"
    }

    private func updateSuggestionFooter() {
        let stats = ActivityCenter.shared.statsLine
        let tip = "输入「标签」「贴文」「用户」「我的」「AI」「共同」「视频」「照片」「文件夹」「最近」「外部导入」后按空格，变成条件胶囊；其他词按空格变成要搜索的内容，可以和条件穿插。「文件夹」后面接文件夹名。"
        suggestions.setFooter((stats.isEmpty ? "" : stats + "\n") + tip)
    }

    private func rebuildSuggestions() {
        let typed = (searchField.text ?? "").trimmingCharacters(in: .whitespaces)
        suggestions.sections = tokenSuggestions(typed)
        updateSuggestionFooter()
    }

    private func matchingTags(_ typed: String, limit: Int = 8) -> [TagCount] {
        let q = typed.lowercased()
        guard !q.isEmpty else { return [] }
        return Array(tagCache.filter { $0.label.lowercased().contains(q) && !terms.contains($0.label) }.sorted { $0.count > $1.count }.prefix(limit))
    }

    private func matchingFolders(_ typed: String) -> [(name: String, count: Int)] {
        let q = typed.lowercased()
        guard !q.isEmpty else { return [] }
        return Core.folders().filter { $0.name.lowercased().contains(q) }
    }

    /// Token style: the conditions still available (completing what is typed), matching tags,
    /// folders, and recent searches.
    private func tokenSuggestions(_ typed: String) -> [SearchSuggestionsView.Section] {
        typealias Row = SearchSuggestionsView.Row
        let present = Set(searchField.tokens.compactMap { $0.representedObject as? String })
        var out: [SearchSuggestionsView.Section] = []
        let pickFolder = { [weak self] (name: String) in
            self?.searchField.text = nil
            self?.addKey(TokenQuery.folderKey(name))
            self?.applyTokens()
            self?.rebuildSuggestions()
        }
        // right after "文件夹": the folders (matching what is typed)
        if (searchField.tokens.last?.representedObject as? String) == TokenQuery.pendingFolder {
            let all = Core.folders()
            let shown = typed.isEmpty ? all : all.filter { $0.name.lowercased().contains(typed.lowercased()) }
            out.append(.init(title: "选择文件夹", rows: shown.isEmpty ? [Row(id: "noFolder", title: all.isEmpty ? "还没有文件夹" : "没有匹配的文件夹", symbol: "folder")] : shown.map { f in
                Row(id: "folder-" + f.name, title: f.name, subtitle: "\(f.count) 个媒体", symbol: "folder", tint: .systemTeal) { pickFolder(f.name) }
            }))
            return out
        }
        let kws = SearchKeyword.all.filter { kw in
            !present.contains(kw.key) && (typed.isEmpty || ([kw.info.word] + kw.info.aliases).contains { $0.lowercased().hasPrefix(typed.lowercased()) })
        }
        if !kws.isEmpty {
            out.append(.init(title: "条件", rows: kws.map { kw in
                Row(id: "kw-" + kw.info.word, title: kw.info.word, subtitle: kw.info.hint, symbol: kw.info.symbol) { [weak self] in
                    self?.searchField.text = nil
                    self?.addKey(kw.key)
                    self?.applyTokens()
                    self?.rebuildSuggestions()
                }
            }))
        }
        if !typed.isEmpty {
            var rows: [Row] = [Row(id: "term", title: "搜索「\(typed)」", symbol: "magnifyingglass") { [weak self] in
                self?.searchField.text = nil
                self?.addTerm(typed)
                self?.rebuildSuggestions()
            }]
            rows += matchingTags(typed).map { t in
                Row(id: "tag-" + t.label, title: t.label, subtitle: "\(t.count) 个媒体", symbol: "tag") { [weak self] in
                    self?.searchField.text = nil
                    self?.addTerm(t.label)
                    self?.rebuildSuggestions()
                }
            }
            out.append(.init(title: "搜索内容", rows: rows))
            let folders = matchingFolders(typed)
            if !folders.isEmpty {
                out.append(.init(title: "文件夹", rows: folders.map { f in
                    Row(id: "folder-" + f.name, title: f.name, subtitle: "只看这个文件夹（\(f.count) 个媒体）", symbol: "folder", tint: .systemTeal) { pickFolder(f.name) }
                }))
            }
        } else {
            let recent = SearchHistory.items.filter { !terms.contains($0) }.prefix(6)
            if !recent.isEmpty {
                out.append(.init(title: "最近搜索", rows: recent.map { t in
                    Row(id: "recent-" + t, title: t, symbol: "clock.arrow.circlepath", tint: .secondaryLabel) { [weak self] in
                        self?.addTerm(t); self?.rebuildSuggestions()
                    }
                } + [Row(id: "clearHistory", title: "清除搜索记录", destructive: true) { SearchHistory.clear(); self.rebuildSuggestions() }]))
            }
        }
        return out
    }

    @objc private func groupChanged() {
        grouped = groupSwitch.isOn
        UserDefaults.standard.set(grouped, forKey: "grouped")
        rebuildEntries()
        passes = initialPasses()
        collectionView.reloadData()
        DispatchQueue.main.async { self.updateInlinePlayback() }
    }

    @objc private func openManage() {
        let vc = ManageViewController()
        vc.onLibraryChanged = { [weak self] in self?.reload(keepPosition: true) }
        let nav = UINavigationController(rootViewController: vc)
        nav.modalPresentationStyle = .formSheet
        present(nav, animated: true)
    }

    private var pendingReload: DispatchWorkItem?

    @objc private func libraryChanged(_ n: Notification) {
        if n.object as AnyObject? === self { return }   // our own change, already applied
        pendingReload?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self, self.presentedViewController == nil || self.presentedViewController is UINavigationController else { return }
            self.reload(keepPosition: true)
        }
        pendingReload = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: w)
    }

    @objc private func reshuffle() {
        order.reshuffle()
        savedBrowse = nil   // a new order: the old position means nothing
        reload()
    }

    // MARK: Collection

    func numberOfSections(in cv: UICollectionView) -> Int { sectionCount }

    func collectionView(_ cv: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        entries.count
    }

    func collectionView(_ cv: UICollectionView, viewForSupplementaryElementOfKind kind: String, at ip: IndexPath) -> UICollectionReusableView {
        let v = cv.dequeueReusableSupplementaryView(ofKind: kind, withReuseIdentifier: LoopSeparatorView.kind, for: ip) as! LoopSeparatorView
        v.configure(count: entries.count, grouped: grouped, pass: ip.section + 1, end: !loops)
        return v
    }

    func collectionView(_ cv: UICollectionView, cellForItemAt ip: IndexPath) -> UICollectionViewCell {
        let cell = cv.dequeueReusableCell(withReuseIdentifier: FeedCell.reuseID, for: ip) as! FeedCell
        cell.delegate = self
        cell.highlight = terms
        cell.refresh(entry(at: ip))
        return cell
    }

    /// Decode upcoming images before their cards appear (same size the cells request).
    func collectionView(_ cv: UICollectionView, prefetchItemsAt ips: [IndexPath]) {
        guard !entries.isEmpty else { return }
        for ip in ips { if let first = entry(at: ip).first { MediaPageView.prefetch(first) } }
    }

    /// A card came on screen: re-check which video plays (a short result list never scrolls,
    /// so scrolling alone would never start it).
    func collectionView(_ cv: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt ip: IndexPath) {
        scheduleInlineUpdate()
    }

    /// Re-checks which video plays at most every 0.12 s, also while scrolling: a video starts
    /// as soon as it is (mostly) in view, not only once the scrolling stops. (A delay restarted
    /// by every scroll event only fired after the scrolling had settled.)
    private func scheduleInlineUpdate() {
        guard pendingInline == nil else { return }
        let w = DispatchWorkItem { [weak self] in
            self?.pendingInline = nil
            self?.updateInlinePlayback()
        }
        pendingInline = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: w)
    }

    func collectionView(_ cv: UICollectionView, didEndDisplaying cell: UICollectionViewCell, forItemAt ip: IndexPath) {
        if let host = inlineHost, host.isDescendant(of: cell) { detachInline() }
    }

    func scrollViewDidScroll(_ sv: UIScrollView) {
        guard sv === collectionView else { return }
        appendPassIfNearEnd()
        scheduleInlineUpdate()
    }

    private func appendPassIfNearEnd() {
        guard !entries.isEmpty, loops else { return }
        let remaining = collectionView.contentSize.height - (collectionView.contentOffset.y + collectionView.bounds.height)
        guard remaining < collectionView.bounds.height * 3 else { return }
        // After a reload the view may not have re-read its data yet: inserting then would be an
        // invalid batch update. Asking for the count syncs it; only append when it matches.
        guard collectionView.numberOfSections == sectionCount else { return }
        let start = passes
        passes += 1
        UIView.performWithoutAnimation { collectionView.insertSections(IndexSet(integer: start)) }
    }

    func feedCellPageDidChange(_ cell: FeedCell) { updateInlinePlayback() }

    func feedCell(_ cell: FeedCell, didTapTag label: String) { addTerm(label) }
    func feedCellDidTapRecent(_ cell: FeedCell) {
        guard !filter.recentOnly else { return }
        filter.recentOnly = true; renderChips(); reload()
    }

    /// Long-press menu of a tag chip.
    func feedCell(_ cell: FeedCell, menuForTag t: TagView, of item: FeedItem) -> UIMenu {
        UIMenu(title: t.label, children: tagActions(t, item: item))
    }

    func feedCell(_ cell: FeedCell, didTapPage index: Int) {
        guard let item = cell.currentItem else { return }
        // a video goes on from where it was playing in the card
        let time = item.kind == .video && inlineHost === cell.currentPageView ? inlinePlayer.currentTime() : .zero
        let vc: UIViewController
        // every media of the list, photos and videos alike, so swiping goes on into the next post
        // (found by the media itself: with posts not grouped, a post's media are separate entries)
        let all = entries.flatMap { $0 }
        if let start = all.firstIndex(where: { $0.mediaId == item.mediaId }) {
            vc = PhotoViewController(items: all, index: start, videoStart: time)
        } else {
            vc = PhotoViewController(items: cell.items, index: index, videoStart: time)
        }
        vc.modalPresentationStyle = .fullScreen
        present(vc, animated: true)
    }

    /// Attaches the shared muted player to the video page closest to the viewport's center.
    private func updateInlinePlayback() {
        guard viewIfLoaded?.window != nil, presentedViewController == nil else { return }
        let visible = collectionView.bounds.inset(by: collectionView.adjustedContentInset)
        var best: (MediaPageView, CGFloat)?
        for cell in collectionView.visibleCells.compactMap({ $0 as? FeedCell }) {
            guard let page = cell.currentPageView, page.item?.kind == .video else { continue }
            let f = page.convert(page.bounds, to: collectionView).intersection(visible)
            let ratio = f.isNull ? 0 : (f.width * f.height) / max(page.bounds.width * page.bounds.height, 1)
            if ratio > 0.6, ratio > (best?.1 ?? 0) { best = (page, ratio) }
        }
        guard let target = best?.0 else { detachInline(); return }
        guard target !== inlineHost else { return }
        detachInline()
        guard let item = target.item else { return }
        inlineHost = target
        // Load the asset off the main thread, then attach.
        let asset = AVURLAsset(url: item.fileURL)
        Task { [weak self, weak target] in
            _ = try? await asset.load(.isPlayable)
            let playerItem = AVPlayerItem(asset: asset)
            await MainActor.run {
                guard let self, let target, self.inlineHost === target, target.item?.mediaId == item.mediaId else { return }
                self.inlinePlayer.replaceCurrentItem(with: playerItem)
                CATransaction.begin(); CATransaction.setDisableActions(true)
                target.playerLayer.opacity = 0
                CATransaction.commit()
                target.playerLayer.player = self.inlinePlayer
                self.readyObservation = target.playerLayer.observe(\.isReadyForDisplay, options: [.initial, .new]) { layer, _ in
                    guard layer.isReadyForDisplay else { return }
                    DispatchQueue.main.async {
                        CATransaction.begin(); CATransaction.setDisableActions(true)
                        layer.opacity = 1
                        CATransaction.commit()
                    }
                }
                target.playBadge.isHidden = true
                target.accessibilityValue = "自动播放中（静音）"
                self.inlinePlayer.play()
            }
        }
    }

    /// Stops the inline video and takes it off its card: the card's still frame shows again.
    /// (Every pause goes through here: a paused video layer left on a card can lose its frame —
    /// after the full-screen player, or in the background — and then shows black.)
    private func detachInline() {
        inlinePlayer.pause()
        readyObservation = nil
        inlineHost?.playerLayer.player = nil
        inlineHost?.playBadge.isHidden = inlineHost?.item?.kind != .video
        inlineHost?.accessibilityValue = nil
        inlineHost = nil
    }

    // MARK: Tag editing

    /// The long-press preview has the card's own rounded shape (the system's rectangle showed the
    /// background in the four corners).
    private func cardPreview(_ cv: UICollectionView, _ ip: IndexPath) -> UITargetedPreview? {
        guard let cell = cv.cellForItem(at: ip) else { return nil }
        let p = UIPreviewParameters()
        p.visiblePath = UIBezierPath(roundedRect: cell.contentView.bounds, cornerRadius: cell.contentView.layer.cornerRadius)
        p.backgroundColor = .clear
        return UITargetedPreview(view: cell.contentView, parameters: p)
    }
    func collectionView(_ cv: UICollectionView, contextMenuConfiguration config: UIContextMenuConfiguration, highlightPreviewForItemAt ip: IndexPath) -> UITargetedPreview? { cardPreview(cv, ip) }
    func collectionView(_ cv: UICollectionView, contextMenuConfiguration config: UIContextMenuConfiguration, dismissalPreviewForItemAt ip: IndexPath) -> UITargetedPreview? { cardPreview(cv, ip) }

    func collectionView(_ cv: UICollectionView, contextMenuConfigurationForItemsAt ips: [IndexPath], point: CGPoint) -> UIContextMenuConfiguration? {
        guard let ip = ips.first, let cell = cv.cellForItem(at: ip) as? FeedCell, let item = cell.currentItem else { return nil }
        return UIContextMenuConfiguration(actionProvider: { [weak self] _ in
            guard let self else { return nil }
            var top: [UIMenuElement] = []
            if !item.isLoose, let key = item.authorKey {
                top.append(UIAction(title: "只看 \(item.authorDisplay) 的帖子", image: UIImage(systemName: "person.crop.circle")) { _ in self.onlyAuthor(key) })
                if let sn = item.screenName, let u = URL(string: "https://x.com/\(sn)") {
                    top.append(UIAction(title: "在 X 打开 @\(sn) 的主页", image: UIImage(systemName: "arrow.up.right.square")) { _ in UIApplication.shared.open(u) })
                }
            }
            var tagging: [UIMenuElement] = [
                UIAction(title: "为这张媒体添加标签…", image: UIImage(systemName: "tag")) { _ in self.showTagPicker(item, post: cell.items, wholePost: false) },
            ]
            if !item.isLoose {
                tagging.append(UIAction(title: "为整个帖子添加标签…", image: UIImage(systemName: "square.stack")) { _ in self.showTagPicker(item, post: cell.items, wholePost: true) })
            }
            let pending = item.tags.filter { $0.isAI && !$0.isUser }
            if !pending.isEmpty {
                tagging.append(UIAction(title: "认可全部 AI 标签", image: UIImage(systemName: "checkmark.seal")) { _ in
                    pending.forEach { try? Core.addTag($0.label, to: item.mediaId) }
                    self.reload(keepPosition: true)
                })
            }
            let taggers = ModelStore.shared.taggerIds
            if !taggers.isEmpty {
                let ref = Core.MediaRef(mediaId: item.mediaId, path: item.path, kind: item.kind.rawValue, text: item.text)
                // one entry per model (built-in or external), the default starred
                let perModel: [UIMenuElement] = taggers.map { id in
                    UIMenu(title: ModelStore.shared.displayName(id), subtitle: "提示词：" + PromptSets.name(forModel: id), image: UIImage(systemName: id == ModelStore.shared.activeTaggerId ? "star.fill" : ExternalModels.isExternal(id) ? "network" : "cpu"), children: [
                        UIAction(title: "只添加新标签", image: UIImage(systemName: "plus.circle")) { _ in AutoTagger.shared.retag([ref], model: id, replaceOld: false) },
                        UIAction(title: "替换未认可的旧 AI 标签", image: UIImage(systemName: "arrow.triangle.2.circlepath")) { _ in AutoTagger.shared.retag([ref], model: id, replaceOld: true) },
                    ])
                }
                tagging.append(taggers.count == 1
                    ? UIMenu(title: "AI 重新标记", image: UIImage(systemName: "sparkles"), children: (perModel.first as? UIMenu)?.children ?? [])
                    : UIMenu(title: "AI 重新标记", image: UIImage(systemName: "sparkles"), children: perModel))
            }
            if !item.tags.isEmpty {
                tagging.append(UIAction(title: "标签来源…", image: UIImage(systemName: "info.circle")) { _ in self.showSources(item) })
            }
            let perTag: [UIMenuElement] = item.tags.map { t in
                UIMenu(title: t.label, image: UIImage(systemName: t.isAI ? (t.isUser ? "checkmark.seal.fill" : "sparkles") : "tag"), children: self.tagActions(t, item: item))
            }
            var folderItems: [UIMenuElement] = [self.folderAddMenu(title: "加入文件夹", image: "folder.badge.plus", media: [item.mediaId])]
            folderItems.append(self.folderAddMenu(title: "整个帖子加入文件夹", image: "folder.fill.badge.plus", posts: [item.postId]))
            let inFolders = Core.mediaFolders(item.mediaId)
            if !inFolders.isEmpty {
                folderItems.append(UIMenu(title: "移出文件夹", image: UIImage(systemName: "folder.badge.minus"), children: inFolders.map { f in
                    UIMenu(title: f, image: UIImage(systemName: "folder"), children: [
                        UIAction(title: "只移出这张媒体") { _ in _ = try? Core.removeFromFolder(f, media: [item.mediaId]); NotificationCenter.default.post(name: .libraryChanged, object: nil); self.reload(keepPosition: true) },
                        UIAction(title: "移出整个帖子") { _ in _ = try? Core.removeFromFolder(f, posts: [item.postId]); NotificationCenter.default.post(name: .libraryChanged, object: nil); self.reload(keepPosition: true) },
                    ])
                }))
            }
            let redownload = UIAction(title: item.bad == nil ? "重新下载此媒体" : "重新下载（文件已损坏）", image: UIImage(systemName: "arrow.clockwise.icloud"),
                                      attributes: [], state: .off) { _ in self.repair(item) }
            var delete: [UIMenuElement] = []
            if !item.tags.isEmpty {
                delete.append(UIMenu(title: "删除标签", image: UIImage(systemName: "tag.slash"), children: item.tags.map { t in
                    UIAction(title: t.label, image: UIImage(systemName: "minus.circle"), attributes: .destructive) { _ in self.deleteTag(t, from: item) }
                }))
            }
            delete.append(UIAction(title: "删除这张媒体", image: UIImage(systemName: "trash"), attributes: .destructive) { _ in self.deleteMedia([item]) })
            delete.append(UIAction(title: "删除整个帖子（含筛选隐藏及待下载媒体）", image: UIImage(systemName: "trash.square"), attributes: .destructive) { _ in
                self.deletePost(item) })
            var children: [UIMenuElement] = []
            if !top.isEmpty { children.append(UIMenu(title: "", options: .displayInline, children: top)) }
            children.append(UIMenu(title: "", options: .displayInline, children: tagging))
            if !perTag.isEmpty { children.append(UIMenu(title: "", options: .displayInline, children: perTag)) }
            children.append(UIMenu(title: "", options: .displayInline, children: folderItems))
            children.append(UIMenu(title: "", options: .displayInline, children: [redownload]))
            children.append(UIMenu(title: "", options: .displayInline, children: delete))
            return UIMenu(children: children)
        })
    }

    /// Actions for one tag of one media (card menu and the tag chip's own long-press menu).
    private func tagActions(_ t: TagView, item: FeedItem) -> [UIMenuElement] {
        var acts: [UIMenuElement] = [
            UIAction(title: "仅看此标签", image: UIImage(systemName: "line.3.horizontal.decrease.circle")) { [weak self] _ in self?.onlyLabel(t.label) },
            UIAction(title: "搜索此标签", image: UIImage(systemName: "magnifyingglass")) { [weak self] _ in self?.addTerm(t.label) },
        ]
        if t.isAI && !t.isUser {
            acts.append(UIAction(title: "认可", image: UIImage(systemName: "checkmark.seal")) { [weak self] _ in
                try? Core.addTag(t.label, to: item.mediaId); self?.reload(keepPosition: true)
            })
        }
        acts.append(UIAction(title: "重命名此标签…", image: UIImage(systemName: "pencil")) { [weak self] _ in self?.renameTag(t.label) })
        acts.append(UIAction(title: "删除标签", image: UIImage(systemName: "tag.slash"), attributes: .destructive) { [weak self] _ in self?.deleteTag(t, from: item) })
        return acts
    }

    // MARK: Folders

    /// Shows only one folder's media (nil = everything).
    func showFolder(_ name: String?) {
        filter.folder = name
        renderChips()
        reload()
    }

    /// "Add to folder" menu: existing folders plus a new one.
    private func folderAddMenu(title: String, image: String, media: [String] = [], posts: [String] = []) -> UIMenu {
        let pick = UIDeferredMenuElement.uncached { [weak self] done in
            var acts: [UIMenuElement] = Core.folders().map { f in
                UIAction(title: f.name, image: UIImage(systemName: "folder")) { _ in self?.addToFolder(f.name, media: media, posts: posts) }
            }
            acts.append(UIAction(title: "新建文件夹…", image: UIImage(systemName: "folder.badge.plus")) { _ in
                self?.askFolderName { name in self?.addToFolder(name, media: media, posts: posts) }
            })
            done(acts)
        }
        return UIMenu(title: title, image: UIImage(systemName: image), children: [pick])
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
        } catch { alert("无法加入文件夹", error.localizedDescription) }
    }

    func askFolderName(_ done: @escaping (String) -> Void) {
        let a = UIAlertController(title: "新建文件夹", message: nil, preferredStyle: .alert)
        a.addTextField { $0.placeholder = "文件夹名称" }
        a.addAction(UIAlertAction(title: "取消", style: .cancel))
        a.addAction(UIAlertAction(title: "创建", style: .default) { _ in
            let n = (a.textFields?.first?.text ?? "").trimmingCharacters(in: .whitespaces)
            if !n.isEmpty { done(n) }
        })
        present(a, animated: true)
    }

    // MARK: Renaming

    /// Renames a tag on every media (also merges into an existing tag of the new name).
    private func renameTag(_ old: String) {
        let count = Core.allTags().first { $0.label == old }?.count ?? 0
        let a = UIAlertController(title: "重命名标签「\(old)」", message: "所有 \(count) 个带这个标签的媒体都会改用新名字；如果新名字已经存在，两者会合并。正在进行的 AI 标记和其他设备也会自动使用新名字，之后可以撤销。", preferredStyle: .alert)
        a.addTextField { $0.text = old; $0.clearButtonMode = .whileEditing; $0.accessibilityIdentifier = "renameField" }
        a.addAction(UIAlertAction(title: "取消", style: .cancel))
        a.addAction(UIAlertAction(title: "重命名", style: .default) { [weak self] _ in
            let new = (a.textFields?.first?.text ?? "").trimmingCharacters(in: .whitespaces)
            guard !new.isEmpty, new.lowercased() != old else { return }
            do {
                let name = try Core.renameTag(old, to: new)
                self?.replaceTerm(old, with: name)
                if let i = self?.filter.labels.firstIndex(of: old) { self?.filter.labels[i] = name }
                self?.renderChips()
                NotificationCenter.default.post(name: .libraryChanged, object: nil)
                self?.reload(keepPosition: true)
                self?.toast.show("已将「\(old)」改名为「\(name)」", action: "撤销") {
                    try? Core.undoRename(old)
                    NotificationCenter.default.post(name: .libraryChanged, object: nil)
                    self?.reload(keepPosition: true)
                }
            } catch { self?.alert("无法重命名", error.localizedDescription) }
        })
        present(a, animated: true)
    }

    // MARK: Filters, deletion, repair

    private func onlyAuthor(_ key: String) {
        filter.author = key
        renderChips()
        reload()
    }

    private func onlyLabel(_ label: String) {
        if !filter.labels.contains(label) { filter.labels.append(label) }
        renderChips()
        reload()
    }

    private func deleteTag(_ t: TagView, from item: FeedItem) {
        try? Core.removeTag(t.label, from: item.mediaId)
        reload(keepPosition: true)
        toast.show("已删除标签「\(t.label)」", action: "撤销") { [weak self] in
            // Put back the same origin (yours, AI, or endorsed).
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
        let overlay = BusyOverlay(title: "正在重新下载…")
        overlay.show(in: view)
        Task.detached(priority: .userInitiated) {
            let r = Result { try Core.repair(item.mediaId) }
            await MainActor.run {
                overlay.dismiss {}
                switch r {
                case .success(.replaced): self.toast.show("已重新下载，文件已修复")
                case .success(.replacedNew): self.alert("已重新下载", "来源上的文件已经变化：新文件已放在原来的位置，并带上了原来的标签；旧文件移到了回收站。")
                case .success(.fromPeers): self.alert("将从其他设备获取", "这条帖子没有链接，无法从网络下载。下次与其他设备同步时，会自动取回一份完好的副本。")
                case .failure(let e): self.alert("无法重新下载", e.localizedDescription)
                }
                MediaLoader.shared.forget(item)
                NotificationCenter.default.post(name: .libraryChanged, object: nil)
                self.reload(keepPosition: true)
            }
        }
    }

    private func alert(_ title: String, _ message: String? = nil) {
        let a = UIAlertController(title: title, message: message, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "好", style: .default))
        present(a, animated: true)
    }

    func feedCellDidTapAddTag(_ cell: FeedCell) {
        guard let item = cell.currentItem else { return }
        showTagPicker(item, post: cell.items, wholePost: false)
    }

    /// The tag adder (search, existing tags, create): from the "+" chip and from the long-press
    /// menu's "添加标签" items alike.
    private func showTagPicker(_ item: FeedItem, post: [FeedItem], wholePost: Bool) {
        guard let scope = try? Core.postScope(item.postId) else { alert("无法读取帖子", "请重试"); return }
        let picker = TagPickerViewController(media: item, scope: scope, wholePost: wholePost)
        picker.onDone = { [weak self] in self?.reload(keepPosition: true) }
        let nav = UINavigationController(rootViewController: picker)
        if let sheet = nav.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
        present(nav, animated: true)
    }

    private func showSources(_ item: FeedItem) {
        let vc = TagSourcesViewController(item: item)
        let nav = UINavigationController(rootViewController: vc)
        nav.sheetPresentationController?.detents = [.medium(), .large()]
        nav.sheetPresentationController?.prefersGrabberVisible = true
        present(nav, animated: true)
    }

}

/// Full-width divider between two passes of the looping feed.
final class LoopSeparatorView: UICollectionReusableView {
    static let kind = "loop-separator"
    static let height: CGFloat = 64
    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        let left = UIView(), right = UIView()
        [left, right].forEach { $0.backgroundColor = .separator; $0.translatesAutoresizingMaskIntoConstraints = false; addSubview($0) }
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        isAccessibilityElement = true
        accessibilityIdentifier = "loopSeparator"
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor), label.centerYAnchor.constraint(equalTo: centerYAnchor),
            left.centerYAnchor.constraint(equalTo: centerYAnchor), right.centerYAnchor.constraint(equalTo: centerYAnchor),
            left.heightAnchor.constraint(equalToConstant: 1), right.heightAnchor.constraint(equalToConstant: 1),
            left.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24), left.trailingAnchor.constraint(equalTo: label.leadingAnchor, constant: -12),
            right.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 12), right.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(count: Int, grouped: Bool, pass: Int, end: Bool = false) {
        let a = NSMutableAttributedString(attachment: NSTextAttachment(image: UIImage(systemName: end ? "checkmark.circle" : "arrow.counterclockwise")!.withTintColor(.secondaryLabel)))
        a.append(NSAttributedString(string: end ? "  共 \(count) \(grouped ? "条帖子" : "个媒体")，已经到底" : "  已看完全部 \(count) \(grouped ? "条帖子" : "个媒体")，从头再来"))
        label.attributedText = a
        accessibilityLabel = label.text
    }
}

/// Short message above the bottom bar with an optional action (e.g. undo).
final class ToastView: UIView {
    private let label = UILabel()
    private let button = UIButton(type: .system)
    private var action: (() -> Void)?
    private var hideWork: DispatchWorkItem?

    override init(frame: CGRect) {
        super.init(frame: frame)
        let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterialDark))
        blur.translatesAutoresizingMaskIntoConstraints = false
        blur.layer.cornerRadius = 18
        blur.layer.cornerCurve = .continuous
        blur.clipsToBounds = true
        addSubview(blur)
        label.font = .systemFont(ofSize: 15, weight: .medium)
        label.textColor = .white
        label.numberOfLines = 2
        button.titleLabel?.font = .systemFont(ofSize: 15, weight: .bold)
        button.tintColor = .systemYellow
        button.addAction(UIAction { [weak self] _ in self?.action?(); self?.hide() }, for: .touchUpInside)
        button.accessibilityIdentifier = "toastAction"
        let st = UIStackView(arrangedSubviews: [label, button])
        st.spacing = 14
        st.alignment = .center
        st.translatesAutoresizingMaskIntoConstraints = false
        addSubview(st)
        NSLayoutConstraint.activate([
            blur.topAnchor.constraint(equalTo: topAnchor), blur.bottomAnchor.constraint(equalTo: bottomAnchor),
            blur.leadingAnchor.constraint(equalTo: leadingAnchor), blur.trailingAnchor.constraint(equalTo: trailingAnchor),
            st.topAnchor.constraint(equalTo: topAnchor, constant: 12), st.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            st.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18), st.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
        ])
        alpha = 0
        isHidden = true
        accessibilityIdentifier = "toast"
    }
    required init?(coder: NSCoder) { fatalError() }

    func show(_ text: String, action title: String? = nil, _ action: (() -> Void)? = nil) {
        label.text = text
        button.setTitle(title, for: .normal)
        button.isHidden = title == nil
        self.action = action
        hideWork?.cancel()
        isHidden = false
        superview?.bringSubviewToFront(self)
        transform = CGAffineTransform(translationX: 0, y: 12)
        UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.85, initialSpringVelocity: 0.5) { self.alpha = 1; self.transform = .identity }
        let w = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: w)
    }

    func hide() {
        hideWork?.cancel()
        UIView.animate(withDuration: 0.2, delay: 0, usingSpringWithDamping: 0.86, initialSpringVelocity: 0, animations: { self.alpha = 0 }) { _ in self.isHidden = true; self.action = nil }
    }
}


/// A view whose visibility another view follows (the search bar and its separate chip row).
final class FollowedView: UIView {
    weak var follower: UIView?
    override var alpha: CGFloat { didSet { follower?.alpha = alpha } }
    override var isHidden: Bool { didSet { follower?.isHidden = isHidden } }
}
