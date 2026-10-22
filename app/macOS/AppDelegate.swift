import AppKit
import SwiftUI

@main
final class AppDelegate: NSObject, NSApplicationDelegate, NSToolbarDelegate, NSSearchFieldDelegate {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }

    private var window: NSWindow!
    private let feed = MacFeedViewController()
    private lazy var main = MacSettingsWindowController()
    /// The search, the same as on iOS: capsules for conditions and text, and an × to end it.
    private let tokenSearch = MacTokenSearch()
    /// The window's content: the sidebar, and the timeline or a collection beside it.
    private lazy var root = MacRootViewController(feed: feed)

    func applicationDidFinishLaunching(_ notification: Notification) {
        if !Core.open() { AppLog.error("lifecycle", "无法打开资料库"); macAlert(nil, "无法打开资料库", Core.libraryDirectory.path) }
        #if DEBUG
        if let out = ProcessInfo.processInfo.environment["TL_MEMORY_AUDIT"],
           let models = ProcessInfo.processInfo.environment["TL_MEMORY_AUDIT_MODELS"],
           ProcessInfo.processInfo.environment["TL_LIBRARY_DIR"] != nil {
            Core.setModelsDirectory(URL(fileURLWithPath: models, isDirectory: true))
            Task {
                await AIEngine.shared.auditIdleMemory(to: URL(fileURLWithPath: out))
                NSApp.terminate(nil)
            }
            return
        }
        if let out = ProcessInfo.processInfo.environment["TL_SETTINGS_LAYOUT_TEST"],
           ProcessInfo.processInfo.environment["TL_LIBRARY_DIR"] != nil {
            runSettingsLayoutAudit(out)
            return
        }
        #endif
        CrashWatch.shared.start()
        #if !DEBUG
        Keychain.migrateDebugSecrets()
        #endif
        Session.applyStoredCookies()
        AudioPolicy.observe()
        ModelStore.shared.configure()
        ActivityCenter.shared.start()
        GridThumbnails.keepLibraryWarm { NSScreen.main?.backingScaleFactor ?? 2 }   // grid thumbnails made ahead of time
        #if DEBUG
        SelfTest.runIfRequested()
        #endif
        buildMenu()

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 820),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.title = "浏览"
        // the toolbar shows what is open (title and subtitle), as in Photos
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .automatic
        window.contentViewController = root
        // a split view controller sizes the window to its smallest; start at a useful size
        window.setContentSize(NSSize(width: 1180, height: 820))
        window.contentMinSize = NSSize(width: 720, height: 480)
        feed.viewerHost = { [weak self] in self?.root.view ?? NSView() }
        feed.responderAfterViewer = { [weak self] in self?.root.content.page?.grid }
        feed.onSearchTag = { [weak self] t in self?.tokenSearch.addTerm(t) }
        feed.onRenameTerm = { [weak self] o, n in self?.tokenSearch.renameTerm(o, to: n) }
        // a search shows its results in the timeline
        tokenSearch.onChange = { [weak self] q in
            guard let self else { return }
            self.feed.applyQuery(q)
            if q != TokenQuery(), self.root.content.place != .timeline { self.root.go(.timeline) }
        }
        tokenSearch.onDownload = { [weak self] button in self?.showQuickDownload(from: button) }
        tokenSearch.onExport = { [weak self] button in self?.showSearchExport(from: button) }
        feed.onChipsChanged = { [weak self] in self?.tokenSearch.chipFilterActive = self?.feed.hasChipFilter == true }
        // a tag chosen on the tags page: its media are shown in 浏览
        NotificationCenter.default.addObserver(forName: MacFeedViewController.showLabelNote, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.root.go(.timeline) }
        }
        root.content.onChange = { [weak self] in self?.refreshChrome() }
        // settings live in the sidebar (设置); ⌘, and the toolbar button go there and back
        root.content.settingsPanel = main.panel
        main.onEmbed = { [weak self] open in
            guard let self else { return }
            self.main.embeddedOpen = open
            if open { self.root.go(.settings) } else if self.root.content.place == .settings { self.root.go(.timeline) }
        }
        window.setFrameAutosaveName("MainWindow")
        window.toolbarStyle = .unified
        refreshChrome()
        NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.fitSearchWidth() }
        }
        NotificationCenter.default.addObserver(forName: ActivityCenter.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if let self, self.root.content.place == .timeline || self.root.content.place == .trash { self.refreshChrome() } }
        }
        if !window.setFrameUsingName("MainWindow") { window.center() }
        // a saved frame from before the sidebar (or a broken one) may be narrower than the minimum
        if window.frame.width < 720 || window.frame.height < 480 {
            window.setContentSize(NSSize(width: 1180, height: 820))
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()

        #if DEBUG
        if let out = ProcessInfo.processInfo.environment["TL_RESIZE_TEST"] { runResizeBenchmark(out) }
        if let out = ProcessInfo.processInfo.environment["TL_SCROLL_TEST"] { runScrollBenchmark(out) }
        if let out = ProcessInfo.processInfo.environment["TL_RENDER_CARD"] { renderCard(out) }
        if let out = ProcessInfo.processInfo.environment["TL_PANE_TEST"] { runPaneBenchmark(out) }
        if let out = ProcessInfo.processInfo.environment["TL_PANEL_TEST"] { runPanelTest(out) }
        if let out = ProcessInfo.processInfo.environment["TL_TRIAGE_TEST"] { runTriageTest(out) }
        if let dir = ProcessInfo.processInfo.environment["TL_UI_TOUR"] { runUITour(dir) }
        if let out = ProcessInfo.processInfo.environment["TL_GRID_BENCH"] { runGridBench(out) }
        if let base = ProcessInfo.processInfo.environment["TL_EXTERNAL_TEST"] { runExternalTest(base) }
        if let out = ProcessInfo.processInfo.environment["TL_VIEWER_SNAP"] { snapViewer(out) }
        if let out = ProcessInfo.processInfo.environment["TL_SWIPE_TEST"] { DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [self] in
            try? feed.debugSwipeTest().write(toFile: out, atomically: true, encoding: .utf8); NSApp.terminate(nil) } }
        #endif
        SyncService.shared.start()
        // Recycle bin: delete what stayed longer than the retention period.
        DispatchQueue.global(qos: .utility).async { if Core.expireTrash() > 0 { DispatchQueue.main.async { NotificationCenter.default.post(name: .libraryChanged, object: nil) } } }
        if ProcessInfo.processInfo.environment["TL_SELFTEST"] == nil { AutoTagger.shared.startIfEnabled() }
        // photos / files shared from Photos or Finder: import as soon as a share completes
        ShareInbox.observe { ShareInbox.importPending() }
        ShareInbox.importPending()
        if CrashWatch.shared.lastRunAbnormal {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.feed.showMessage("上次运行没有正常结束，已记录原因；可以在设置 › 问题与诊断里导出发给开发者")
            }
        }
        NotificationCenter.default.addObserver(forName: ShareInbox.failed, object: nil, queue: .main) { [weak self] n in
            MainActor.assumeIsolated { if let t = n.object as? String { self?.feed.showMessage(t) } }
        }
        NotificationCenter.default.addObserver(forName: ShareInbox.imported, object: nil, queue: .main) { [weak self] n in
            MainActor.assumeIsolated {
                guard let reports = n.object as? [ImportReport] else { return }
                self?.feed.showMessage(ShareInbox.summary(reports))
            }
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) { ShareInbox.importPending() }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// .tlpack opened from Finder or AirDrop.
    func application(_ application: NSApplication, open urls: [URL]) {
        // twitterlibrary://share — the share extension launched the app
        if urls.contains(where: { $0.scheme?.hasPrefix("twitterlibrary") == true }) { ShareInbox.importPending() }
        for url in urls where url.pathExtension.lowercased() == "tlpack" {
            macRun(window, { try Core.importPack(url) }) { r in
                NotificationCenter.default.post(name: .libraryChanged, object: nil)
                macAlert(self.window, "已导入 \(r.posts) 个帖子，\(r.media) 个媒体")
            }
        }
    }

    #if DEBUG
    /// Renders one card with a very long synthetic text off-screen to a PNG (layout check).
    private func renderCard(_ out: String) {
        let longText = String(repeating: "这是一段非常长的测试正文，用来检查卡片在帖子内容过长时标签是否还能正常显示。", count: 12)
        let item = FeedItem(mediaId: "test", postId: "p", ordinal: 0, kind: .photo, path: "/nonexistent.jpg", text: longText,
                            authorName: "测试作者", screenName: "tester", url: "https://x.com/tester/status/9990001",
                            tags: [TagView(label: "白墙", origin: 2, models: ["m"]), TagView(label: "收藏", origin: 1), TagView(label: "认可", origin: 3)])
        let card = FeedCard()
        card.loadView()
        let w: CGFloat = 320
        card.view.frame = NSRect(x: 0, y: 0, width: w, height: FeedCard.height(width: w))
        card.configure([item])
        card.view.layoutSubtreeIfNeeded()
        guard let rep = card.view.bitmapImageRepForCachingDisplay(in: card.view.bounds) else { return }
        card.view.cacheDisplay(in: card.view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
    }

    /// Scrolls the feed in 240 steps of 60 pt (≈ fast trackpad scrolling), forcing layout +
    /// display each step, then shuffles; records per-step times.
    /// Scrolls like a fast fling (TL_SCROLL_STEP points per frame, default 60) and records the
    /// time per frame, visible cards still without a picture (what looks like flicker) and how
    /// often the inline video was swapped.
    private func runScrollBenchmark(_ out: String) {
        let step = CGFloat(Double(ProcessInfo.processInfo.environment["TL_SCROLL_STEP"] ?? "") ?? 60)
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [self] in
            guard let scroll = feed.view.subviews.compactMap({ $0 as? NSScrollView }).first else { return }
            var times: [Double] = []
            var gaps: [Double] = []
            var blank = 0, i = 0
            var last = CACurrentMediaTime()
            var scrollT = 0.0, layoutT = 0.0, displayT = 0.0
            // main-thread time outside the scroll step (CA commits, image completions…): from
            // the end of a wait to the start of the next wait, minus the step itself
            var busyBetween = 0.0, wake = CACurrentMediaTime(), stepTime = 0.0
            let obs = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue | CFRunLoopActivity.afterWaiting.rawValue, true, 0) { _, act in
                let now = CACurrentMediaTime()
                if act == .afterWaiting { wake = now } else { busyBetween += max(0, now - wake - stepTime); stepTime = 0 }
            }
            CFRunLoopAddObserver(CFRunLoopGetMain(), obs, .commonModes)
            let swaps0 = feed.debugInlineSwaps
            // one step per timer tick (≈120 Hz), so image completions on the main queue run in between, as in real scrolling
            Timer.scheduledTimer(withTimeInterval: 1.0 / 120, repeats: true) { [self] timer in
                MainActor.assumeIsolated {
                    let t = CACurrentMediaTime()
                    gaps.append((t - last) * 1000); last = t
                    scroll.contentView.scroll(to: NSPoint(x: 0, y: CGFloat(i) * step))
                    scroll.reflectScrolledClipView(scroll.contentView)
                    let t1 = CACurrentMediaTime()
                    window.contentView?.layoutSubtreeIfNeeded()
                    let t2 = CACurrentMediaTime()
                    window.displayIfNeeded()
                    scrollT += t1 - t; layoutT += t2 - t1; displayT += CACurrentMediaTime() - t2
                    stepTime += CACurrentMediaTime() - t
                    times.append((CACurrentMediaTime() - t) * 1000)
                    if i > 0 { blank += feed.debugBlankCards() }
                    i += 1
                    guard i == 240 else { return }
                    timer.invalidate()
                    let s = times.sorted(), g = gaps.dropFirst().sorted()
                    let lat = MacMediaLoader.shared.debugLatency.sorted()
                    let report = String(format: "step=%.0f frames=%d work avg=%.2fms p95=%.2fms max=%.2fms | frame gap p95=%.1fms max=%.1fms gaps>17ms=%d | blankCardsPerFrame=%.2f inlineSwaps=%d decodes=%d done=%d latency p50=%.0fms p95=%.0fms",
                                        step, times.count, times.reduce(0, +) / Double(times.count), s[228], s.last!,
                                        g[g.count * 95 / 100], g.last ?? 0, g.filter { $0 > 17 }.count,
                                        Double(blank) / 239, feed.debugInlineSwaps - swaps0, MacMediaLoader.shared.debugRequests, lat.count,
                                        lat.isEmpty ? 0 : lat[lat.count / 2] * 1000, lat.isEmpty ? 0 : lat[lat.count * 95 / 100] * 1000)
                    let split = String(format: " | per frame: scroll %.2fms layout %.2fms display %.2fms images %.2fms; cards filled %d, %.2fms each; between frames %.2fms",
                                       scrollT * 1000 / 240, layoutT * 1000 / 240, displayT * 1000 / 240, MacMediaLoader.shared.debugFinishTime * 1000 / 240, feed.debugConfigures,
                                       feed.debugConfigureTime * 1000 / Double(max(feed.debugConfigures, 1)), busyBetween * 1000 / 240)
                    try? (report + split).write(toFile: out, atomically: true, encoding: .utf8)
                    NSApp.terminate(nil)
                }
            }
        }
    }

    /// Steps the window through 120 sizes, forcing a full layout + display each time, and records timings.
    /// Opens the management window and switches through every tab twice, timing each switch
    /// (layout + display), with TL_TAG_SEED tags seeded first.
    /// What is really on screen for this window (toolbar and title bar included).
    static func windowSnapshot(_ w: NSWindow, to url: URL) {
        // the frame view (content's superview) also draws the title bar and the toolbar
        guard let v = w.contentView?.superview ?? w.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
        v.cacheDisplay(in: v.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    /// Opens the first post with several media in the viewer and turns `steps` pages.
    private func debugOpenMixed(steps: Int) {
        root.go(.timeline)
        let items = (try? Core.feed(FeedRequest())) ?? []
        guard let post = Dictionary(grouping: items, by: \.postId).first(where: { $0.value.count > 2 })?.value.sorted(by: { $0.ordinal < $1.ordinal }) else { return }
        feed.openMedia(post[0], in: post)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            guard let v = Self.firstView(MacPhotoView.self, in: self.window.contentView!) else { return }
            for _ in 0..<steps { v.goNext() }
        }
    }

    /// Walks the main screens and saves a picture of each (synthetic library only).
    static func allViews(in v: NSView) -> [NSView] { [v] + v.subviews.flatMap { allViews(in: $0) } }
    static func firstView<T: NSView>(_ t: T.Type, in v: NSView) -> T? {
        if let m = v as? T { return m }
        for s in v.subviews { if let m = firstView(t, in: s) { return m } }
        return nil
    }

    /// External models end to end against a mock server (TL_EXTERNAL_TEST = its base URL):
    /// cloud (Grok-style, key + model), local (URL only), a wrong key, prompt sets, and a real
    /// auto-tagging run with the external model as the default. Writes external.txt to TL_UI_TOUR.
    private func runExternalTest(_ base: String) {
        let out = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TL_UI_TOUR"] ?? NSTemporaryDirectory()).appendingPathComponent("external.txt")
        if let seed = ProcessInfo.processInfo.environment["TL_TOUR_SEED"] { _ = try? Core.importLooseDir(URL(fileURLWithPath: seed), folder: nil, consume: false) }
        Task { @MainActor in
            var log: [String] = []
            var grok = ExternalModel.new(); grok.name = "Grok"; grok.url = base + "/v1"; grok.model = "grok-2-vision-1212"
            ExternalModels.save(grok); grok.apiKey = "xai-TESTKEY123"
            var local = ExternalModel.new(); local.url = base + "/local"
            ExternalModels.save(local)
            let set = PromptSets.add(name: "测试集", from: AIEngine.Prompt(prompt: "PROMPT-SET-B：给出标签"))
            PromptSets.assign(set.id, to: grok.id)
            log.append("models: \(ModelStore.shared.taggerIds.filter(ExternalModels.isExternal).map { ModelStore.shared.displayName($0) })")
            log.append("prompt for grok: \(PromptSets.name(forModel: grok.id)); for local: \(PromptSets.name(forModel: local.id))")
            do { log.append("grok test: \(try await ExternalAI.test(grok))") } catch { log.append("grok test FAILED: \(error.localizedDescription)") }
            do { log.append("local test: \(try await ExternalAI.test(local))") } catch { log.append("local test FAILED: \(error.localizedDescription)") }
            var bad = grok; bad.id = "ext:bad"; ExternalModels.save(bad); bad.apiKey = "wrong"
            do { _ = try await ExternalAI.test(bad); log.append("wrong key: unexpectedly OK") } catch { log.append("wrong key error: \(error.localizedDescription)") }
            ExternalModels.remove(bad.id)
            // a real run: grok is the default, auto-tag the (synthetic) library
            ModelStore.shared.activeTaggerId = grok.id
            ModelStore.shared.autoTag = true
            AutoTagger.shared.startIfEnabled()
            for _ in 0..<60 { try? await Task.sleep(nanoseconds: 250_000_000); if AutoTagger.shared.counts.done == AutoTagger.shared.counts.total, !AutoTagger.shared.running { break } }
            let items = (try? Core.feed(FeedRequest())) ?? []
            log.append("auto-tag: analysed \(AutoTagger.shared.counts.done)/\(AutoTagger.shared.counts.total), error: \(AutoTagger.shared.lastError ?? "none")")
            log.append("tags of first media: \(items.first.map { Core.mediaTags($0.mediaId) } ?? [])")
            // retag one media with the local model (as the long-press menu does)
            if let it = items.first {
                AutoTagger.shared.retag([Core.MediaRef(mediaId: it.mediaId, path: it.path, kind: it.kind.rawValue, text: it.text)], model: local.id, replaceOld: false)
                for _ in 0..<40 { try? await Task.sleep(nanoseconds: 250_000_000); if !AutoTagger.shared.running { break } }
                log.append("after local retag: \(Core.mediaTags(it.mediaId))")
            }
            try? log.joined(separator: "\n").write(to: out, atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
        }
    }

    static func allLabels(in v: NSView) -> [NSTextField] {
        (v as? NSTextField).map { [$0] } ?? [] + v.subviews.flatMap { allLabels(in: $0) }
    }

    /// The folder grid under load (TL_GRID_BENCH = report file): TL_TOUR_SEED is imported into a
    /// folder (first launch), the grid opens, and the benchmark scrolls and zooms fast; again
    /// after TL_GRID_BENCH_WAIT seconds (the disk cache warmed up), then the app quits.
    private func runGridBench(_ out: String) {
        let url = URL(fileURLWithPath: out)
        let env = ProcessInfo.processInfo.environment
        if let seed = env["TL_TOUR_SEED"], Core.folders().first(where: { $0.name == "压力测试" }) == nil {
            _ = try? Core.importLooseDir(URL(fileURLWithPath: seed), folder: "压力测试", consume: false)
            NotificationCenter.default.post(name: .libraryChanged, object: nil)
        }
        UserDefaults.standard.set(1, forKey: "mac.grid.level")    // every run starts at the middle level
        let wait = Double(env["TL_GRID_BENCH_WAIT"] ?? "") ?? 0
        let label = env["TL_GRID_BENCH_LABEL"] ?? "run"
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [self] in
            root.go(.allFolders)
            root.go(.folder("压力测试"))
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [self] in
                guard let g = root.content.page?.grid else { try? "no grid".write(to: url, atomically: true, encoding: .utf8); NSApp.terminate(nil); return }
                g.debugBench(out: url, label: "\(label) (\(g.tiles.count) tiles, \(g.columns) columns, \(Int(g.bounds.width))×\(Int(g.bounds.height)) pt)") {
                    guard wait > 0 else { NSApp.terminate(nil); return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
                        g.debugBench(out: url, label: "\(label) after \(Int(wait)) s (disk cache warmed)") { NSApp.terminate(nil) }
                    }
                }
            }
        }
    }

    /// The window a tour step wants pictured (a settings page, a popover), when not the main one.
    private var tourSnap: NSWindow?

    private func runUITour(_ dir: String) {
        let d = URL(fileURLWithPath: dir)
        var log: [String] = []
        // TL_TOUR_SEED: a folder of synthetic photos, imported as loose media into a folder first
        if let seed = ProcessInfo.processInfo.environment["TL_TOUR_SEED"] {
            _ = try? Core.importLooseDir(URL(fileURLWithPath: seed), folder: "测试文件夹", consume: false)
            NotificationCenter.default.post(name: .libraryChanged, object: nil)
        }
        // TL_TOUR_POSTS: a folder of legacy post folders (pictures + 推文内容.txt), imported as posts
        if let posts = ProcessInfo.processInfo.environment["TL_TOUR_POSTS"] {
            _ = try? Core.importLegacyDirectory(URL(fileURLWithPath: posts))
            NotificationCenter.default.post(name: .libraryChanged, object: nil)
        }
        var steps: [(String, () -> Void)] = [
            ("M1-settings", { self.main.setPanel(open: true, animated: false); self.tourSnap = self.main.window }),
            ("M2-models", {
                var e = ExternalModel.new(); e.name = "Grok"; e.url = "https://api.x.ai/v1"; e.model = "grok-2-vision"; ExternalModels.save(e)
                var l = ExternalModel.new(); l.url = "http://127.0.0.1:11434"; ExternalModels.save(l)
                PromptSets.assign(PromptSets.add(name: "简洁版", from: AIEngine.Prompt.load()).id, to: e.id)
                self.main.panel.push(MacSettingsPages.models(), title: "AI 模型"); self.tourSnap = self.main.window }),
            ("M2b-models-external", {
                if let sc = Self.firstView(NSScrollView.self, in: self.main.panel.view), let doc = sc.documentView {
                    let target = Self.allLabels(in: doc).first { $0.stringValue == "外部模型" }
                    if let t = target { doc.scroll(NSPoint(x: 0, y: max(0, t.convert(t.bounds, to: doc).minY - 20))) }
                }
                self.tourSnap = self.main.window }),
            ("M3-trash-from-folders", { self.main.panel.pop(); self.root.go(.allFolders); self.root.go(.trash); self.tourSnap = self.main.window }),
            ("M4-feed-highlight", {
                self.main.setPanel(open: false, animated: false); self.root.go(.timeline); self.feed.showFromFolders(FeedFilter(), title: "")
                if let items = try? Core.feed(FeedRequest()) { for (i, it) in items.enumerated() { try? Core.addTag(i % 2 == 0 ? "灰猫" : "白墙", to: it.mediaId, ai: i % 3 == 0) } }
                self.tokenSearch.debugType("猫 ") }),
            ("M5-search-list", { self.tokenSearch.debugType("灰"); self.tourSnap = self.tokenSearch.debugPopoverWindow }),
            ("M6-tag-picker", { self.window.makeFirstResponder(nil); self.tourSnap = self.feed.debugShowTagPicker() }),
            // from a folder's grid to the 文件夹 page: no glass may linger on it (pictures taken right after the switch)
            ("0a0-glass-switch", {
                self.root.go(.folder("测试文件夹"))
                // (the switch happens 6 s in, so a screen recording can watch it)
                DispatchQueue.main.asyncAfter(deadline: .now() + 6) { self.root.go(.allFolders) }
            }),
            ("0a-folders-overview", { self.root.go(.allFolders) }),
            ("0b-folder-grid", {
                self.root.go(.folder("测试文件夹"))
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    guard let g = self.root.content.page?.grid else { return log.append("grid: none") }
                    log.append("grid: tiles=\(g.tiles.count) columns=\(g.columns) tile0=\(g.debugTileFrame(0).map { "\($0)" } ?? "-") tile\(g.columns)=\(g.debugTileFrame(g.columns).map { "\($0)" } ?? "-")")
                }
            }),
            ("0b2-grid-mid-pinch", {
                guard let g = self.root.content.page?.grid else { return }
                g.debugPinch(at: CGPoint(x: 200, y: 150), scales: (1...30).map { 1 - 0.012 * CGFloat($0) })
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { log.append("mid pinch: \(g.debugInfo)") }
            }),
            ("0b3-grid-settled", {
                guard let g = self.root.content.page?.grid else { return }
                g.debugRelease()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { log.append("settled: \(g.debugInfo)") }
            }),
            ("0b3a-grid-zoom-in", {
                guard let g = self.root.content.page?.grid else { return }
                g.debugPinch(at: CGPoint(x: 300, y: 200), scales: (1...40).map { 1 + 0.02 * CGFloat($0) })
            }),
            ("0b3b-grid-zoom-in-settled", { self.root.content.page?.grid.debugRelease() }),
            ("0b3d-grid-scrolled", { self.root.content.page?.grid.debugScrollBy(420) }),
            // a folder scrolled so tiles pass under the toolbar (the blur band across the top)
            ("0h-grid-under-toolbar", {
                self.root.go(.folder("测试文件夹"))
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.root.content.page?.grid.debugScrollBy(520) }
            }),
            ("0b3c-grid-delete", {
                guard let p = self.root.content.page, let id = p.grid.tiles.dropFirst(2).first?.item.mediaId else { return }
                _ = try? Core.trash(media: [id])
                NotificationCenter.default.post(name: .libraryChanged, object: nil)
            }),
            ("0b4-grid-select", { self.root.content.page?.setSelecting(true); self.root.content.page?.grid.selectAll(true) }),
            ("0b5-folders-back", { self.root.content.page?.setSelecting(false); self.root.go(.allFolders) }),
            ("0c0-search-click", {
                self.root.go(.timeline)
                let f = self.tokenSearch.field
                let p = f.convert(NSPoint(x: 40, y: f.bounds.midY), to: nil)
                func ev(_ t: NSEvent.EventType) -> NSEvent? { NSEvent.mouseEvent(with: t, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: self.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) }
                // the release is queued first, so the field's click tracking ends as with a real click
                if let up = ev(.leftMouseUp) { NSApp.postEvent(up, atStart: false) }
                if let down = ev(.leftMouseDown) { self.window.sendEvent(down) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.tourSnap = self.tokenSearch.debugPopoverWindow; log.append("popover after click: \(self.tokenSearch.debugPopoverWindow?.isVisible == true) \(self.tokenSearch.debugSuggestions)") }
            }),
            ("0c1-search-click-away", {
                // a real click in the content, through the event queue: the list must close
                func click(_ p: NSPoint) {
                    for t in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                        if let e = NSEvent.mouseEvent(with: t, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: self.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) { NSApp.postEvent(e, atStart: false) }
                    }
                }
                let before = self.tokenSearch.debugPopoverWindow?.isVisible == true
                click(NSPoint(x: self.window.frame.width / 2, y: 200))
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    let afterAway = self.tokenSearch.debugPopoverWindow?.isVisible == true
                    // open it again with a click in the field, then a second click in the field closes it
                    let f = self.tokenSearch.field
                    let mid = f.convert(NSPoint(x: f.bounds.midX, y: f.bounds.midY), to: nil)
                    click(mid)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        let afterFirst = self.tokenSearch.debugPopoverWindow?.isVisible == true
                        click(mid)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                            log.append("search list: open before=\(before) after click away=\(afterAway) after click in field=\(afterFirst) after second click=\(self.tokenSearch.debugPopoverWindow?.isVisible == true)")
                        }
                    }
                }
            }),
            ("0d1-settings", { self.openManage() }),
            ("0d2-settings-page", { self.main.panel.push(MacSettingsPages.transfer(), title: "导入与备份") }),
            ("0e-trash", { self.window.makeFirstResponder(nil); self.root.go(.trash) }),
            ("0f-narrow", {
                self.root.go(.folder("测试文件夹"))
                var f = self.window.frame; f.size.width = 760; self.window.setFrame(f, display: true)
            }),
            ("0g-wide", { var f = self.window.frame; f.size.width = 1500; self.window.setFrame(f, display: true); self.root.go(.allFolders) }),
            ("0c-search-list", { self.root.go(.timeline); self.window.makeFirstResponder(self.tokenSearch.field); self.tokenSearch.debugType("文件")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { log.append("after typing: \(self.tokenSearch.debugSuggestions)") } }),
            ("0d-search-term", { self.tokenSearch.debugType("文件夹 "); }),
            ("0d0-search-capsules", { self.tokenSearch.debugType("用户 猫 灰"); }),
            ("1-feed", { log.append("settings window visible at launch: \(self.main.window?.isVisible == true)") }),
            ("1b-scrolled-down", { self.feed.debugScroll(toFraction: 1) }),
            ("1c-scrolled-back", { self.feed.debugScroll(toFraction: 0) }),
            ("2-viewer", { log.append("cards without image after scrolling back: \(self.feed.debugBlankCards())"); if let v = self.feed.debugOpenGroupPhoto() { log.append("viewer opened, counter=\(v.index + 1)") } else { log.append("no group photo") } }),
            ("3-viewer-next", { (self.feed.view.subviews.last as? MacPhotoView)?.goNext(); log.append("after →: \((self.feed.view.subviews.last as? MacPhotoView)?.index ?? -1)") }),
            ("4-feed-again", { self.feed.debugCloseViewer() }),
            ("5a-tags-seeded", {
                // synthetic tags (yours, AI's and both) on the synthetic media, then the page in the main window
                let items = (try? Core.feed(FeedRequest())) ?? []
                let names = ["风景", "城市夜景", "猫", "白墙", "室内", "插画", "截图", "人物", "食物", "蓝天", "一个名字特别长的测试标签用来看换行", "x"]
                for (i, it) in items.enumerated() {
                    for (k, n) in names.enumerated() where (i + k) % 3 != 2 {
                        try? Core.addTag(n, to: it.mediaId, ai: k % 2 == 0)
                        if k % 4 == 0 { try? Core.addTag(n, to: it.mediaId, ai: k % 2 != 0) }
                    }
                }
                NotificationCenter.default.post(name: .libraryChanged, object: nil)
                self.root.go(.settings)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self.main.panel.push(MacTagsPage(), title: "标签") }
            }),
            ("E1-search-export", {
                let items = (try? Core.feed(FeedRequest())) ?? []
                let names = ["风景", "猫", "白墙"]
                for (i, it) in items.enumerated() { for (k, n) in names.enumerated() where (i + k) % 2 == 0 { try? Core.addTag(n, to: it.mediaId, ai: k == 1) } }
                try? Core.addToFolder("旅行", media: Array(items.prefix(3).map(\.mediaId)))
                NotificationCenter.default.post(name: .libraryChanged, object: nil)
                self.root.go(.timeline)
                self.window.makeFirstResponder(self.tokenSearch.field)
                self.tokenSearch.debugType("标签 猫 ")
                log.append("export button hidden before? \(self.tokenSearch.debugExportButton.isHidden)")
            }),
            ("E2-search-export-popover", {
                log.append("export button hidden: \(self.tokenSearch.debugExportButton.isHidden); current: \(self.feed.resultsAreCurrent); results: \(self.feed.resultMediaIds.count)")
                self.showSearchExport(from: self.tokenSearch.debugExportButton)
            }),
            ("E3-search-export-run", {
                self.exportPopover?.close()
                let ids = self.feed.resultMediaIds
                let out = d.appendingPathComponent("search.tlpack")
                let outZip = d.appendingPathComponent("search.zip")
                do {
                    let a = try Core.exportMedia(ids, options: ExportOptions(), to: out)
                    let b = try Core.exportMedia(ids, options: ExportOptions(tags: false, folders: false, mediaOnly: true), to: outZip)
                    log.append("exported \(a.media) media / \(a.posts) posts as tlpack, \(b.media) as zip for \(ids.count) results")
                } catch { log.append("export failed: \(error)") }
            }),
            ("E4-tag-card-click", {
                self.tokenSearch.field.objectValue = []
                self.root.go(.settings)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    NotificationCenter.default.post(name: MacFeedViewController.showLabelNote, object: "猫")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        log.append("after tag card click: place=\(self.root.content.place) chipFilter=\(self.feed.hasChipFilter) exportShown=\(!self.tokenSearch.debugExportButton.isHidden) results=\(self.feed.resultMediaIds.count)")
                    }
                }
            }),
            ("K1-kind-video", {
                self.tokenSearch.field.objectValue = []; self.root.go(.timeline)
                self.window.makeFirstResponder(self.tokenSearch.field)
                self.tokenSearch.debugType("视频 ")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    let items = (try? Core.feed(FeedRequest())) ?? []
                    log.append("视频: results=\(self.feed.resultMediaIds.count) of \(items.count); expected videos=\(items.filter { $0.kind == .video }.count); exportShown=\(!self.tokenSearch.debugExportButton.isHidden)")
                }
            }),
            ("K2-kind-photo", {
                self.tokenSearch.field.objectValue = []
                self.tokenSearch.debugType("图片 ")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    let items = (try? Core.feed(FeedRequest())) ?? []
                    log.append("图片(照片): results=\(self.feed.resultMediaIds.count); expected photos=\(items.filter { $0.kind == .photo }.count)")
                }
            }),
            ("K3-kind-both", {
                self.tokenSearch.field.objectValue = []
                self.tokenSearch.debugType("视频 照片 ")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { log.append("视频+照片: results=\(self.feed.resultMediaIds.count)") }
            }),
            ("5-tags", { self.main.setPanel(open: true, animated: false); self.main.panel.push(MacTagsPage(), title: "标签") }),
            ("6-problems", { self.main.panel.pop(); self.main.panel.push(MacSettingsPages.problems(), title: "问题记录") }),
            ("6b-settings-root", { self.main.panel.pop() }),
            ("V1-photo-viewer", {
                self.root.go(.timeline)
                let items = (try? Core.feed(FeedRequest())) ?? []
                let photos = items.filter { $0.kind == .photo }
                if let it = photos.dropFirst().first { self.feed.openMedia(it, in: photos) }
                log.append("viewer: \(photos.count) photos")
            }),
            ("V2-player", {
                self.feed.debugCloseViewer()
                let items = (try? Core.feed(FeedRequest())) ?? []
                if let v = items.first(where: { $0.kind == .video }) { self.feed.openMedia(v, in: items) } else { log.append("no video") }
            }),
            ("V3-sidebar-triage", { self.feed.debugCloseViewer(); self.root.go(.triage) }),
            ("T-triage-decisions", {
                // 整理: three keeps a second apart (TL_TOUR_SLOW long enough to film it from outside)
                self.root.go(.triage)
                for i in 1...3 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0 * Double(i)) {
                        guard let t = self.root.content.triage else { return }
                        t.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: self.window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 126)!)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                            let frames = ["triageKeep", "triageDelete"].compactMap { id in Self.allViews(in: t).first { $0.accessibilityIdentifier() == id }.map { "\(id)=\($0.convert($0.bounds, to: nil))" } }
                            log.append("after keep \(i): " + frames.joined(separator: " "))
                        }
                    }
                }
            }),
            ("T2-triage-filter", { self.root.go(.triage); DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.root.content.triage?.debugOpenFilter() } }),
            ("V4-folder-back", {
                self.root.go(.allFolders); self.root.go(.folder("测试文件夹"))
                log.append("folder toolbar: \(self.window.toolbar?.items.map(\.itemIdentifier.rawValue) ?? [])")
            }),
            ("V5-back-pressed", {
                if let back = self.window.toolbar?.items.first(where: { $0.itemIdentifier.rawValue == "back" }), let a = back.action { NSApp.sendAction(a, to: back.target, from: back) }
                log.append("after back: \(self.root.content.place)")
            }),
            ("V6-trash", { self.root.go(.trash) }),
            // a post of photo, video, photo (TL_TOUR_POSTS): the video is a page of the viewer
            ("0i1-viewer-photo", { self.debugOpenMixed(steps: 0) }),
            ("0i2-viewer-video", { self.debugOpenMixed(steps: 1) }),
            ("0i3-viewer-photo-after", { self.debugOpenMixed(steps: 2) }),
            // switching between grid pages and others again and again: the main thread must keep up
            ("Y-switch-stress", {
                let seq: [MacPlace] = [.photos, .timeline, .folder("测试文件夹"), .trash, .allFolders, .photos, .triage]
                var worst = 0.0, last = Date()
                let lag = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { _ in let n = Date(); worst = max(worst, n.timeIntervalSince(last)); last = n }
                for i in 0..<42 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25 * Double(i)) {
                        self.root.go(seq[i % seq.count])
                        if case .photos = seq[i % seq.count] { self.root.content.page?.grid.debugScrollBy(300) }
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 11) { lag.invalidate(); log.append("switch stress: 42 switches, longest main-thread stall \(Int(worst * 1000)) ms") }
            }),
            ("X-switch-frames", {
                // timeline → 图片 → 设置 → 回收站: pictures of the window right after each switch
                let seq: [MacPlace] = [.photos, .settings, .trash, .timeline, .allFolders, .triage, .timeline]
                var f = self.window.frame; f.size.width = 1300; self.window.setFrame(f, display: true)
                self.root.split.splitViewItems[0].isCollapsed = false
                log.append("window=\(Int(self.window.frame.width)) collapsed=\(self.root.split.splitViewItems[0].isCollapsed)")
                func shoot(_ i: Int) {
                    guard i < seq.count else { return }
                    self.root.go(seq[i])
                    for (n, t) in [0.0, 0.03, 0.08, 0.2, 0.5].enumerated() {
                        DispatchQueue.main.asyncAfter(deadline: .now() + t) {
                            Self.windowSnapshot(self.window, to: d.appendingPathComponent("X\(i)-\(seq[i].title)-\(n).png"))
                            let tb = self.window.toolbar?.items.first { $0.itemIdentifier == .sidebarTrackingSeparator }
                            log.append("\(seq[i].title) t=\(t) toolbar=\(self.window.toolbar.map { String(UInt(bitPattern: ObjectIdentifier($0).hashValue), radix: 16) } ?? "-") visible=\(self.window.toolbar?.items.filter { !$0.isHidden }.map(\.itemIdentifier.rawValue).filter { !$0.hasPrefix("NS") }.joined(separator: ",") ?? "") split=\(Int(self.root.split.splitViewItems[0].viewController.view.frame.width)) tbItems=\(self.window.toolbar?.items.count ?? 0) sep=\(tb != nil) collapsed=\(self.root.split.splitViewItems[0].isCollapsed) divider=\(Int(self.root.split.splitView.subviews[0].frame.width))")
                        }
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { shoot(i + 1) }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { shoot(0) }
            }),
            ("7-triage", { self.main.setPanel(open: false, animated: false); log.append("window before triage: \(Int(self.window.frame.height))"); self.root.go(.triage) }),
            ("8-done", { log.append("window in triage: \(Int(self.window.frame.height))"); self.root.go(.timeline) }),
            ("9-tag-row", { self.feed.debugScroll(toFraction: 0); log.append("tag row: " + self.feed.debugTagScrollTest(step: 1)) }),
            ("9a-tag-row-scrolled", { log.append("tag row: " + self.feed.debugTagScrollTest(step: 2)) }),
            ("9a2-feed", { log.append("tag row: " + self.feed.debugTagScrollTest(step: 3)) }),
            ("0b9-trash", {
                // bin a post with several media and a loose one: the bin must show each post once
                let items = (try? Core.feed(FeedRequest())) ?? []
                let multi = Dictionary(grouping: items, by: \.postId).first { $0.value.count > 2 }
                if let p = multi?.key { _ = try? Core.trash(post: p) } else { for it in items.prefix(5) { _ = try? Core.trash(media: [it.mediaId]) } }
                let bin = Core.trashList()
                log.append("bin: \(bin.count) media in \(TrashGroups.group(bin).count) groups")
                self.root.go(.trash)
            }),
        ]
        if let only = ProcessInfo.processInfo.environment["TL_TOUR_ONLY"] { steps = steps.filter { $0.0.hasPrefix(only) } }
        func run(_ i: Int) {
            guard i < steps.count else { try? log.joined(separator: "\n").write(to: d.appendingPathComponent("tour.txt"), atomically: true, encoding: .utf8); NSApp.terminate(nil); return }
            steps[i].1()
            // TL_TOUR_SLOW: longer per step, and the step's name in current.txt, so the window can be
            // pictured from outside (window snapshots leave out Metal and the toolbar's glass)
            let slow = Double(ProcessInfo.processInfo.environment["TL_TOUR_SLOW"] ?? "") ?? 1.2
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { try? "\(steps[i].0)\n".write(to: d.appendingPathComponent("current.txt"), atomically: true, encoding: .utf8) }
            DispatchQueue.main.asyncAfter(deadline: .now() + slow) { MainActor.assumeIsolated {
                // settings steps picture the settings window
                var w = ["5", "6", "9b", "9c", "9d"].contains(where: { steps[i].0.hasPrefix($0) }) ? (self.main.window ?? self.window!) : self.window!
                if let t = self.tourSnap { w = t; self.tourSnap = nil }
                Self.windowSnapshot(w, to: d.appendingPathComponent("\(steps[i].0).png"))
                // the grid draws with Metal, which window snapshots leave out: picture it apart
                if steps[i].0.hasPrefix("0b"), let g = self.root.content.page?.grid {
                    g.debugSnapshot(to: d.appendingPathComponent("\(steps[i].0)-grid.png"))
                    log.append("\(steps[i].0): \(g.debugInfo)")
                }
                run(i + 1) } }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { MainActor.assumeIsolated { run(0) } }
    }

    /// Opens 整理 from the sidebar and records how long until the
    /// queue is shown and the longest main-thread stall meanwhile.
    private func runTriageTest(_ out: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [self] in
            MainActor.assumeIsolated {
                let t0 = CACurrentMediaTime()
                var last = t0, maxGap = 0.0
                let tick = Timer(timeInterval: 0.005, repeats: true) { _ in let n = CACurrentMediaTime(); maxGap = max(maxGap, n - last); last = n }
                RunLoop.main.add(tick, forMode: .common)
                root.go(.triage)
                func poll() {
                    if let n = root.content.triage?.debugLoadedCount {
                        let loaded = CACurrentMediaTime() - t0
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            tick.invalidate()
                            try? String(format: "queue=%d loaded=%.0fms longestMainThreadStall=%.0fms", n, loaded * 1000, maxGap * 1000).write(toFile: out, atomically: true, encoding: .utf8)
                            NSApp.terminate(nil)
                        }
                    } else if CACurrentMediaTime() - t0 > 30 {
                        try? "timeout".write(toFile: out, atomically: true, encoding: .utf8); NSApp.terminate(nil)
                    } else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { poll() } }
                }
                poll()
            }
        }
    }

    /// Opens and closes the settings panel on a narrow and on a wide window; records frames and
    /// saves a picture of each state.
    private func runPanelTest(_ out: String) {
        var lines: [String] = []
        let screen = window.screen?.visibleFrame ?? .zero
        func snap(_ name: String) { Self.windowSnapshot(window, to: URL(fileURLWithPath: out).deletingLastPathComponent().appendingPathComponent("window-\(name).png")) }
        func state(_ label: String) {
            window.contentView?.layoutSubtreeIfNeeded()
            lines.append("\(label): window=\(Int(window.frame.width)) panelOpen=\(main.isPanelOpen) panel=\(Int(main.panel.view.frame.width)) feed=\(Int(feed.view.frame.width))")
        }
        // every width the media area passes through while the panel animates (a jump shows up here)
        var feedWidths: [Int] = []
        feed.view.postsFrameChangedNotifications = true
        let obs = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: feed.view, queue: nil) { [weak self] _ in
            if let w = self?.feed.view.frame.width { let i = Int(w.rounded()); if feedWidths.last != i { feedWidths.append(i) } }
        }
        func widths(_ label: String) { lines.append("\(label) media-area widths during animation: \(feedWidths)"); feedWidths = [] }
        let steps: [(String, () -> Void)] = [
            ("narrow", { self.window.setFrame(NSRect(x: screen.minX + 100, y: screen.minY + 50, width: 900, height: 760), display: true); feedWidths = [] }),
            ("narrow-open", { self.main.setPanel(open: true, animated: true); widths("open") }),
            ("narrow-closed", { self.main.setPanel(open: false, animated: true); widths("close") }),
            ("wide", { self.window.setFrame(NSRect(x: screen.minX + 20, y: screen.minY + 50, width: min(1600, screen.width - 40), height: 900), display: true) }),
            ("wide-open", { self.main.setPanel(open: true, animated: false) }),
            ("wide-sub", { self.main.panel.push(MacSettingsPages.problems(), title: "问题记录") }),
            ("wide-closed", { self.main.setPanel(open: false, animated: false) }),
        ]
        func run(_ i: Int) {
            guard i < steps.count else {
                lines.append("screen=\(Int(screen.width))")
                NotificationCenter.default.removeObserver(obs)
                try? lines.joined(separator: "\n").write(toFile: out, atomically: true, encoding: .utf8)
                NSApp.terminate(nil); return
            }
            steps[i].1()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { MainActor.assumeIsolated { state(steps[i].0); snap(steps[i].0); run(i + 1) } }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { MainActor.assumeIsolated { run(0) } }
    }

    private func runPaneBenchmark(_ out: String) {
        if let n = Int(ProcessInfo.processInfo.environment["TL_TAG_SEED"] ?? ""), let items = try? Core.feed(FeedRequest()), !items.isEmpty {
            for i in 0..<n { try? Core.addTag("标签\(i)", to: items[i % items.count].mediaId, ai: i % 2 == 0) }
            for i in 0..<min(400, items.count) { _ = try? Core.trash(media: [items[i].mediaId]) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            MainActor.assumeIsolated { ActivityCenter.shared.refreshStats() }
            self.main.setPanel(open: true, animated: false)
            let pages: [(String, () -> NSViewController)] = [("下载帖子", { MacSettingsPages.download() }), ("导入与备份", { MacSettingsPages.transfer() }),
                ("标签", { MacSettingsPages.renames() }), ("问题记录", { MacSettingsPages.problems() }), ("AI 模型", { MacSettingsPages.models() }), ("同步", { MacSettingsPages.sync() })]
            var lines: [String] = []
            let snapDir = ProcessInfo.processInfo.environment["TL_PANEL_SNAPS"]
            func snap(_ name: String) {
                guard let dir = snapDir, let v = self.main.panel.view as NSView?, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
                v.cacheDisplay(in: v.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png"))
            }
            self.window.contentView?.layoutSubtreeIfNeeded(); self.window.displayIfNeeded(); snap("0-设置")
            for round in 0..<2 {
                for (i, (title, make)) in pages.enumerated() {
                    let t = CACurrentMediaTime()
                    self.main.panel.push(make(), title: title)
                    self.window.contentView?.layoutSubtreeIfNeeded()
                    self.window.displayIfNeeded()
                    lines.append(String(format: "round%d %@ %.1fms", round, title, (CACurrentMediaTime() - t) * 1000))
                    if round == 0 { snap("\(i + 1)-\(title)") }
                    self.main.panel.pop()
                }
            }
            let fits = self.main.panel.view.fittingSize
            lines.append("panel width=\(Int(self.main.panel.view.frame.width)) window=\(Int(self.window.frame.width)) fitting=\(Int(fits.width))")
            _ = try? Core.restore(Core.trashList().map(\.mediaId))
            try? lines.joined(separator: "\n").write(toFile: out, atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
        }
    }

    /// Renders the whole window (toolbar included) with the feed, then with the first photo open.
    private func snapViewer(_ out: String) {
        func render(_ path: String) {
            guard let frame = window.contentView?.superview else { return }
            frame.layoutSubtreeIfNeeded()
            guard let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else { return }
            frame.cacheDisplay(in: frame.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [self] in
            render(out + "-feed.png")
            feed.debugOpenFirstPhoto()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [self] in
                render(out + "-viewer.png")
                // Click test: what does the window hit at the close button's center?
                var report = "viewer=\(feed.isShowingViewer)"
                if let frame = window.contentView?.superview,
                   let close = frame.firstDescendant(where: { $0.accessibilityIdentifier() == "photoClose" }) {
                    let p = close.convert(NSPoint(x: close.bounds.midX, y: close.bounds.midY), to: frame)
                    let hit = frame.hitTest(p)
                    report += " closeHit=\(hit === close || hit?.isDescendant(of: close) == true) hitClass=\(hit.map { String(describing: type(of: $0)) } ?? "nil")"
                    report += " traffic=\(window.standardWindowButton(.closeButton)?.isHidden == true ? "hidden" : "visible") toolbar=\(window.toolbar?.isVisible == true)"
                    (close as? NSButton)?.performClick(nil)
                    report += " afterClick viewer=\(feed.isShowingViewer)"
                }
                try? report.write(toFile: out + "-report.txt", atomically: true, encoding: .utf8)
                NSApp.terminate(nil)
            }
        }
    }

    private func runResizeBenchmark(_ out: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [self] in
            var times: [Double] = []
            let origin = window.frame.origin
            for i in 0..<120 {
                let w = 700 + CGFloat(i % 60) * 15 * (i < 60 ? 1 : -1) + (i < 60 ? 0 : 900)
                let t = CACurrentMediaTime()
                window.setFrame(NSRect(x: origin.x, y: origin.y, width: w, height: 760 + CGFloat(i % 7) * 10), display: false)
                window.contentView?.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                times.append((CACurrentMediaTime() - t) * 1000)
            }
            let sorted = times.sorted()
            let report = String(format: "frames=%d avg=%.2fms p50=%.2fms p95=%.2fms max=%.2fms", times.count,
                                times.reduce(0, +) / Double(times.count), sorted[60], sorted[113], sorted.last!)
            try? report.write(toFile: out, atomically: true, encoding: .utf8)
        }
    }
    #endif

    // MARK: Toolbar

    /// The toolbar follows what the content shows, as in Photos: the window's title and subtitle
    /// (what it is, how much), then at most three groups — the view's own controls, search, and
    /// 资料库管理. Every item is also in the menu bar.
    private enum ToolbarMode: String { case timeline, grid, folderGrid, selecting, folders, plain, settings, settingsSub }
    private var toolbarMode: ToolbarMode?

    private enum ID {
        static let search = NSToolbarItem.Identifier("search")
        static let group = NSToolbarItem.Identifier("group")
        static let shuffle = NSToolbarItem.Identifier("shuffle")
        static let manage = NSToolbarItem.Identifier("manage")
        static let zoom = NSToolbarItem.Identifier("zoom")
        static let select = NSToolbarItem.Identifier("select")
        static let more = NSToolbarItem.Identifier("more")
        static let newFolder = NSToolbarItem.Identifier("newFolder")
        static let selectAll = NSToolbarItem.Identifier("selectAll")
        static let share = NSToolbarItem.Identifier("share")
        static let addTo = NSToolbarItem.Identifier("addTo")
        static let takeOut = NSToolbarItem.Identifier("takeOut")
        static let trash = NSToolbarItem.Identifier("trash")
        static let restore = NSToolbarItem.Identifier("restore")
        static let purge = NSToolbarItem.Identifier("purge")
        static let done = NSToolbarItem.Identifier("done")
        static let back = NSToolbarItem.Identifier("back")
        static let title = NSToolbarItem.Identifier("titlePill")
    }
    /// The title and subtitle of a grid page, on glass (the photos scroll under the toolbar).
    private let titlePill = MacGlassTitle()

    private var page: MacMediaGridPage? { root.content.page }

    // MARK: Export of a search

    private var downloadPopover: NSPopover?

    private func showQuickDownload(from button: NSView) {
        downloadPopover?.close()
        let pop = NSPopover()
        pop.behavior = .transient
        let host = NSHostingController(rootView: QuickDownloadView(openSettings: { [weak self, weak pop] in
            pop?.close()
            guard let self else { return }
            self.main.setPanel(open: true)
            self.main.panel.push(MacSettingsPages.download(), title: "下载帖子")
        }, download: { [weak self, weak pop] in
            MainActor.assumeIsolated {
                DownloadModel.shared.download(self?.window)
                if DownloadModel.shared.links.isEmpty { pop?.close() }
            }
        }))
        host.sizingOptions = .preferredContentSize
        pop.contentViewController = host
        downloadPopover = pop
        pop.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
    }

    private var exportPopover: NSPopover?

    /// The export button next to the search field: a small popover (two switches and the plain
    /// media switch, then 导出) for exactly the media the search shows now.
    private func showSearchExport(from button: NSView) {
        exportPopover?.close()
        guard feed.resultsAreCurrent else { return macAlert(window, "正在搜索", "等搜索结果出来后再导出。") }
        let ids = feed.resultMediaIds
        let pop = NSPopover()
        pop.behavior = .transient
        pop.animates = true
        let host = NSHostingController(rootView: SearchExportView(count: ids.count) { [weak self, weak pop] in
            pop?.close()
            self?.exportSearchResult(ids)
        })
        host.sizingOptions = .preferredContentSize
        pop.contentViewController = host
        exportPopover = pop
        pop.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
    }

    private func exportSearchResult(_ ids: [String]) {
        let name = SearchExportPrefs.fileName()
        let options = SearchExportPrefs.options
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.beginSheetModal(for: window) { [weak self] r in
            guard r == .OK, let url = panel.url, let self else { return }
            macRunProgress(self.window, title: "正在导出 \(ids.count) 个媒体…", progress: {
                guard let p = Core.exportStatus(), p.total > 0 else { return nil }
                return "\(p.done) / \(p.total) 个媒体 · \(ActivityCenter.bytes(p.bytes))"
            }, cancel: { Core.cancelExport() }, { try Core.exportMedia(ids, options: options, to: url) }) { [weak self] r in
                let more = r.skippedText
                macAlert(self?.window, more.isEmpty ? "导出完成" : "导出完成（有遗漏）", "\(r.posts) 个帖子，\(r.media) 个媒体，\(ActivityCenter.bytes(r.bytes))" + (more.isEmpty ? "" : "\n\n" + more))
            }
        }
    }

    /// Title, subtitle and toolbar for what the content shows now.
    func refreshChrome() {
        let c = root.content
        let (title, subtitle) = c.titles
        window.title = title
        window.subtitle = subtitle
        titlePill.set(title: title, subtitle: subtitle)
        let mode: ToolbarMode
        // a folder is a level below 文件夹: its page has a Back to all folders
        if let p = c.page { mode = p.selecting ? .selecting : c.place.folderName != nil ? .folderGrid : .grid }
        else if c.place == .settings { mode = main.panel.backTitle == nil ? .settings : .settingsSub }
        else { mode = c.place == .timeline ? .timeline : c.place == .allFolders ? .folders : .plain }      // .plain: 整理 has no toolbar items of its own
        main.embeddedOpen = c.place == .settings
        // One toolbar for the life of the window: each page only shows or hides items. Putting in
        // a new toolbar per page rebuilt the title bar and its glass, and every switch flashed.
        if window.toolbar?.identifier != "main" {
            let tb = NSToolbar(identifier: "main")
            tb.delegate = self
            tb.displayMode = .iconOnly
            tb.allowsUserCustomization = false
            window.toolbar = tb
        }
        toolbarMode = mode
        let shown = Set(visibleItems(mode))
        // a grid page shows its title on glass (as an item); the window's own title only elsewhere
        // The title item is never hidden or shown (the toolbar animates that, and its glass lingered on
        // the other pages): it stays in place and the pill inside it appears or goes at once.
        let pill = c.page != nil
        titlePill.setShown(pill)
        if window.titleVisibility != (pill ? .hidden : .visible) { window.titleVisibility = pill ? .hidden : .visible }
        for it in window.toolbar?.items ?? [] where Self.pageItems.contains(it.itemIdentifier) {
            let hide = !shown.contains(it.itemIdentifier)
            if it.isHidden != hide { it.isHidden = hide }
        }
        updateToolbarStates()
    }

    /// The search field gets about a quarter of the window, so the toolbar's own items (title,
    /// zoom, 选择, More) always fit beside it, down to the narrowest window.
    private func fitSearchWidth() {
        tokenSearch.setWidth(window.frame.width * 0.28)
    }

    private func updateToolbarStates() {
        fitSearchWidth()
        guard let items = window.toolbar?.items else { return }
        for it in items {
            switch it.itemIdentifier {
            case ID.zoom:
                (it as? NSToolbarItemGroup)?.subitems.first?.isEnabled = page?.canZoomOut ?? false
                (it as? NSToolbarItemGroup)?.subitems.last?.isEnabled = page?.canZoomIn ?? false
            case ID.selectAll: it.title = page?.allSelected == true ? "取消全选" : "全选"
            case ID.addTo:
                (it as? NSMenuToolbarItem)?.menu = page?.addToFolderMenu() ?? NSMenu()
                it.isEnabled = page?.hasSelection ?? false
            case ID.more: (it as? NSMenuToolbarItem)?.menu = page?.moreMenu() ?? NSMenu()
            case ID.takeOut, ID.trash, ID.share, ID.restore, ID.purge: it.isEnabled = page?.hasSelection ?? false
            case ID.group: (it.view as? NSButton)?.state = feed.grouped ? .on : .off
            default: break
            }
        }
    }

    /// Every page's items, in one fixed order; a page shows its own (`visibleItems`).
    private static let pageItems: [NSToolbarItem.Identifier] = [ID.back, ID.group, ID.shuffle, ID.zoom, ID.select, ID.more, ID.newFolder,
                                                               ID.selectAll, ID.share, ID.addTo, ID.takeOut, ID.trash, ID.restore, ID.purge, ID.done, ID.search]

    /// What a page shows. Search belongs to 浏览 (results show there); elsewhere the toolbar
    /// has only the view's own controls.
    private func visibleItems(_ mode: ToolbarMode) -> [NSToolbarItem.Identifier] {
        switch mode {
        case .timeline: return [ID.group, ID.shuffle, ID.search]
        case .grid: return [ID.zoom, ID.select, ID.more]
        case .folderGrid: return [ID.back, ID.zoom, ID.select, ID.more]
        case .selecting where page?.bin == true: return [ID.selectAll, ID.restore, ID.purge, ID.done]
        case .selecting: return [ID.selectAll, ID.share, ID.addTo] + (page?.folder != nil ? [ID.takeOut] : []) + [ID.trash, ID.done]
        case .folders: return [ID.newFolder]
        case .plain, .settings: return []
        case .settingsSub: return [ID.back]
        }
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, ID.back, ID.title, .flexibleSpace] + Self.pageItems.filter { $0 != ID.back && $0 != ID.title }
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarDefaultItemIdentifiers(toolbar) }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        func button(_ symbol: String, _ label: String, _ action: Selector) -> NSToolbarItem {
            let item = NSToolbarItem(itemIdentifier: id)
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            item.label = label
            item.toolTip = label
            item.target = self
            item.action = action
            return item
        }
        func text(_ title: String, _ action: Selector) -> NSToolbarItem {
            let item = NSToolbarItem(itemIdentifier: id)
            item.title = title
            item.label = title
            item.target = self
            item.action = action
            item.isBordered = true
            return item
        }
        func menu(_ symbol: String, _ label: String) -> NSMenuToolbarItem {
            let item = NSMenuToolbarItem(itemIdentifier: id)
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            item.label = label
            item.toolTip = label
            item.showsIndicator = false
            item.menu = NSMenu()
            return item
        }
        switch id {
        case ID.title:
            let item = NSToolbarItem(itemIdentifier: id)
            item.view = titlePill
            item.label = "标题"
            item.visibilityPriority = .high
            if #available(macOS 26.0, *) { item.isBordered = false }   // the pill is its own glass
            return item
        case ID.search:
            let item = NSToolbarItem(itemIdentifier: id)
            item.view = tokenSearch
            item.label = "搜索"
            item.visibilityPriority = .high
            return item
        case ID.group:
            // a toggle: on, a post is one card (also 显示 › 按帖子分组)
            let b = NSButton(image: NSImage(systemSymbolName: "rectangle.stack", accessibilityDescription: "按帖子分组")!, target: self, action: #selector(groupToggled(_:)))
            b.setButtonType(.pushOnPushOff)
            b.bezelStyle = .toolbar
            b.state = feed.grouped ? .on : .off
            b.setAccessibilityIdentifier("groupToggle")
            let item = NSToolbarItem(itemIdentifier: id)
            item.view = b
            item.label = "按帖子分组"
            item.toolTip = "按帖子分组：一个帖子显示为一张卡片"
            return item
        case ID.shuffle: return button("shuffle", "重新随机", #selector(reshuffle))
        case ID.manage: return button("square.stack.3d.down.right", "资料库管理", #selector(openManage))
        case ID.zoom:
            let g = NSToolbarItemGroup(itemIdentifier: id, images: [NSImage(systemSymbolName: "minus", accessibilityDescription: "缩小")!, NSImage(systemSymbolName: "plus", accessibilityDescription: "放大")!],
                                       selectionMode: .momentary, labels: ["缩小", "放大"], target: self, action: #selector(zoomClicked(_:)))
            g.label = "缩放"
            g.controlRepresentation = .expanded      // − and + side by side, never folded into a menu
            g.toolTip = "缩小 ⌘− / 放大 ⌘+（也可以在触控板上捏合）"
            return g
        case ID.select: return text("选择", #selector(toggleSelecting))
        case ID.back:
            // the standard Back: a chevron, no text (HIG)
            let item = button("chevron.backward", "返回", #selector(goBack))
            item.isNavigational = true
            return item
        case ID.more: return menu("ellipsis", "更多")
        case ID.newFolder: return button("folder.badge.plus", "新建文件夹", #selector(newFolder))
        case ID.selectAll: return text("全选", #selector(selectAllInGrid))
        case ID.share:
            let item = NSSharingServicePickerToolbarItem(itemIdentifier: id)
            item.delegate = self
            item.label = "分享"
            return item
        case ID.addTo: return menu("folder.badge.plus", "加入文件夹")
        case ID.takeOut: return button("folder.badge.minus", "移出文件夹", #selector(takeOutOfFolder))
        case ID.trash: return button("trash", "移到回收站", #selector(trashSelection))
        case ID.restore: return button("arrow.uturn.backward", "还原", #selector(restoreSelection))
        case ID.purge: return button("trash.slash", "永久删除", #selector(purgeSelection))
        case ID.done:
            let item = text("完成", #selector(toggleSelecting))
            if #available(macOS 26.0, *) { item.style = .prominent }
            return item
        default: return nil
        }
    }

    /// Back: a settings sub-page to its parent, a folder to all folders.
    @objc private func goBack() {
        if root.content.place.folderName != nil { root.go(.allFolders) } else { main.panel.pop() }
    }
    @objc private func groupToggled(_ b: NSButton) { feed.grouped = b.state == .on; refreshChrome() }
    @objc private func toggleGrouped() { feed.grouped.toggle(); refreshChrome() }
    @objc private func reshuffle() { feed.reshuffle() }
    @objc func openManage() { main.togglePanel() }
    @objc private func zoomClicked(_ g: NSToolbarItemGroup) { g.selectedIndex == 0 ? page?.zoomOut() : page?.zoomIn() }
    @objc private func zoomInMenu() { page?.zoomIn() }
    @objc private func zoomOutMenu() { page?.zoomOut() }
    @objc private func toggleSelecting() { page.map { $0.setSelecting(!$0.selecting) } }
    @objc private func selectAllInGrid() { page?.toggleAll() }
    @objc private func takeOutOfFolder() { page?.removeSelectedFromFolder() }
    @objc private func trashSelection() { page?.trashSelected() }
    @objc private func restoreSelection() { page?.restoreSelected() }
    @objc private func purgeSelection() { page?.purgeSelected() }
    @objc private func newFolder() { MacFolderActions.create(in: window) { [weak self] n in self?.root.go(.folder(n)) } }
    @objc private func goTimeline() { root.go(.timeline) }
    @objc private func goFolders() { root.go(.allFolders) }
    @objc private func goPhotos() { root.go(.photos) }
    @objc private func goVideos() { root.go(.videos) }

    // MARK: Menu

    private func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        let app = NSMenu()
        app.addItem(withTitle: "关于 TwimShelf", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "资料库管理…", action: #selector(openManage), keyEquivalent: ",")
        app.addItem(.separator())
        app.addItem(withTitle: "隐藏 TwimShelf", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(withTitle: "退出 TwimShelf", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = app

        let fileItem = NSMenuItem(); main.addItem(fileItem)
        let file = NSMenu(title: "文件")
        file.addItem(withTitle: "新建文件夹…", action: #selector(newFolder), keyEquivalent: "N")
        file.addItem(.separator())
        file.addItem(withTitle: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileItem.submenu = file

        let editItem = NSMenuItem(); main.addItem(editItem)
        let edit = NSMenu(title: "编辑")
        edit.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        edit.addItem(withTitle: "选择", action: #selector(toggleSelecting), keyEquivalent: "")
        editItem.submenu = edit

        let viewItem = NSMenuItem(); main.addItem(viewItem)
        let view = NSMenu(title: "显示")
        view.addItem(withTitle: "显示侧边栏", action: #selector(NSSplitViewController.toggleSidebar(_:)), keyEquivalent: "s").keyEquivalentModifierMask = [.command, .control]
        view.addItem(.separator())
        view.addItem(withTitle: "放大", action: #selector(zoomInMenu), keyEquivalent: "+")
        view.addItem(withTitle: "缩小", action: #selector(zoomOutMenu), keyEquivalent: "-")
        view.addItem(.separator())
        view.addItem(withTitle: "按帖子分组", action: #selector(toggleGrouped), keyEquivalent: "")
        view.addItem(withTitle: "重新随机", action: #selector(reshuffle), keyEquivalent: "r")
        view.addItem(.separator())
        view.addItem(withTitle: "进入全屏幕", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f").keyEquivalentModifierMask = [.command, .control]
        viewItem.submenu = view

        let goItem = NSMenuItem(); main.addItem(goItem)
        let go = NSMenu(title: "前往")
        go.addItem(withTitle: "浏览", action: #selector(goTimeline), keyEquivalent: "1")
        go.addItem(withTitle: "文件夹", action: #selector(goFolders), keyEquivalent: "2")
        go.addItem(withTitle: "图片", action: #selector(goPhotos), keyEquivalent: "3")
        go.addItem(withTitle: "视频", action: #selector(goVideos), keyEquivalent: "4")
        goItem.submenu = go

        let winItem = NSMenuItem(); main.addItem(winItem)
        let win = NSMenu(title: "窗口")
        win.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        win.addItem(withTitle: "缩放", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        winItem.submenu = win
        NSApp.windowsMenu = win
        NSApp.mainMenu = main
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(zoomInMenu): return page?.canZoomIn ?? false
        case #selector(zoomOutMenu): return page?.canZoomOut ?? false
        case #selector(toggleSelecting): item.state = page?.selecting == true ? .on : .off; return page != nil
        case #selector(toggleGrouped): item.state = feed.grouped ? .on : .off; return true
        case #selector(reshuffle): return root.content.place == .timeline
        default: return true
        }
    }
}

extension AppDelegate: NSSharingServicePickerToolbarItemDelegate {
    func items(for pickerToolbarItem: NSSharingServicePickerToolbarItem) -> [Any] { page?.selectedURLs ?? [] }
}

#if DEBUG
extension NSView {
    func firstDescendant(where f: (NSView) -> Bool) -> NSView? {
        for v in subviews { if f(v) { return v }; if let d = v.firstDescendant(where: f) { return d } }
        return nil
    }
}
#endif

#if DEBUG
extension AppDelegate {
    /// Isolated settings-only audit: requires a temporary library, starts no sync,
    /// downloader, model worker or share-inbox observer, and never presses actions.
    private func runSettingsLayoutAudit(_ output: String) {
        let directory = URL(fileURLWithPath: output, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // synthetic content, so the pages show what they look like in use (TL_LIBRARY_DIR only)
        if let seed = ProcessInfo.processInfo.environment["TL_TOUR_SEED"] {
            _ = try? Core.importLooseDir(URL(fileURLWithPath: seed), folder: "旅行", consume: false)
            let items = (try? Core.feed(FeedRequest())) ?? []
            for (i, it) in items.enumerated() { for (k, n) in ["风景", "猫", "白墙", "城市夜景"].enumerated() where (i + k) % 2 == 0 { try? Core.addTag(n, to: it.mediaId, ai: k % 2 == 1) } }
            var e = ExternalModel.new(); e.name = "本地 Ollama"; e.url = "http://127.0.0.1:11434"; ExternalModels.save(e)
            var c = ExternalModel.new(); c.name = "Grok"; c.url = "https://api.x.ai/v1"; c.model = "grok-2-vision"; c.apiKey = "test"; ExternalModels.save(c)
            _ = PromptSets.add(name: "简洁版", from: AIEngine.Prompt.load())
            _ = try? Core.renameTag("猫", to: "猫咪")
            MainActor.assumeIsolated { ActivityCenter.shared.refreshStats() }
        }
        let panel = MacSettingsPanel()
        panel.embedded = true
        let testWindow = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 520, height: 600),
                                  styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        self.window = testWindow
        let embedded = ProcessInfo.processInfo.environment["TL_SETTINGS_EMBEDDED"] == "1"
        if embedded {
            let host = MacRootViewController(feed: MacFeedViewController())
            host.content.settingsPanel = panel
            testWindow.contentViewController = host
            host.split.splitView.autosaveName = nil
            host.go(.settings)
        } else {
            testWindow.contentViewController = panel
        }
        testWindow.orderFront(nil)
        panel.willShow()
        let pages: [(String, () -> NSViewController)] = [
            ("root", { MacSettingsPages.root() }), ("download", { MacSettingsPages.download() }),
            ("transfer", { MacSettingsPages.transfer() }), ("models", { MacSettingsPages.models() }),
            ("sync", { MacSettingsPages.sync() }),
            ("problems", { MacSettingsPages.problems() }), ("tags", { MacTagsPage() })]
        let sizes: [NSSize] = embedded
            ? [.init(width: 720, height: 480), .init(width: 900, height: 600),
               .init(width: 1180, height: 820), .init(width: 1400, height: 900)]
            : [.init(width: 380, height: 420), .init(width: 520, height: 480),
               .init(width: 900, height: 700), .init(width: 1400, height: 900)]
        var log: [String] = []
        var activePage: NSViewController?
        var previousCardHeights: [CGFloat] = []
        var previousContentWidth: CGFloat = 0
        var failures = 0
        func check(_ condition: Bool, _ message: String) {
            if !condition { failures += 1; log.append("FAIL " + message) }
        }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func run(_ index: Int) {
            guard index < pages.count * sizes.count else {
                log.append("failures=\(failures)")
                try? log.joined(separator: "\n").write(to: directory.appendingPathComponent("layout.txt"), atomically: true, encoding: .utf8)
                panel.didHide()
                NSApp.terminate(nil)
                return
            }
            let (name, make) = pages[index / sizes.count]
            let size = sizes[index % sizes.count]
            NSAnimationContext.beginGrouping()
            NSAnimationContext.current.duration = 0
            testWindow.setContentSize(size)
            if let host = testWindow.contentViewController as? MacRootViewController {
                // Exercise both sidebar states explicitly; programmatic resize does
                // not produce AppKit's live-resize callbacks.
                host.split.splitViewItems.first?.isCollapsed = size.width < 900
                host.view.needsLayout = true
                host.view.layoutSubtreeIfNeeded()
            }
            NSAnimationContext.endGrouping()
            if index % sizes.count == 0 {
                panel.popToRoot()
                let page = make()
                panel.push(page, title: name)
                (page as? FormPane)?.resume()
                activePage = page
                previousCardHeights = []
            }
            testWindow.appearance = NSAppearance(named: index % sizes.count < 2 ? .aqua : .darkAqua)
            guard let page = activePage else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                testWindow.contentView?.layoutSubtreeIfNeeded()
                page.view.layoutSubtreeIfNeeded()
                let key = "\(name)-\(Int(size.width))"
                if embedded, size.width >= 900 {
                    check(panel.view.bounds.width < testWindow.contentView!.bounds.width - 180, key + " sidebar is visible")
                }
                if embedded, let detail = panel.parent?.view {
                    check(abs(panel.view.bounds.width - detail.bounds.width) < 1, key + " fills main detail width")
                }
                check(abs(page.view.bounds.width - panel.view.bounds.width) < 1, key + " page width")
                check(abs(page.view.bounds.height - panel.view.bounds.height) < 1, key + " page height")
                // SwiftUI pages scroll and lay themselves out: log what they were given
                log.append("\(key) page=\(page.view.bounds.size)")
                if index % sizes.count == 0 || index % sizes.count == 2 {
                    let snapshot = embedded ? testWindow.contentView! : page.view
                    if let rep = snapshot.bitmapImageRepForCachingDisplay(in: snapshot.bounds) {
                        snapshot.cacheDisplay(in: snapshot.bounds, to: rep)
                        try? rep.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent(key + ".png"))
                    }
                    // long pages: also what lies below the first screen (the page's own scroll view)
                    if let scroll = descendants(page.view).compactMap({ $0 as? NSScrollView }).first, let doc = scroll.documentView {
                        let viewport = scroll.contentView.bounds.height
                        var y = viewport * 0.9
                        var n = 1
                        while y < doc.bounds.height - viewport * 0.2, n <= 3 {
                            scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
                            scroll.reflectScrolledClipView(scroll.contentView)
                            testWindow.contentView?.layoutSubtreeIfNeeded()
                            if let rep = snapshot.bitmapImageRepForCachingDisplay(in: snapshot.bounds) {
                                snapshot.cacheDisplay(in: snapshot.bounds, to: rep)
                                try? rep.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("\(key)-s\(n).png"))
                            }
                            y += viewport * 0.9; n += 1
                        }
                        scroll.contentView.scroll(to: .zero)
                    }
                }
                run(index + 1)
            }
        }
        run(0)
    }
}
#endif
