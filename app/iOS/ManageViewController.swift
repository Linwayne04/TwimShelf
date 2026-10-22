import UIKit
import UniformTypeIdentifiers

/// Library management: totals, live progress, download (single + batch, shared route),
/// compatibility import, export, AI, sync, account, wipe.
final class ManageViewController: FormViewController, UIDocumentPickerDelegate {
    var onLibraryChanged: (() -> Void)?

    private let stats = StatsCardView()
    private let linksView = PlaceholderTextView(placeholder: "每行粘贴一个帖子链接\nhttps://x.com/用户/status/…")
    private let authField = UITextField()
    private let ct0Field = UITextField()
    private var activityCards: [Activity.Kind: ActivityCardView] = [:]
    private var batchURLs: [String] = []
    private var batchFileName: String?
    private var concurrency = Double(UserDefaults.standard.object(forKey: "dl.concurrency") as? Int ?? 3)
    private var intervalMs = Double(UserDefaults.standard.object(forKey: "dl.interval") as? Int ?? 500)
    private var pickerKind: PickerKind = .bookmarks
    /// Folder downloads go into (nil = none). Applies to single links and batches.
    private var downloadFolder: String?
    /// The download page's own progress card (a view can be on one page only).
    private var downloadCard: ActivityCardView?
    private var observers: [NSObjectProtocol] = []

    private enum PickerKind { case bookmarks, legacyZip, looseZip, pack, backupFolder }

    /// Download route (index into `DownloadRoute.allCases`), shared by links and batches.
    private var routeIndex: Int {
        get { min(max(UserDefaults.standard.integer(forKey: "dl.route"), 0), DownloadRoute.allCases.count - 1) }
        set { UserDefaults.standard.set(newValue, forKey: "dl.route") }
    }
    private var route: DownloadRoute { DownloadRoute.allCases[routeIndex] }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "资料库"
        navigationController?.navigationBar.prefersLargeTitles = true
        navigationItem.largeTitleDisplayMode = .always
        // 完成 closes the whole sheet, also with a share sheet or alert still on top of it
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in
            guard let self else { return }
            (self.navigationController?.presentingViewController ?? self.presentingViewController)?.dismiss(animated: true)
        })
        linksView.accessibilityIdentifier = "linksView"
        for (f, p) in [(authField, "auth_token"), (ct0Field, "ct0")] {
            f.placeholder = p; f.isSecureTextEntry = true; f.autocapitalizationType = .none; f.autocorrectionType = .no; f.clearButtonMode = .whileEditing
            f.font = .monospacedSystemFont(ofSize: 15, weight: .regular)
            f.heightAnchor.constraint(greaterThanOrEqualToConstant: 34).isActive = true
        }
        authField.text = Keychain.get("auth_token")
        ct0Field.text = Keychain.get("ct0")
        let nc = NotificationCenter.default
        observers = [ActivityCenter.changed, ModelStore.changed, SyncService.changed, LibraryPrefs.changed].map {
            nc.addObserver(forName: $0, object: nil, queue: .main) { [weak self] _ in self?.build() }
        }
        ActivityCenter.shared.refreshStats()
        build()
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    private func card(_ a: Activity) -> ActivityCardView {
        let c = activityCards[a.kind] ?? ActivityCardView()
        activityCards[a.kind] = c
        c.update(a)
        return c
    }

    /// Top level, grouped as in Settings: library totals and live work first, then content,
    /// viewing, triage, intelligence and sync, account, maintenance, and the destructive reset
    /// last. Forms with fields (download, import, Cookie) live one level down.
    private func build() {
        stats.update(ActivityCenter.shared.stats)
        let acts = ActivityCenter.shared.activities
        var s: [Section] = [
            Section(id: "stats", header: "资料库", footer: "在每台设备上核对这些数字，可以确认同步是否完整。", rows: [.custom("stats", stats)]),
        ]
        if !acts.isEmpty {
            var rows: [Row] = acts.map { .custom("act-\($0.kind.rawValue)", card($0)) }
            if Core.downloadStatus()?.running == true {
                rows.append(.button("取消下载", icon: .init("xmark", .systemRed), destructive: true) { [weak self] in do { try Core.stopDownload(pause: false) } catch { self?.alert("无法取消", error.localizedDescription) } })
            }
            s.append(Section(id: "activity", header: "任务状态", rows: rows))
        }
        if let d = Core.downloadStatus(), !d.running, !d.errors.isEmpty {
            s.append(Section(id: "lastdl", rows: [.navigation("上次下载有 \(d.failed) 个失败", detail: "查看", icon: .init("exclamationmark.triangle.fill", .systemOrange)) { [weak self] in self?.showErrors(d.errors) }]))
        }
        let bad = ActivityCenter.shared.stats?.bad ?? 0
        s += [
            Section(id: "content", header: "内容", rows: [
                .navigation("下载帖子", detail: Core.downloadStatus()?.running == true ? "正在下载" : "链接 · 批量 · Cookie", icon: .init("arrow.down.circle.fill", .systemBlue), id: "n:download") { [weak self] in
                    self?.openSub("下载帖子") { self?.downloadSections() ?? [] } },
                .navigation("导入与备份", detail: "ZIP · 导出包 · 整库备份", icon: .init("shippingbox.fill", .systemBrown), id: "n:transfer") { [weak self] in
                    self?.openSub("导入与备份") { self?.transferSections() ?? [] } },
                .navigation("标签", detail: "\(ActivityCenter.shared.stats?.tags ?? 0) 个", icon: .init("tag.fill", .systemBlue), id: "n:tags") { [weak self] in
                    self?.navigationController?.pushViewController(TagListViewController(style: .insetGrouped), animated: true) },
            ]),
            Section(id: "view", header: "浏览与播放", footer: "「仅用耳机播放声音」：没连耳机时视频先静音，并询问是否开启声音。「视频禁用手势」：播放器里不再拖动调节进度、音量和亮度（长按倍速、双击暂停照常）；在帖子里左右滑动就能在照片和视频之间切换，向下拖动关闭播放器。不开启时，播放器两侧有箭头切换上一个、下一个。", rows: [
            ] + (bad > 0 || LibraryPrefs.badOnly ? [
                .toggle("只显示损坏的媒体（\(bad)）", LibraryPrefs.badOnly, icon: .init("exclamationmark.triangle.fill", .systemRed), id: "t:bad") { on in LibraryPrefs.badOnly = on },
            ] : []) + [
                .toggle("仅用耳机播放声音", AudioPolicy.headphonesOnly, icon: .init("headphones", .systemPink), id: "t:headphones") { on in AudioPolicy.headphonesOnly = on },
                .toggle("视频禁用手势", LibraryPrefs.playerGesturesOff, icon: .init("hand.raised.slash.fill", .systemIndigo), id: "t:playerGestures") { on in LibraryPrefs.playerGesturesOff = on },
                .toggle("横屏视频自动横屏", LibraryPrefs.autoLandscape, icon: .init("rectangle.landscape.rotate", .systemOrange), id: "t:landscape") { on in LibraryPrefs.autoLandscape = on },
                .toggle("主页动态背景", LibraryPrefs.backdrop, icon: .init("sparkles.rectangle.stack.fill", .systemBlue), id: "t:backdrop") { on in LibraryPrefs.backdrop = on },
            ]),
            Section(id: "search", header: "搜索", footer: "在搜索框里输入「标签」「贴文」「用户」「我的」「AI」「共同」「视频」「照片」「文件夹」「最近」「外部导入」后按空格，它们会变成条件胶囊；其他词按空格变成要搜索的内容，可以和条件穿插。不加「标签」「贴文」「用户」时，在标签、帖子正文和作者里一起找。语义模糊搜索：包含匹配，并找意思相近的标签。" + (LibraryPrefs.semanticSearchAvailable ? "" : "\n" + LibraryPrefs.semanticSearchNeedsModel), rows: [
                .toggle("语义模糊搜索", LibraryPrefs.fuzzySearch, enabled: LibraryPrefs.semanticSearchAvailable, icon: .init("sparkle.magnifyingglass", .systemPurple), id: "t:fuzzy") { on in LibraryPrefs.fuzzySearch = on },
            ]),
            Section(id: "triage", header: "整理模式", footer: "一次一个帖子：上滑保留，左滑删除，点下方的文件夹放入。整理进度只保存在这台设备上，不会在设备之间同步；删除和文件夹的结果照常同步。", rows: [
                .toggle("整理模式", LibraryPrefs.triageMode, icon: .init("rectangle.stack.fill", .systemIndigo), id: "t:triage") { on in LibraryPrefs.triageMode = on },
                .button("清空整理记录…", icon: .init("clock.arrow.circlepath", .systemRed), destructive: true, id: "b:triageClear") { [weak self] in self?.confirmClearTriage() },
            ]),
            Section(id: "smart", header: "智能与同步", rows: [
                .navigation("AI 模型", detail: ModelStore.shared.activeTaggerId.map { ModelStore.shared.displayName($0) } ?? "未安装", icon: .init("sparkles", .systemPurple)) { [weak self] in
                    self?.navigationController?.pushViewController(ModelsViewController(), animated: true) },
                .navigation("局域网同步", detail: SyncService.shared.summary, icon: .init("arrow.triangle.2.circlepath", .systemTeal)) { [weak self] in
                    self?.navigationController?.pushViewController(SyncViewController(), animated: true) },
            ]),
            Section(id: "maint", header: "维护", footer: "检查会逐个核对文件，找出损坏或丢失的媒体。诊断信息只含错误记录和数量，不含图片、正文、标签名或 Cookie。", rows: [
                Core.verifyStatus()?.running == true
                    ? .button("停止检查", icon: .init("stop.fill", .systemRed), destructive: true, id: "b:verify") { Core.cancelVerify() }
                    : .button("检查资料库媒体（不含回收站）", icon: .init("checkmark.shield.fill", .systemGreen), id: "b:verify") { [weak self] in
                        do { try Core.startVerify() } catch { self?.alert("无法开始检查", error.localizedDescription) } },
                .value("完整性", Core.integritySummary()?.text ?? "无法读取检查记录", icon: .init("exclamationmark.triangle", .systemOrange), id: "v:bad"),
                .navigation("问题记录", detail: "\(AppLog.problemCount) 条", icon: .init("exclamationmark.bubble.fill", .systemOrange), id: "n:problems") { [weak self] in
                    self?.navigationController?.pushViewController(ProblemsViewController(), animated: true) },
                .button("导出诊断信息…", icon: .init("stethoscope", .systemTeal), id: "b:diag") { [weak self] in self?.exportDiagnostics() },
            ]),
            Section(id: "wipe", footer: "删除这台设备上的全部内容和设置，恢复为全新状态，不会同步到其他设备。", rows: [
                .button("清除所有数据…", icon: .init("trash.fill", .systemRed), destructive: true) { [weak self] in self?.confirmWipe() },
            ]),
        ]
        sections = s
        reloadForm()
        subpage?.rebuild()
    }

    // MARK: Subpages (their fields and state stay here, so nothing is lost going back and forth)

    private weak var subpage: ManageSubpage?

    func openDownloads() {
        openSub("下载帖子") { [weak self] in self?.downloadSections() ?? [] }
        // The search-bar shortcut opens this page directly; allow closing the whole sheet.
        subpage?.navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in
            self?.navigationController?.dismiss(animated: true)
        })
    }

    private func openSub(_ title: String, _ make: @escaping () -> [Section]) {
        let vc = ManageSubpage(title: title, make: make)
        subpage = vc
        navigationController?.pushViewController(vc, animated: true)
    }

    /// Pickers, alerts and sheets started from a subpage are shown on top of it.
    override func present(_ vc: UIViewController, animated: Bool, completion: (() -> Void)? = nil) {
        if viewIfLoaded?.window == nil, let top = navigationController?.topViewController, top !== self {
            top.present(vc, animated: animated, completion: completion)
        } else {
            super.present(vc, animated: animated, completion: completion)
        }
    }

    /// The download page: progress first while a download runs, then the way and the folder (for
    /// the links and the batch alike), the links and the button (kept above the keyboard), batch
    /// import, and the account Cookie that locked-account posts need.
    private func downloadSections() -> [Section] {
        var s: [Section] = []
        if let a = ActivityCenter.shared.activities.first(where: { $0.kind == .download }) {
            let c = downloadCard ?? ActivityCardView()
            downloadCard = c
            c.update(a)
            var rows: [Row] = [.custom("dl-progress", c)]
            if Core.downloadStatus()?.running == true {
                rows.append(.button("暂停下载", icon: .init("pause", .systemOrange), id: "b:dlpause") { [weak self] in do { try Core.stopDownload(pause: true) } catch { self?.alert("无法暂停", error.localizedDescription) } })
                rows.append(.button("取消下载", icon: .init("xmark", .systemRed), destructive: true, id: "b:dlcancel") { [weak self] in do { try Core.stopDownload(pause: false) } catch { self?.alert("无法取消", error.localizedDescription) } })
            }
            s.append(Section(id: "dlprogress", header: Core.downloadStatus()?.outcomeText ?? "下载状态", rows: rows))
        } else if let d = Core.downloadStatus(), d.total > 0 {
            var rows: [Row] = [.value(d.outcomeText, "完成 \(d.done) · 已有 \(d.skipped)" + (d.failed > 0 ? " · 失败 \(d.failed)" : ""), icon: .init("checkmark.circle", .systemGreen), id: "v:lastdl")]
            if !d.errors.isEmpty { rows.append(.navigation("查看失败的链接", detail: "\(d.errors.count) 条", icon: .init("exclamationmark.triangle.fill", .systemOrange)) { [weak self] in self?.showErrors(d.errors) }) }
            s.append(Section(id: "dlprogress", header: "上次下载", rows: rows))
        }
        if let d = Core.downloadStatus(), !d.running, d.paused > 0 {
            s.append(Section(id: "dlpaused", header: "已暂停 \(d.paused) 个任务", footer: "暂停后需手动继续。取消会移除未完成任务，已下载内容保留。", rows: [
                .button("继续下载", icon: .init("play.fill", .systemBlue), id: "b:dlresume") { [weak self] in do { try Core.resumeDownload() } catch { self?.alert("无法继续", error.localizedDescription) } },
                .button("取消这些任务", icon: .init("xmark", .systemRed), destructive: true, id: "b:dlcancelpaused") { [weak self] in do { try Core.stopDownload(pause: false) } catch { self?.alert("无法取消", error.localizedDescription) } },
            ]))
        }
        // the way and the folder come first and apart: they hold for the links below and for the
        // batch import after them (inside the links' section they looked like theirs alone)
        s.append(Section(id: "dlsettings", header: "下载方式与文件夹", footer: "对下面的链接下载和批量导入收藏夹都生效。「自动」先用公开镜像 FxTwitter，拿不到时（例如锁定账号）且已设置 Cookie，就用账号下载。已在资料库里的帖子也会放进所选文件夹。", rows: [
            .menu("下载方式", value: Self.routeNames[routeIndex], icon: .init("point.3.connected.trianglepath.dotted", .systemIndigo), id: "m:route") { [weak self] in self?.routeMenu() ?? UIMenu() },
            .menu("放入文件夹", value: downloadFolder ?? "不放入", icon: .init("folder.fill", .systemTeal), id: "m:folder") { [weak self] in self?.folderMenu() ?? UIMenu() },
        ]))
        s.append(Section(id: "links", header: "下载帖子", footer: "每行一个帖子链接。", rows: [
            .custom("links", linksView),
            .button("下载", icon: .init("arrow.down.circle.fill", .systemBlue), id: "b:download") { [weak self] in self?.downloadLinks() },
        ]))
        s.append(Section(id: "batch", header: "批量导入收藏夹", footer: "选择油猴脚本 Twitter Web Exporter 导出的收藏夹 JSON，逐条下载。并发数是同时下载几个帖子，间隔是每个帖子开始前等待的时间；帖子多时调低并发、加大间隔更稳妥。中断后再次开始会从未完成的帖子继续。下载方式和文件夹沿用最上面的设置。", rows: [
            .button(batchFileName.map { "已载入 \($0)" } ?? "选择 JSON 文件…", icon: .init("doc.badge.plus", .systemIndigo), id: "b:pick") { [weak self] in self?.pick(.bookmarks) },
            .value("帖子数", batchURLs.isEmpty ? "—" : "\(batchURLs.count)", icon: .init("number", .systemGray)),
            .stepper("并发数", value: concurrency, range: 1...16, step: 1, icon: .init("arrow.triangle.branch", .systemTeal), format: { "\(Int($0))" }) { [weak self] v in
                self?.concurrency = v; UserDefaults.standard.set(Int(v), forKey: "dl.concurrency") },
            .stepper("间隔", value: intervalMs, range: 0...10_000, step: 250, icon: .init("timer", .systemOrange), format: { String(format: "%.2f 秒", $0 / 1000) }) { [weak self] v in
                self?.intervalMs = v; UserDefaults.standard.set(Int(v), forKey: "dl.interval") },
            .button("开始批量下载", icon: .init("square.and.arrow.down.on.square", .systemGreen), enabled: !batchURLs.isEmpty) { [weak self] in self?.startBatch() },
        ]))
        return s + cookieSections()
    }

    private func transferSections() -> [Section] {
        [
            Section(id: "legacy", header: "导入", footer: "旧版 ZIP：每个子文件夹是一个帖子。散装媒体 ZIP：只有图片和视频，每个文件成为一个散装媒体。", rows: [
                .button("导入旧版 ZIP…", icon: .init("archivebox.fill", .systemBrown)) { [weak self] in self?.pick(.legacyZip) },
                .button("导入散装媒体 ZIP…", icon: .init("square.dashed", .systemIndigo)) { [weak self] in self?.pick(.looseZip) },
                .button("导入 .tlpack 导出包…", icon: .init("shippingbox.fill", .systemBlue)) { [weak self] in self?.pick(.pack) },
                .navigation("导入记录", detail: nil, icon: .init("list.bullet.rectangle", .systemGray)) { [weak self] in
                    self?.navigationController?.pushViewController(ImportHistoryViewController(), animated: true) },
            ]),
            Section(id: "export", header: "备份", footer: "备份包含全部媒体（含回收站）、正文、标签、文件夹和改名规则，不含 AI 模型、整理记录和设备配对。恢复时在任意设备上导入 .tlpack 即可。要导出一部分内容：在「浏览」里搜索，再点搜索框旁的导出按钮。", rows: [
                .button("备份整个资料库…", icon: .init("externaldrive.fill.badge.timemachine", .systemPurple), id: "b:backup") { [weak self] in self?.pick(.backupFolder) },
            ]),
        ]
    }

    private func cookieSections() -> [Section] {
        [
            Section(id: "cookie", header: "账号 Cookie（锁定账号的帖子需要）", footer: "在浏览器登录 x.com，从开发者工具的 Cookie 中复制 auth_token 与 ct0。仅保存在本机钥匙串，不会同步。", rows: [
                .custom("auth", authField),
                .custom("ct0", ct0Field),
                .button("保存 Cookie", icon: .init("key.fill", .systemYellow)) { [weak self] in self?.saveCookies() },
                .button("检查 Cookie", icon: .init("checkmark.shield", .systemGreen), id: "b:checkCookie") { [weak self] in
                    // a network request of up to ~30 s: never on the main thread
                    self?.runBusy("正在检查 Cookie…", { Core.checkCookies() }) { r in
                        let a = UIAlertController(title: r.title, message: r.detail, preferredStyle: .alert)
                        a.addAction(UIAlertAction(title: "好", style: .default))
                        self?.present(a, animated: true)
                    }
                },
            ]),
        ]
    }

    func exportDiagnostics() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("diagnostics", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmm"
        let out = dir.appendingPathComponent("TwimShelf 诊断 \(f.string(from: Date())).zip")
        runBusy("正在收集诊断信息…", { try Diagnostics.export(to: out) }) { [weak self] _ in
            guard let self else { return }
            let share = UIActivityViewController(activityItems: [out], applicationActivities: nil)
            share.popoverPresentationController?.sourceView = self.view
            share.popoverPresentationController?.sourceRect = CGRect(x: self.view.bounds.midX, y: self.view.bounds.maxY - 80, width: 1, height: 1)
            share.completionWithItemsHandler = { _, _, _, _ in try? FileManager.default.removeItem(at: dir) }
            self.present(share, animated: true)
        }
    }

    /// Two confirmations: the history cannot be brought back (decisions' effects stay).
    private func confirmClearTriage() {
        let n = Core.triageCounts(Core.TriageFilter())?.triaged ?? 0
        let a = UIAlertController(title: "清空整理记录？", message: "这台设备上已整理的 \(n) 个内容会重新出现在整理模式中。已经删除或放入文件夹的结果不会被撤销。", preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "取消", style: .cancel))
        a.addAction(UIAlertAction(title: "继续", style: .destructive) { [weak self] _ in
            let b = UIAlertController(title: "再次确认", message: "清空后无法恢复整理记录。", preferredStyle: .alert)
            b.addAction(UIAlertAction(title: "取消", style: .cancel))
            b.addAction(UIAlertAction(title: "清空整理记录", style: .destructive) { _ in
                _ = try? Core.triageClear()
                NotificationCenter.default.post(name: .libraryChanged, object: nil)
                self?.alert("已清空整理记录")
            })
            self?.present(b, animated: true)
        })
        present(a, animated: true)
    }

    private static let routeNames = ["自动", "仅 FxTwitter", "仅 Cookie"]

    private func routeMenu() -> UIMenu {
        UIMenu(children: DownloadRoute.allCases.enumerated().map { i, _ in
            UIAction(title: Self.routeNames[i], state: i == routeIndex ? .on : .off) { [weak self] _ in
                self?.routeIndex = i; self?.build() }
        })
    }

    private func folderMenu() -> UIMenu {
        var acts: [UIMenuElement] = [UIAction(title: "不放入", state: downloadFolder == nil ? .on : .off) { [weak self] _ in self?.downloadFolder = nil; self?.build() }]
        let folders = Core.folders()
        if !folders.isEmpty {
            acts.append(UIMenu(options: .displayInline, children: folders.map { f in
                UIAction(title: f.name, image: UIImage(systemName: "folder"), state: downloadFolder == f.name ? .on : .off) { [weak self] _ in self?.downloadFolder = f.name; self?.build() } }))
        }
        acts.append(UIMenu(options: .displayInline, children: [UIAction(title: "新建文件夹…", image: UIImage(systemName: "folder.badge.plus")) { [weak self] _ in
            let a = UIAlertController(title: "新建文件夹", message: nil, preferredStyle: .alert)
            a.addTextField { $0.placeholder = "文件夹名称" }
            a.addAction(UIAlertAction(title: "取消", style: .cancel))
            a.addAction(UIAlertAction(title: "创建", style: .default) { _ in
                let n = (a.textFields?.first?.text ?? "").trimmingCharacters(in: .whitespaces)
                if !n.isEmpty { _ = try? Core.createFolder(n); self?.downloadFolder = n; self?.build() }
            })
            self?.present(a, animated: true)
        }]))
        return UIMenu(children: acts)
    }

    // MARK: Actions

    private func downloadLinks() {
        let urls = linksView.text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !urls.isEmpty else { return alert("请先粘贴帖子链接") }
        let bad = urls.filter { Core.fxAPIURL(for: $0) == nil }
        guard bad.isEmpty else { return alert("无法识别的链接", bad.prefix(3).joined(separator: "\n")) }
        do {
            // Links you paste are explicit: posts you deleted earlier come back.
            try Core.startDownload(DownloadRequest(urls: urls, concurrency: Int(concurrency), intervalMs: UInt64(intervalMs), route: route, revive: true, folder: downloadFolder))
            linksView.text = ""
            view.endEditing(true)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            ActivityCenter.shared.refreshNow()   // the progress shows on this page right away
            build()
        } catch { alert("无法开始下载", error.localizedDescription) }
    }

    private func startBatch() {
        do {
            let n = try Core.startDownload(DownloadRequest(urls: batchURLs, concurrency: Int(concurrency), intervalMs: UInt64(intervalMs), route: route, folder: downloadFolder, markRecent: true))
            batchURLs = []; batchFileName = nil
            ActivityCenter.shared.refreshNow()
            build()
            if n == 0 { alert("没有需要下载的帖子") } else { UINotificationFeedbackGenerator().notificationOccurred(.success) }
        } catch { alert("无法开始下载", error.localizedDescription) }
    }

    private func saveCookies() {
        let ok1 = Keychain.set("auth_token", (authField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
        let ok2 = Keychain.set("ct0", (ct0Field.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
        Session.applyStoredCookies()
        view.endEditing(true)
        guard ok1 && ok2 else { return alert("Cookie 没有保存", "钥匙串拒绝了保存，请再试一次。") }
        alert((authField.text ?? "").isEmpty || (ct0Field.text ?? "").isEmpty ? "已清除 Cookie" : "Cookie 已保存")
    }

    private func showErrors(_ errors: [[String]]) {
        let vc = FormViewController()
        vc.title = "失败记录"
        vc.loadViewIfNeeded()
        vc.sections = [.init(id: "e", rows: errors.reversed().enumerated().map { i, e in
            let l = UILabel()
            l.numberOfLines = 0
            l.font = .preferredFont(forTextStyle: .footnote)
            l.text = "\(e.first ?? "")\n\(e.last ?? "")"
            return .custom("e\(i)", l)
        })]
        vc.reloadForm(animated: false)
        navigationController?.pushViewController(vc, animated: true)
    }

    private func confirmWipe() {
        let a = UIAlertController(title: "清除所有数据？", message: "这台设备上的全部帖子、媒体、标签、Cookie 和同步配置都会被永久删除，无法恢复。其他设备不受影响。\n已安装的 AI 模型默认保留（不必重新下载）。", preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "取消", style: .cancel))
        for (title, models) in [("清除（保留 AI 模型）", false), ("连同 AI 模型一起清除", true)] {
            a.addAction(UIAlertAction(title: title, style: .destructive) { [weak self] _ in
                let b = UIAlertController(title: "再次确认", message: "输入「清除」以确认。" + (models ? "\nAI 模型也会被删除，之后需要重新下载。" : ""), preferredStyle: .alert)
                b.addTextField()
                b.addAction(UIAlertAction(title: "取消", style: .cancel))
                b.addAction(UIAlertAction(title: "清除所有数据", style: .destructive) { _ in
                    guard b.textFields?.first?.text == "清除" else { return }
                    self?.performWipe(includeModels: models)
                })
                self?.present(b, animated: true)
            })
        }
        present(a, animated: true)
    }

    private func performWipe(includeModels: Bool) {
        AutoTagger.shared.stop()
        runBusy("正在清除…", {
            // a wipe that keeps the AI settings keeps the custom prompt too (it lives in the library)
            let keptPrompt = includeModels ? nil : Core.setting("ai.prompt")
            try Core.wipe(includeModels: includeModels)
            if let keptPrompt { Core.setSetting("ai.prompt", keptPrompt) }
            ShareInbox.wipe()
            AppLog.wipe()
            Keychain.wipeAll()
            Core.setCookies(authToken: "", ct0: "")
            let d = UserDefaults.standard
            d.dictionaryRepresentation().keys.filter { includeModels || !Core.aiPreferenceKeys.contains($0) }.forEach { d.removeObject(forKey: $0) }
        }) { [weak self] in
            if includeModels { ModelStore.shared.wipe() } else { ModelStore.shared.reload() }
            SyncService.shared.resetForWipe()
            self?.authField.text = ""; self?.ct0Field.text = ""
            NotificationCenter.default.post(name: .libraryChanged, object: nil)
            ActivityCenter.shared.refreshStats()
            self?.build()
            self?.alert("已清除", "应用已恢复为全新状态。")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { ModelStore.shared.configure(); SyncService.shared.start() }
        }
    }

    // MARK: Document picking

    private func pick(_ kind: PickerKind) {
        pickerKind = kind
        let types: [UTType] = switch kind {
        case .bookmarks: [.json]
        case .legacyZip, .looseZip: [.zip]
        case .pack: [.tlpack, .zip]
        case .backupFolder: [.folder]
        }
        // a folder is opened in place (the backup is written straight into it); files are copied
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: kind != .backupFolder)
        picker.delegate = self
        present(picker, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        switch pickerKind {
        case .bookmarks:
            do { batchURLs = try Core.bookmarkURLs(in: url); batchFileName = url.lastPathComponent; build() }
            catch { alert("无法读取 JSON", error.localizedDescription) }
            // the links are read: the picker's copy is not needed any more
            if Self.isInsideTemporary(url) { try? FileManager.default.removeItem(at: url) }
        case .legacyZip:
            chooseTargetFolder(title: "导入到文件夹？", suggested: url.deletingPathExtension().lastPathComponent) { [weak self] folder in self?.importZip(url, folder: folder) }
        case .looseZip:
            chooseTargetFolder(title: "导入到文件夹？", suggested: url.deletingPathExtension().lastPathComponent) { [weak self] folder in
                self?.runBusy("正在导入…", { try Core.importLooseZip(url, folder: folder) }) { r in
                    self?.releasePickedCopy(url, r)
                    self?.showImportResult(r)
                    NotificationCenter.default.post(name: .libraryChanged, object: nil)
                }
            }
        case .pack:
            chooseTargetFolder(title: "导入到文件夹？", suggested: url.deletingPathExtension().lastPathComponent) { [weak self] folder in self?.importPack(url, folder: folder) }
        case .backupFolder:
            backup(into: url)
        }
    }

    /// Files picked in Files arrive as the app's own copy (it can be gigabytes). When nothing in
    /// it needs attention, nobody will ever export problem files from it: delete it now.
    /// Otherwise it stays until the import record is deleted.
    /// Whether a picked file is the system's copy in our temporary folder (compared by path
    /// components: "/tmp2/x" is not inside "/tmp").
    static func isInsideTemporary(_ url: URL) -> Bool {
        let tmp = FileManager.default.temporaryDirectory.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let p = url.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        return p.count > tmp.count && Array(p.prefix(tmp.count)) == tmp
    }

    private func releasePickedCopy(_ url: URL, _ r: ImportReport) {
        guard r.skipped.isEmpty, Self.isInsideTemporary(url) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Writes the whole-library backup straight into the chosen folder, with live progress.
    private func backup(into folder: URL) {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HHmm"
        let out = folder.appendingPathComponent("TwimShelf 备份 \(f.string(from: Date()))").appendingPathExtension("tlpack")
        let access = folder.startAccessingSecurityScopedResource()
        runBusy("正在备份整个资料库…", progress: {
            guard let p = Core.exportStatus(), p.total > 0 else { return nil }
            return "\(p.done) / \(p.total) 个媒体 · \(ActivityCenter.bytes(p.bytes))"
        }, cancel: { Core.cancelExport() }, {
            // released on success and on failure (runBusy shows failures itself)
            defer { if access { folder.stopAccessingSecurityScopedResource() } }
            return try Core.exportBackup(to: out)
        }) { [weak self] r in self?.showBackupResult(r, file: out) }
    }

    private func showBackupResult(_ r: ExportReport, file: URL) {
        var t = "已备份 \(r.posts) 个帖子、\(r.media) 个媒体（其中回收站 \(r.trashed ?? 0) 个）· \(ActivityCenter.bytes(r.bytes))\n文件：\(file.lastPathComponent)"
        let skipped = r.skipped ?? []
        if !skipped.isEmpty {
            t += "\n\n有 \(skipped.count) 个媒体没有备份："
            for s in skipped.prefix(15) { t += "\n· \(s.postId.hasPrefix("loose:") ? "散装媒体" : "帖子 \(s.postId)") 的 \(s.mediaId.prefix(10))…：\(s.reason)" }
            if skipped.count > 15 { t += "\n……还有 \(skipped.count - 15) 个" }
        }
        alert(skipped.isEmpty ? "备份完成" : "备份完成（有遗漏）", t)
    }

    private func importZip(_ url: URL, folder: String?) {
            runBusy("正在导入…", { try Core.importLegacyZip(url, folder: folder) }) { [weak self] r in
                self?.releasePickedCopy(url, r)
                self?.showImportResult(r)
                NotificationCenter.default.post(name: .libraryChanged, object: nil)
            }
    }

    private func importPack(_ url: URL, folder: String?) {
            runBusy("正在导入…", { try Core.importPack(url, folder: folder) }) { [weak self] r in
                self?.releasePickedCopy(url, r)
                self?.showImportResult(r, extra: "\n标签、来源与文件夹已一并恢复")
                NotificationCenter.default.post(name: .libraryChanged, object: nil)
            }
    }
}

/// One level below the library page: its sections come from the library page, which owns the
/// fields and state, and rebuilds this page whenever it rebuilds itself.
final class ManageSubpage: FormViewController {
    private let make: () -> [Section]
    init(title: String, make: @escaping () -> [Section]) {
        self.make = make
        super.init(nibName: nil, bundle: nil)
        self.title = title
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.largeTitleDisplayMode = .never
        rebuild()
    }

    func rebuild() {
        guard isViewLoaded else { return }
        sections = make()
        reloadForm()
    }
}
