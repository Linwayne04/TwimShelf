import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The settings pages, in SwiftUI: cards, tiles and rings on a soft page (`MacSettingsKit`).
/// Each is pushed on the settings panel by `PaneEnv.open`; the panel's header is the main
/// window's toolbar.
enum MacSettingsPages {
    static func root() -> SettingsHost { SettingsHost { SettingsRootView() } }
    static func download() -> SettingsHost { SettingsHost { DownloadPageView() } }
    static func transfer() -> SettingsHost { SettingsHost { TransferPageView() } }
    static func models() -> SettingsHost { SettingsHost { ModelsPageView() } }
    static func sync() -> SettingsHost { SettingsHost { SyncPageView() } }
    static func problems() -> SettingsHost { SettingsHost { ProblemsPageView() } }
    static func renames() -> SettingsHost { SettingsHost { TagRenamesPageView() } }
}

// MARK: - Root

/// The front page: the library's numbers, tiles for the places, then preferences and care.
struct SettingsRootView: View {
    @EnvironmentObject private var env: PaneEnv
    @StateObject private var live = LiveTick()
    private let tiles = [GridItem(.adaptive(minimum: 230), spacing: 14, alignment: .top)]

    var body: some View {
        let _ = live.count
        let stats = ActivityCenter.shared.stats
        let counts = AutoTagger.shared.counts
        let svc = SyncService.shared
        let online = svc.reachablePeers.count
        let downloading = ActivityCenter.shared.activities.first { $0.kind == .download }
        SettingsCanvas {
            hero(stats, svc)
            ActivityCard()

            VStack(alignment: .leading, spacing: 10) {
                SectionHeading("管理")
                LazyVGrid(columns: tiles, spacing: 14) {
                    NavTile(title: "下载帖子", detail: downloading.map { "\($0.title) · \($0.detail)" } ?? "链接 · 批量 JSON · Cookie", symbol: "arrow.down", color: .blue,
                            progress: downloading?.progress, id: "nav-download") { env.open("下载帖子", MacSettingsPages.download()) }
                    NavTile(title: "导入与备份", detail: "ZIP · 导出包 · 整库备份", symbol: "shippingbox.fill", color: .brown, id: "nav-transfer") { env.open("导入与备份", MacSettingsPages.transfer()) }
                    NavTile(title: "标签", detail: "\(stats?.tags ?? 0) 个标签，点一下就在浏览里只看它", symbol: "tag.fill", color: .indigo, id: "nav-tags") { env.open("标签", MacTagsPage()) }
                    NavTile(title: "AI 模型", detail: (ModelStore.shared.activeTaggerId.map { ModelStore.shared.displayName($0) } ?? "未安装模型") + (counts.total > 0 ? " · 已分析 \(counts.done) / \(counts.total)" : ""),
                            symbol: "sparkles", color: .purple, progress: counts.total > 0 ? Double(counts.done) / Double(counts.total) : nil, id: "nav-models") { env.open("AI 模型", MacSettingsPages.models()) }
                    NavTile(title: "同步", detail: svc.hasAccount ? (online > 0 ? "\(online) 台设备在线" : "没有发现其他在线设备") : "局域网 · 还没有加入账户", symbol: "arrow.triangle.2.circlepath", color: .green,
                            badge: (svc.status?.syncing ?? 0) > 0 ? "正在同步" : nil, badgeColor: .blue, id: "nav-sync") { env.open("同步", MacSettingsPages.sync()) }
                    NavTile(title: "问题记录", detail: AppLog.problemCount == 0 ? "没有记录到问题" : "\(AppLog.problemCount) 条警告和错误", symbol: "exclamationmark.bubble.fill", color: .orange,
                            badge: AppLog.problemCount == 0 ? nil : "\(AppLog.problemCount)", badgeColor: .orange, id: "nav-problems") { env.open("问题记录", MacSettingsPages.problems()) }
                }
            }

            preferences(stats)
            care(stats)
            danger
        }
        .onAppear { live.start() }
        .onDisappear { live.stop() }
    }

    // MARK: Blocks

    private func hero(_ stats: LibraryStats?, _ svc: SyncService) -> some View {
        let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)
        return VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("资料库").font(.system(size: 22, weight: .bold, design: .rounded))
                    Text("数量仅供核对；同步结果请查看各设备的状态。").font(.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Pill(text: svc.stateText, color: (svc.status?.syncing ?? 0) > 0 ? .blue : .secondary, symbol: "arrow.triangle.2.circlepath")
            }
            StatsStrip(stats: stats)
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            shape.fill(LinearGradient(colors: [Color.accentColor.opacity(0.20), Color.purple.opacity(0.10), Color.pink.opacity(0.06)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(shape.fill(Color(nsColor: .controlBackgroundColor).opacity(0.55)))
                .overlay(shape.strokeBorder(Color.primary.opacity(0.08)))
                .shadow(color: Color.accentColor.opacity(0.12), radius: 16, y: 6)
        }
    }

    private func preferences(_ stats: LibraryStats?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeading("偏好")
            Card(spacing: 14) {
                groupLabel("浏览与播放")
                if (stats?.bad ?? 0) > 0 || LibraryPrefs.badOnly {
                    ToggleRow(symbol: "exclamationmark.triangle.fill", color: .red, title: "只显示损坏的媒体", detail: "损坏或丢失 \(stats?.bad ?? 0) 个",
                              isOn: Binding(get: { LibraryPrefs.badOnly }, set: { LibraryPrefs.badOnly = $0 }))
                    RowDivider(inset: 42)
                }
                ToggleRow(symbol: "headphones", color: .pink, title: "仅用耳机播放声音", detail: "没连耳机时视频先静音，并询问是否开启声音",
                          isOn: Binding(get: { AudioPolicy.headphonesOnly }, set: { AudioPolicy.headphonesOnly = $0 }))
                RowDivider(inset: 42)
                ToggleRow(symbol: "hand.raised.slash.fill", color: .indigo, title: "视频禁用手势",
                          detail: "拖动不再调节进度（长按倍速、双击暂停照常）；← → 和两指左右滑动在照片和视频之间切换",
                          isOn: Binding(get: { LibraryPrefs.playerGesturesOff }, set: { LibraryPrefs.playerGesturesOff = $0 }))

                Divider().padding(.vertical, 2)
                groupLabel("搜索")
                ToggleRow(symbol: "sparkle.magnifyingglass", color: .purple, title: "语义模糊搜索",
                          detail: LibraryPrefs.semanticSearchAvailable ? "包含匹配，并找意思相近的标签" : LibraryPrefs.semanticSearchNeedsModel,
                          isOn: Binding(get: { LibraryPrefs.fuzzySearch }, set: { LibraryPrefs.fuzzySearch = $0; NotificationCenter.default.post(name: .libraryChanged, object: nil) }),
                          disabled: !LibraryPrefs.semanticSearchAvailable)
                VStack(alignment: .leading, spacing: 8) {
                    Text("在搜索框里输入这些词，按空格变成条件胶囊；其他词是要搜索的内容，可以和条件穿插。")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    FlowLayout(spacing: 6) {
                        ForEach(SearchKeyword.all, id: \.key) { kw in Pill(text: kw.info.word, color: .accentColor, symbol: kw.info.symbol) }
                    }
                }
                .padding(12)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }

    private func care(_ stats: LibraryStats?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeading("整理与维护")
            Card(spacing: 14) {
                CardRow(symbol: "rectangle.stack.fill", color: .indigo, title: "整理记录") {
                    Button("清空…") { confirmClearTriage(env.window) }
                }
                RowDivider(inset: 42)
                CardRow(symbol: "checkmark.shield.fill", color: .green, title: "媒体完整性") {
                    HStack(spacing: 10) {
                        Pill(text: Core.integritySummary()?.text ?? "无法读取检查记录", color: (stats?.bad ?? 0) > 0 ? .red : .secondary)
                        if Core.verifyStatus()?.running == true {
                            Button("停止检查") { Core.cancelVerify() }
                        } else {
                            Button("检查资料库媒体（不含回收站）") {
                                do { try Core.startVerify() } catch { macAlert(env.window, "无法开始检查", error.localizedDescription) }
                            }
                        }
                    }
                }
                RowDivider(inset: 42)
                CardRow(symbol: "stethoscope", color: .teal, title: "诊断信息") {
                    Button("导出…") { macExportDiagnostics(env.window) }
                }
            }
        }
    }

    private var danger: some View {
        Card(tint: .red, spacing: 12) {
            CardRow(symbol: "trash.fill", color: .red, title: "清除这台设备上的全部数据",
                    detail: "删除本机的全部帖子、媒体、标签、Cookie 与同步配置，恢复为全新状态。") {
                Button("清除…", role: .destructive) { MacWipeFlow.start(env.window) }.accessibilityIdentifier("wipeAll")
            }
        }
    }

    private func groupLabel(_ text: String) -> some View {
        Text(text).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
    }
}

/// Two confirmations; the decisions' effects (bin, folders) stay.
@MainActor
func confirmClearTriage(_ window: NSWindow?) {
    let n = Core.triageCounts(Core.TriageFilter())?.triaged ?? 0
    macChoose(window, title: "清空整理记录？", message: "这台设备上已整理的 \(n) 个内容会重新出现在「整理」中。已经删除或放入文件夹的结果不会被撤销。", options: ["继续"]) { _ in
        DispatchQueue.main.async {
            macChoose(window, title: "再次确认", message: "清空后无法恢复整理记录。", options: ["清空整理记录"]) { _ in
                _ = try? Core.triageClear()
                NotificationCenter.default.post(name: .libraryChanged, object: nil)
                macAlert(window, "已清空整理记录")
            }
        }
    }
}

// MARK: - Download

@MainActor
final class DownloadModel: ObservableObject {
    static let shared = DownloadModel()
    static let routes: [(title: String, detail: String, symbol: String, color: Color)] = [
        ("自动", "先用公开镜像 FxTwitter；拿不到时（例如锁定账号）再用 Cookie", "wand.and.stars", .blue),
        ("仅 FxTwitter", "公开镜像，不需要登录，也不会用到你的账号", "globe", .teal),
        ("仅 Cookie", "用你的账号下载，适合锁定账号的帖子", "key.fill", .orange),
    ]
    @Published var route = UserDefaults.standard.integer(forKey: "dl.route") { didSet { UserDefaults.standard.set(route, forKey: "dl.route") } }
    @Published var folder = ""      // "" = none; single links and batches
    @Published var links = ""
    @Published var concurrency = UserDefaults.standard.object(forKey: "dl.concurrency") as? Int ?? 3 { didSet { UserDefaults.standard.set(concurrency, forKey: "dl.concurrency") } }
    @Published var interval = UserDefaults.standard.object(forKey: "dl.interval") as? Int ?? 500 { didSet { UserDefaults.standard.set(interval, forKey: "dl.interval") } }
    @Published var batch: [String] = []
    @Published var batchName: String?
    @Published var authToken = Keychain.get("auth_token") ?? ""
    @Published var ct0 = Keychain.get("ct0") ?? ""

    var routeValue: DownloadRoute { DownloadRoute.allCases[min(max(route, 0), DownloadRoute.allCases.count - 1)] }
    var folderValue: String? { folder.isEmpty ? nil : folder }

    /// The links typed so far: how many are recognised and how many are not.
    var parsed: (good: Int, bad: Int) {
        let urls = links.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let good = urls.filter { Core.fxAPIURL(for: $0) != nil }.count
        return (good, urls.count - good)
    }

    func download(_ window: NSWindow?) {
        let urls = links.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !urls.isEmpty else { return macAlert(window, "请先粘贴帖子链接") }
        let bad = urls.filter { Core.fxAPIURL(for: $0) == nil }
        guard bad.isEmpty else { return macAlert(window, "无法识别的链接", bad.prefix(3).joined(separator: "\n")) }
        do { try Core.startDownload(DownloadRequest(urls: urls, concurrency: concurrency, intervalMs: UInt64(interval), route: routeValue, revive: true, folder: folderValue)); links = "" }
        catch { macAlert(window, "无法开始下载", error.localizedDescription) }
    }

    func startBatch(_ window: NSWindow?) {
        do {
            try Core.startDownload(DownloadRequest(urls: batch, concurrency: concurrency, intervalMs: UInt64(interval), route: routeValue, folder: folderValue, markRecent: true))
            batch = []; batchName = nil
        } catch { macAlert(window, "无法开始下载", error.localizedDescription) }
    }

    func chooseBatch(_ window: NSWindow?) { macOpenPanel([.json]) { [weak self] u in self?.loadBatch(u, window) } }

    func loadBatch(_ u: URL, _ window: NSWindow?) {
        do { batch = try Core.bookmarkURLs(in: u); batchName = u.lastPathComponent }
        catch { macAlert(window, "无法读取 JSON", error.localizedDescription) }
    }

    func newFolder(_ window: NSWindow?) {
        macPrompt(window, title: "新建文件夹", placeholder: "文件夹名称") { [weak self] n in
            let n = n.trimmingCharacters(in: .whitespaces)
            guard !n.isEmpty else { return }
            _ = try? Core.createFolder(n)
            self?.folder = n
            NotificationCenter.default.post(name: .libraryChanged, object: nil)
        }
    }

    func saveCookies(_ window: NSWindow?) {
        let ok1 = Keychain.set("auth_token", authToken.trimmingCharacters(in: .whitespacesAndNewlines))
        let ok2 = Keychain.set("ct0", ct0.trimmingCharacters(in: .whitespacesAndNewlines))
        Session.applyStoredCookies()
        macAlert(window, ok1 && ok2 ? "Cookie 已保存" : "Cookie 没有保存", ok1 && ok2 ? "" : "钥匙串拒绝了保存，请再试一次。")
    }
}

struct DownloadPageView: View {
    @EnvironmentObject private var env: PaneEnv
    @StateObject private var live = LiveTick()
    @StateObject private var m = DownloadModel.shared
    @State private var dropTargeted = false

    var body: some View {
        let _ = live.count
        let status = Core.downloadStatus()
        let folders = Core.folders().map(\.name)
        let parsed = m.parsed
        SettingsCanvas {
            if status?.running == true, let a = ActivityCenter.shared.activities.first(where: { $0.kind == .download }) {
                Card(tint: .accentColor, spacing: 14) {
                    ActivityRow(activity: a)
                    HStack { Spacer()
                        Button("暂停") { do { try Core.stopDownload(pause: true) } catch { macAlert(env.window, "无法暂停", error.localizedDescription) } }
                        Button("取消下载", role: .destructive) { do { try Core.stopDownload(pause: false) } catch { macAlert(env.window, "无法取消", error.localizedDescription) } }
                    }
                }
            }

            if let d = status, !d.running, d.total > 0 { Text(d.outcomeText + " · 完成 \(d.done) · 失败 \(d.failed)").foregroundStyle(.secondary) }
            if let d = status, !d.running, d.paused > 0 {
                HStack {
                    Text("已暂停 \(d.paused) 个待下载任务")
                    Button("继续下载") { do { try Core.resumeDownload() } catch { macAlert(env.window, "无法继续", error.localizedDescription) } }
                    Button("取消这些任务", role: .destructive) { do { try Core.stopDownload(pause: false) } catch { macAlert(env.window, "无法取消", error.localizedDescription) } }
                }
            }
            Text("暂停后需手动继续；取消会移除未完成任务，已下载内容保留。").font(.caption).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 10) {
                SectionHeading("下载方式", note: "对单条链接和批量 JSON 同样生效。")
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 12, alignment: .top)], spacing: 12) {
                    ForEach(Array(DownloadModel.routes.enumerated()), id: \.offset) { i, r in
                        OptionCard(title: r.title, detail: r.detail, symbol: r.symbol, color: r.color, selected: m.route == i) { m.route = i }
                    }
                }
                Card(spacing: 10) {
                    Label("保存到文件夹", systemImage: "folder").font(.system(size: 13, weight: .medium))
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ChipButton(title: "不放入文件夹", selected: m.folder.isEmpty) { m.folder = "" }
                            ForEach(folders, id: \.self) { f in ChipButton(title: f, symbol: "folder", selected: m.folder == f) { m.folder = f } }
                            ChipButton(title: "新建文件夹…", symbol: "plus", dashed: true) { m.newFolder(env.window) }
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                SectionHeading("下载帖子", note: "每行一个链接，视频只保存 MP4。")
                Card(spacing: 12) {
                    PlaceholderEditor(text: $m.links, placeholder: "粘贴帖子链接，每行一个\nhttps://x.com/用户名/status/…", minHeight: 120)
                        .accessibilityLabel("帖子链接")
                    HStack(spacing: 8) {
                        if parsed.good > 0 { Pill(text: "识别 \(parsed.good) 条", color: .green, symbol: "checkmark") }
                        if parsed.bad > 0 { Pill(text: "\(parsed.bad) 条无法识别", color: .orange, symbol: "exclamationmark.triangle.fill") }
                        Spacer()
                        Button { m.download(env.window) } label: { Label("下载", systemImage: "arrow.down.circle.fill") }
                            .buttonStyle(.borderedProminent).controlSize(.large).disabled(parsed.good == 0)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                SectionHeading("批量导入收藏夹", note: "用油猴脚本 Twitter Web Exporter 导出的收藏夹 JSON，按并发数和间隔逐条下载。中断后再次开始会从未完成的帖子继续。")
                Card(spacing: 16) {
                    dropZone
                    VStack(spacing: 12) {
                        sliderRow("并发", "同时下载几个帖子", value: Double(m.concurrency), display: "\(m.concurrency)") {
                            Slider(value: Binding(get: { Double(m.concurrency) }, set: { m.concurrency = Int($0.rounded()) }), in: 1...16, step: 1)
                        }
                        sliderRow("间隔", "每个帖子开始前等待多久", value: Double(m.interval), display: String(format: "%.2f 秒", Double(m.interval) / 1000)) {
                            Slider(value: Binding(get: { Double(m.interval) }, set: { m.interval = Int($0.rounded()) }), in: 0...10000, step: 250)
                        }
                    }
                    HStack { Spacer(); Button { m.startBatch(env.window) } label: { Label("开始批量下载", systemImage: "square.and.arrow.down.on.square.fill") }
                        .buttonStyle(.borderedProminent).controlSize(.large).disabled(m.batch.isEmpty) }
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                SectionHeading("账号 Cookie", note: "下载锁定账号的帖子时使用。在浏览器登录 x.com，从开发者工具的 Cookie 中复制 auth_token 与 ct0。仅保存在本机钥匙串，不会同步。",
                               trailing: AnyView(Pill(text: (!m.authToken.isEmpty && !m.ct0.isEmpty) ? "已设置" : "未设置", color: (!m.authToken.isEmpty && !m.ct0.isEmpty) ? .green : .secondary,
                                                      symbol: (!m.authToken.isEmpty && !m.ct0.isEmpty) ? "lock.fill" : "lock.open")))
                Card(spacing: 12) {
                    secretField("auth_token", $m.authToken)
                    secretField("ct0", $m.ct0)
                    HStack(spacing: 8) {
                        Spacer()
                        Button("检查 Cookie") {
                            // a network request of up to ~30 s: never on the main thread
                            let w = env.window
                            macRun(w, { Core.checkCookies() }) { r in macAlert(w, r.title, r.detail) }
                        }
                        Button("保存 Cookie") { m.saveCookies(env.window) }.buttonStyle(.borderedProminent)
                    }
                }
            }

            if let status, !status.errors.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    SectionHeading("失败记录（\(status.errors.count)）")
                    Card(tint: .orange, spacing: 10) {
                        ForEach(Array(status.errors.suffix(8).reversed().enumerated()), id: \.offset) { _, e in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(e.first ?? "").font(.caption.weight(.semibold))
                                Text(e.last ?? "").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                        }
                    }
                }
            }
        }
        .onAppear { live.start(every: 1) }
        .onDisappear { live.stop() }
    }

    // MARK: Pieces

    /// The place to drop (or choose) a bookmarks JSON.
    private var dropZone: some View {
        Button { m.chooseBatch(env.window) } label: {
            HStack(spacing: 14) {
                IconTile(symbol: m.batchName == nil ? "tray.and.arrow.down.fill" : "doc.text.fill", color: m.batchName == nil ? .indigo : .green, size: 42)
                VStack(alignment: .leading, spacing: 3) {
                    Text(m.batchName ?? "选择或拖入收藏夹 JSON").font(.system(size: 14, weight: .semibold))
                    Text(m.batchName == nil ? "Twitter Web Exporter 导出的收藏夹 JSON，里面的每个帖子链接会逐条下载" : "\(m.batch.count) 个帖子，点一下换一个文件").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if m.batchName != nil { Pill(text: "\(m.batch.count) 个帖子", color: .green, symbol: "checkmark") }
            }
            .padding(14)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(dropTargeted ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(dropTargeted ? Color.accentColor : Color.secondary.opacity(0.4), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            guard let p = providers.first else { return false }
            let window = env.window
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                DispatchQueue.main.async { m.loadBatch(url, window) }
            }
            return true
        }
    }

    private func sliderRow<S: View>(_ title: String, _ note: String, value: Double, display: String, @ViewBuilder slider: () -> S) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13.5, weight: .medium))
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
            .frame(width: 130, alignment: .leading)
            slider()
            Text(display).font(.system(size: 13, weight: .semibold, design: .rounded)).monospacedDigit().frame(width: 70, alignment: .trailing)
        }
    }

    private func secretField(_ name: String, _ text: Binding<String>) -> some View {
        HStack(spacing: 12) {
            Text(name).font(.system(size: 13, weight: .medium, design: .monospaced)).frame(width: 90, alignment: .leading)
            SecureField(name, text: text, prompt: Text("未设置")).labelsHidden().textFieldStyle(.roundedBorder)
        }
    }
}

// MARK: - Import and backup

struct TransferPageView: View {
    @EnvironmentObject private var env: PaneEnv
    @StateObject private var live = LiveTick()

    var body: some View {
        let _ = live.count
        let reports = Array(Core.importReports().prefix(8))
        let df: DateFormatter = { let f = DateFormatter(); f.dateFormat = "M月d日 HH:mm"; return f }()
        SettingsCanvas {
            ActivityCard(kinds: [.importing])

            VStack(alignment: .leading, spacing: 10) {
                SectionHeading("导入", note: "导入时可以选择放进一个文件夹；边读边存，不需要额外的解压空间。")
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 14, alignment: .top)], spacing: 14) {
                    NavTile(title: "旧版 ZIP", detail: "根文件夹内每个子文件夹是一个帖子；有「推文内容.txt」就读取作者、链接与原文", symbol: "archivebox.fill", color: .brown) {
                        importFile([.zip]) { try Core.importLegacyZip($0, folder: $1) }
                    }
                    NavTile(title: "散装媒体 ZIP", detail: "只有图片和视频、没有任何结构，每个文件成为一个「散装媒体」", symbol: "square.dashed", color: .indigo) {
                        importFile([.zip]) { try Core.importLooseZip($0, folder: $1) }
                    }
                    NavTile(title: "导出包 .tlpack", detail: "本应用导出的包或整库备份，带着标签和文件夹一起回来", symbol: "shippingbox.fill", color: .blue) {
                        importFile([.tlpack, .zip]) { try Core.importPack($0, folder: $1) }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                SectionHeading("备份")
                Card(tint: .purple, spacing: 14) {
                    HStack(alignment: .top, spacing: 14) {
                        IconTile(symbol: "externaldrive.fill.badge.timemachine", color: .purple, size: 44)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("备份整个资料库").font(.system(size: 15, weight: .semibold))
                            Text("用于冷备份：所有媒体（也包括回收站里的）、帖子正文、标签及其来源、AI 分析记录、文件夹（包括空文件夹）、标签改名规则和「最近添加」标记。不含 AI 模型、整理记录、设备配对和导入记录。")
                                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 8)
                        Button { backup() } label: { Label("备份…", systemImage: "arrow.down.doc.fill") }.buttonStyle(.borderedProminent).controlSize(.large)
                    }
                    Text("边读边写，每个文件都会核对校验值，损坏或缺失的文件会单独列出。恢复时在任意设备上「导入 .tlpack」即可。要导出一部分内容：在「浏览」里搜索，再点搜索框旁的导出按钮。")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }

            if !reports.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    SectionHeading("导入记录", note: "每次导入都会记下每个没有正常导入的文件和文件夹：路径、原因、与哪个文件相同。可以查看，也可以把这些文件原样导出。",
                                   trailing: AnyView(Button("删除全部…") { let all = Core.importReports(); deleteReports(all.map(\.file), what: "全部 \(all.count) 条导入记录") }.buttonStyle(.borderless).foregroundStyle(.red)))
                    Card(spacing: 12) {
                        ForEach(Array(reports.enumerated()), id: \.element.file) { i, r in
                            if i > 0 { RowDivider() }
                            HStack(spacing: 12) {
                                IconTile(symbol: r.issues == 0 ? "checkmark" : "exclamationmark", color: r.issues == 0 ? .green : .orange, size: 30)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(URL(fileURLWithPath: r.source).lastPathComponent).font(.system(size: 13.5, weight: .medium)).lineLimit(1).truncationMode(.middle)
                                    Text(df.string(from: r.date)).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 8)
                                Pill(text: r.issues == 0 ? "全部正常" : "\(r.issues) 项需要注意", color: r.issues == 0 ? .green : .orange)
                                Button("查看…") { MacImportReportWindowController.show(reportFile: r.file) }
                                Button("删除") { deleteReports([r.file], what: "这条导入记录") }
                            }
                        }
                    }
                }
            }
        }
        .onAppear { live.start() }
        .onDisappear { live.stop() }
    }

    private func importFile(_ types: [UTType], _ work: @escaping (URL, String?) throws -> ImportReport) {
        let window = env.window
        macOpenPanel(types) { url in
            DispatchQueue.main.async {
                macChooseFolder(window, title: "导入到文件夹？", suggested: url.deletingPathExtension().lastPathComponent) { folder in
                    macRun(window, { try work(url, folder) }) { r in
                        NotificationCenter.default.post(name: .libraryChanged, object: nil)
                        macShowImportResult(window, r)
                        live.poke()
                    }
                }
            }
        }
    }

    /// Deletes import records; a share's leftover problem files go with them (they are the app's
    /// own copies). Files you imported from elsewhere on this Mac are never touched.
    private func deleteReports(_ files: [String], what: String) {
        guard !files.isEmpty else { return }
        let window = env.window
        macChoose(window, title: "删除\(what)？", message: "删除后无法再查看这些记录，也不能再从记录里导出问题文件。通过「分享」导入时留在 App 里的问题文件会一起删除；你从这台 Mac 其他位置导入的原始文件不会被删除。", options: ["删除"]) { _ in
            do {
                let r = try Core.deleteImportReports(files, owned: ShareInbox.ownedRoots)
                live.poke()
                macAlert(window, "已删除 \(r.reports) 条记录", r.sources > 0 ? "同时删除了 App 里保存的 \(r.sources) 份问题文件，释放 \(ActivityCenter.bytes(r.bytes))" : nil)
            } catch { macAlert(window, "删除失败", error.localizedDescription) }
        }
    }

    private func backup() {
        let window = env.window
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HHmm"
        macSavePanel("TwimShelf 备份 \(f.string(from: Date())).tlpack") { url in
            macRunProgress(window, title: "正在备份整个资料库…", progress: {
                guard let p = Core.exportStatus(), p.total > 0 else { return nil }
                return "\(p.done) / \(p.total) 个媒体 · \(ActivityCenter.bytes(p.bytes))"
            }, cancel: { Core.cancelExport() }, { try Core.exportBackup(to: url) }) { r in
                var t = "\(r.posts) 个帖子、\(r.media) 个媒体（其中回收站 \(r.trashed ?? 0) 个）· \(ActivityCenter.bytes(r.bytes))"
                let skipped = r.skipped ?? []
                if !skipped.isEmpty {
                    t += "\n\n有 \(skipped.count) 个媒体没有备份："
                    for s in skipped.prefix(15) { t += "\n· \(s.postId.hasPrefix("loose:") ? "散装媒体" : "帖子 \(s.postId)") 的 \(s.mediaId.prefix(10))…：\(s.reason)" }
                    if skipped.count > 15 { t += "\n……还有 \(skipped.count - 15) 个" }
                }
                macAlert(window, skipped.isEmpty ? "备份完成" : "备份完成（有遗漏）", t)
            }
        }
    }
}

// MARK: - Problems and rename rules

struct ProblemsPageView: View {
    @StateObject private var live = LiveTick()
    var body: some View {
        let _ = live.count
        let list = AppLog.recentProblems()
        let df: DateFormatter = { let f = DateFormatter(); f.dateFormat = "M月d日 HH:mm:ss"; return f }()
        SettingsCanvas {
            if list.isEmpty {
                emptyState(symbol: "checkmark.seal.fill", color: .green, title: "没有记录到问题", detail: "警告和错误会出现在这里。")
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    SectionHeading("最近 \(list.count) 条", note: Diagnostics.contents)
                    Card(padding: 4, spacing: 0) {
                        ForEach(Array(list.prefix(200).enumerated()), id: \.offset) { i, e in
                            if i > 0 { RowDivider() }
                            HStack(alignment: .top, spacing: 12) {
                                Capsule().fill(e.level == .error ? Color.red : Color.orange).frame(width: 4)
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 8) {
                                        Pill(text: e.cat, color: e.level == .error ? .red : .orange)
                                        Text(df.string(from: e.date)).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Text(e.msg).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 14).padding(.vertical, 10)
                        }
                    }
                }
            }
        }
        .onAppear { live.start() }
        .onDisappear { live.stop() }
    }
}

struct TagRenamesPageView: View {
    @StateObject private var live = LiveTick()
    var body: some View {
        let _ = live.count
        let renames = Core.tagRenames()
        SettingsCanvas {
            if renames.isEmpty {
                emptyState(symbol: "tag.slash.fill", color: .indigo, title: "还没有改名的标签",
                           detail: "在标签页的卡片上右键 →「重命名或合并…」即可改名或合并。")
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    SectionHeading("标签改名", note: "改名不会改写任何标签记录：旧名字显示为新名字，正在进行的 AI 标记和其他设备也一样；撤销后旧名字重新单独显示。")
                    Card(padding: 4, spacing: 0) {
                        ForEach(Array(renames.enumerated()), id: \.element.old) { i, r in
                            if i > 0 { RowDivider() }
                            HStack(spacing: 12) {
                                Pill(text: r.old, color: .secondary)
                                Image(systemName: "arrow.right").font(.caption.weight(.bold)).foregroundStyle(.tertiary)
                                Pill(text: r.current, color: .indigo)
                                Spacer(minLength: 8)
                                Button("撤销") {
                                    try? Core.undoRename(r.old)
                                    NotificationCenter.default.post(name: .libraryChanged, object: nil)
                                }
                            }
                            .padding(.horizontal, 14).padding(.vertical, 10)
                        }
                    }
                }
            }
        }
        .onAppear { live.start() }
        .onDisappear { live.stop() }
    }
}

/// A page with nothing to show: a big symbol and a sentence.
func emptyState(symbol: String, color: Color, title: String, detail: String) -> some View {
    VStack(spacing: 10) {
        Image(systemName: symbol).font(.system(size: 44)).foregroundStyle(color.gradient)
        Text(title).font(.system(size: 17, weight: .semibold))
        Text(detail).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
    }
    .frame(maxWidth: .infinity)
    .padding(.top, 70)
}

struct QuickDownloadView: View {
    @ObservedObject var model = DownloadModel.shared
    var openSettings: () -> Void
    var download: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("下载帖子").font(.headline)
            Text("每行一个帖子链接，支持一次粘贴多条链接")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: $model.links)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(height: 140)
                .background(.background, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.secondary.opacity(0.3)))
                .accessibilityLabel("帖子链接，每行一条")
                .accessibilityIdentifier("quickDownloadLinks")
            HStack {
                Button("跳转到下载设置", action: openSettings)
                Spacer()
                Button("下载", action: download)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(model.links.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}
