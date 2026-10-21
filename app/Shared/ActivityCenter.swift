import Foundation

/// One running task the UI should show progress for.
struct Activity: Equatable, Identifiable {
    enum Kind: String { case download, model, tagging, sync, verify, importing }
    let kind: Kind
    var id: String { kind.rawValue }
    var title: String
    var detail: String
    /// 0…1, or nil for indeterminate.
    var progress: Double?
    /// File to preview (photo or MP4) — the item currently being processed.
    var previewPath: String?
    var previewIsVideo: Bool

    /// A stopped worker is not proof of success. Only an explicit success fills the bar.
    func ended(outcome: String, detail: String? = nil, progress: Double? = nil) -> Activity {
        var result = self
        let prefix: String
        switch outcome {
        case "succeeded": prefix = "已完成"
        case "partial": prefix = "部分完成，有问题需处理"
        case "failed": prefix = "失败"
        case "cancelled": prefix = "已取消"
        case "paused": prefix = "已暂停"
        default: prefix = "已停止"
        }
        result.title = prefix + " · " + title.replacingOccurrences(of: "正在", with: "")
        if let detail { result.detail = detail }
        result.progress = outcome == "succeeded" ? 1 : (progress ?? self.progress)
        return result
    }
}

/// Polls every source of background work (downloads, model downloads, AI tagging, sync) and
/// publishes a single list the progress UI renders on both platforms.
@MainActor
final class ActivityCenter {
    static let shared = ActivityCenter()
    static let changed = Notification.Name("ActivityCenterChanged")

    private(set) var activities: [Activity] = []
    private(set) var stats: LibraryStats?
    private var timer: Timer?
    private var lastDownloadRunning = false
    private var lastModelRunning = false
    private var lastDownloadRecent: String?
    private var lastVerifyRunning = false

    func start() {
        guard timer == nil else { return }
        // Sync status changes (incl. received media) refresh stats promptly.
        NotificationCenter.default.addObserver(forName: SyncService.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
        NotificationCenter.default.addObserver(forName: .libraryChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshStats() }
        }
        refreshStats()
        tick()
        resumeInterruptedDownloads()
    }

    /// Links whose download was cut off by a quit or crash stay queued in the library; they
    /// continue by themselves (with the saved concurrency and interval) a moment after launch.
    private func resumeInterruptedDownloads() {
        guard (stats?.pendingJobs ?? 0) > 0, ProcessInfo.processInfo.environment["TL_SELFTEST"] == nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            guard Core.downloadStatus()?.running != true, let n = Core.stats()?.pendingJobs, n > 0 else { return }
            let d = UserDefaults.standard
            let req = DownloadRequest(urls: [], concurrency: d.object(forKey: "dl.concurrency") as? Int ?? 3, intervalMs: UInt64(d.object(forKey: "dl.interval") as? Int ?? 500))
            if (try? Core.startDownload(req)) != nil { AppLog.info("download", "继续上次未完成的 \(n) 个帖子"); self.refreshNow() }
        }
    }

    func refreshStats() {
        let s = Core.stats()
        // every field: records from a newer app version (newerOps) arrive without any change of
        // the media counts, and the sync pages must still show them
        if s != stats {
            stats = s
            NotificationCenter.default.post(name: Self.changed, object: nil)
        }
    }

    /// Re-reads the running work now (after starting a download: its progress appears at once).
    func refreshNow() { tick() }

    private func tick() {
        var list: [Activity] = []
        if let d = Core.downloadStatus(), d.running {
            let recent = d.recent.last
            list.append(Activity(kind: .download, title: "正在下载帖子",
                                 detail: "\(d.finished) / \(d.total)" + (d.failed > 0 ? " · 失败 \(d.failed)" : "") + (d.active.isEmpty ? "" : " · 进行中 \(d.active.count)"),
                                 progress: d.total > 0 ? Double(d.finished) / Double(d.total) : nil,
                                 previewPath: recent, previewIsVideo: recent.map(isVideoPath) ?? false))
            if recent != lastDownloadRecent { lastDownloadRecent = recent; refreshStats() }
        }
        if lastDownloadRunning, Core.downloadStatus()?.running != true {
            NotificationCenter.default.post(name: .libraryChanged, object: nil)
        }
        lastDownloadRunning = Core.downloadStatus()?.running ?? false
        // A model download ending anywhere (not only while the models page is open) installs it:
        // the list is re-read, and a failure goes to the problem log.
        let modelRunning = Core.modelStatus()?.running ?? false
        if lastModelRunning, !modelRunning, let m = Core.modelStatus() {
            if m.finished { ModelStore.shared.reload() }
            else if let e = m.error, e != "已取消" { AppLog.error("model", "下载模型 \(m.repo) 失败：\(e)") }
        }
        lastModelRunning = modelRunning
        if let m = Core.modelStatus(), m.running {
            list.append(Activity(kind: .model, title: "正在下载模型 \(ModelCatalog.find(m.repo)?.displayName ?? m.repo)",
                                 detail: "\(Self.bytes(m.doneBytes)) / \(Self.bytes(m.totalBytes))",
                                 progress: m.totalBytes > 0 ? Double(m.doneBytes) / Double(m.totalBytes) : nil, previewPath: nil, previewIsVideo: false))
        }
        let t = AutoTagger.shared
        if t.running {
            list.append(Activity(kind: .tagging, title: t.title, detail: "\(t.done) / \(max(t.total, t.done))",
                                 progress: t.total > 0 ? Double(t.done) / Double(t.total) : nil,
                                 previewPath: t.currentPath, previewIsVideo: t.currentKind == "video"))
        }
        if let s = SyncService.shared.status, s.syncing > 0 {
            if let t = s.receiving, t.total > 0 {
                let inFlight = t.currentSize > 0 ? Double(t.currentDone) / Double(t.currentSize) : 0
                let leftFiles = t.total > t.received ? t.total - t.received : 0
                var detail = "剩余 \(leftFiles) 个"
                if t.totalBytes > 0 {
                    detail += " · \(Self.bytes(t.totalBytes > t.bytes ? t.totalBytes - t.bytes : 0))"
                    detail += "（已收 \(t.received)/\(t.total) · \(Self.bytes(t.bytes)) / \(Self.bytes(t.totalBytes))）"
                } else {
                    detail += "（已收 \(t.received)/\(t.total) · \(Self.bytes(t.bytes))）"
                }
                if t.currentSize > 8_000_000 { detail += " · 当前文件 \(Int(inFlight * 100))%" }
                let progress = t.totalBytes > 0 ? Double(t.bytes) / Double(t.totalBytes) : (Double(t.received) + inFlight) / Double(t.total)
                list.append(Activity(kind: .sync, title: "正在从其他设备接收媒体", detail: detail,
                                     progress: progress,
                                     previewPath: t.lastPath, previewIsVideo: t.lastPath.map(isVideoPath) ?? false))
            } else {
                list.append(Activity(kind: .sync, title: "正在与其他设备同步", detail: "局域网 · 交换变更", progress: nil, previewPath: nil, previewIsVideo: false))
            }
        }
        if let i = Core.importStatus(), i.running {
            list.append(Activity(kind: .importing, title: i.waiting == true ? "等待上一个导入完成" : "正在导入",
                                 detail: "帖子文件夹 \(i.foldersDone) / \(i.foldersTotal) · 媒体 \(i.filesDone)" + (i.issues > 0 ? " · 有问题的 \(i.issues)" : ""),
                                 progress: i.foldersTotal > 0 ? Double(i.foldersDone) / Double(i.foldersTotal) : nil,
                                 previewPath: i.current, previewIsVideo: i.current.map(isVideoPath) ?? false))
        }
        if let v = Core.verifyStatus() {
            if v.running {
                list.append(Activity(kind: .verify, title: "正在检查媒体完整性",
                                     detail: "\(v.checked) / \(v.total) · \(Self.bytes(v.bytes))" + (v.bad > 0 ? " · 发现 \(v.bad) 个损坏" : ""),
                                     progress: v.total > 0 ? Double(v.checked) / Double(v.total) : nil,
                                     previewPath: v.current, previewIsVideo: v.current.map(isVideoPath) ?? false))
            }
            if lastVerifyRunning && !v.running { refreshStats(); NotificationCenter.default.post(name: .libraryChanged, object: nil) }
            lastVerifyRunning = v.running
        }
        list = holdBriefly(list)
        if list != activities {
            activities = list
            NotificationCenter.default.post(name: Self.changed, object: nil)
        }
    }

    /// When each card first appeared, and the last state of each running one.
    private var shownSince: [Activity.Kind: Date] = [:]
    private var lastRunning: [Activity.Kind: Activity] = [:]
    private var finishedUntil: [Activity.Kind: Date] = [:]
    static let minimumShown: TimeInterval = 2

    /// A card stays at least two seconds, so it is never gone before it can be read: work that
    /// ends sooner retains its actual terminal outcome and progress for the rest of that time, and at least a moment.
    private func holdBriefly(_ running: [Activity]) -> [Activity] {
        let now = Date()
        var out = running
        let live = Set(running.map(\.kind))
        for a in running {
            if shownSince[a.kind] == nil || finishedUntil[a.kind] != nil { shownSince[a.kind] = now }
            finishedUntil[a.kind] = nil
            lastRunning[a.kind] = a
        }
        for (kind, last) in lastRunning where !live.contains(kind) {
            if finishedUntil[kind] == nil {
                let since = shownSince[kind] ?? now
                finishedUntil[kind] = max(since.addingTimeInterval(Self.minimumShown), now.addingTimeInterval(1.2))
            }
            if let until = finishedUntil[kind], now < until {
                out.append(completed(last))
            } else {
                lastRunning[kind] = nil; finishedUntil[kind] = nil; shownSince[kind] = nil
            }
        }
        return out
    }

    private func completed(_ last: Activity) -> Activity {
        switch last.kind {
        case .download:
            guard let d = Core.downloadStatus() else { return last.ended(outcome: "stopped") }
            return last.ended(outcome: d.outcome, detail: "完成 \(d.done) · 已有 \(d.skipped) · 失败 \(d.failed) / 共 \(d.total)", progress: d.total > 0 ? Double(d.finished) / Double(d.total) : nil)
        case .model:
            guard let m = Core.modelStatus() else { return last.ended(outcome: "stopped") }
            return last.ended(outcome: m.finished ? "succeeded" : (m.error == "已取消" ? "cancelled" : "failed"), detail: m.error, progress: m.totalBytes > 0 ? Double(m.doneBytes) / Double(m.totalBytes) : nil)
        case .tagging:
            let t = AutoTagger.shared
            return last.ended(outcome: t.outcome, detail: t.lastError ?? "\(t.done) / \(t.total)", progress: t.total > 0 ? Double(t.done) / Double(t.total) : nil)
        case .importing:
            guard let i = Core.importStatus() else { return last.ended(outcome: "stopped") }
            return last.ended(outcome: i.outcome, detail: "帖子文件夹 \(i.foldersDone)/\(i.foldersTotal) · 媒体 \(i.filesDone) · 问题 \(i.issues)", progress: i.foldersTotal > 0 ? Double(i.foldersDone) / Double(i.foldersTotal) : nil)
        case .verify:
            guard let v = Core.verifyStatus() else { return last.ended(outcome: "stopped") }
            return last.ended(outcome: v.outcome, detail: "已检查 \(v.checked)/\(v.total) · 发现 \(v.bad) 个损坏", progress: v.total > 0 ? Double(v.checked) / Double(v.total) : nil)
        case .sync:
            // No aggregate session-success signal: report the observed state without
            // claiming all peers or every file have converged.
            var result = last
            result.title = SyncService.shared.stateText
            result.progress = nil
            result.detail = "请在同步页面查看各设备的结果"
            return result
        }
    }

    static func bytes(_ b: UInt64) -> String { ByteCountFormatter.string(fromByteCount: Int64(b), countStyle: .file) }

    /// "帖子 12 · 照片 30 · 视频 4" for cross-device checks.
    var statsLine: String {
        guard let s = stats else { return "" }
        return "帖子 \(s.posts) · 照片 \(s.photos) · 视频 \(s.videos)"
    }
}
