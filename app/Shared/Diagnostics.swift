import Foundation
#if canImport(MetricKit)
import MetricKit
#endif
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// The app's problem log: every error and warning, with its time and the part of the app it came
/// from, in `logs/app.log` (rotated at 1 MB, one older file kept). It never records library
/// content — no post text, image, tag name or file name: messages are error causes and counts,
/// and paths are shortened to their last component kinds. Export it with `Diagnostics.export`.
enum AppLog {
    enum Level: String, Codable { case info, warn, error }
    struct Entry: Codable, Hashable { let t: Double; let level: Level; let cat: String; let msg: String
        var date: Date { Date(timeIntervalSince1970: t) } }

    static var dir: URL { Core.libraryDirectory.appendingPathComponent("logs", isDirectory: true) }
    static var file: URL { dir.appendingPathComponent("app.log") }
    private static let queue = DispatchQueue(label: "AppLog", qos: .utility)
    static let changed = Notification.Name("AppLog.changed")

    static func info(_ cat: String, _ msg: String) { write(.info, cat, msg) }
    static func warn(_ cat: String, _ msg: String) { write(.warn, cat, msg) }
    static func error(_ cat: String, _ msg: String) { write(.error, cat, msg) }

    static func write(_ level: Level, _ cat: String, _ msg: String) {
        let e = Entry(t: Date().timeIntervalSince1970, level: level, cat: cat, msg: sanitize(msg))
        queue.async {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if let a = try? FileManager.default.attributesOfItem(atPath: file.path), (a[.size] as? Int ?? 0) > 1 << 20 {
                let old = dir.appendingPathComponent("app.1.log")
                try? FileManager.default.removeItem(at: old)
                try? FileManager.default.moveItem(at: file, to: old)
            }
            guard var line = try? JSONEncoder().encode(e) else { return }
            line.append(0x0A)
            if let h = try? FileHandle(forWritingTo: file) { h.seekToEndOfFile(); h.write(line); try? h.close() }
            else { try? line.write(to: file) }
            if level != .info { DispatchQueue.main.async { problemCount = min(problemCount + 1, 200); NotificationCenter.default.post(name: changed, object: nil) } }
        }
        #if DEBUG
        NSLog("[%@/%@] %@", level.rawValue, cat, e.msg)
        #endif
    }

    /// Keeps causes, drops personal detail: the home folder becomes "~", long paths keep only
    /// their last component, and messages are capped.
    /// Links, paths and file names are removed entirely (a file name can say what the
    /// library holds); the cause around them stays readable.
    static func sanitize(_ s: String) -> String {
        var t = s.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        t = t.replacingOccurrences(of: #"(?i)\b[a-z][a-z0-9+.-]{1,15}://[^\s)"'”]+"#, with: "<链接>", options: .regularExpression)
        t = t.replacingOccurrences(of: #"(?:~|/)(?:[^\s/：:，,"'“”)]+/)+[^\s：:，,"'“”)]*"#, with: "<路径>", options: .regularExpression)
        t = t.replacingOccurrences(of: #"(?i)[^\s/"'“”「」<>]+\.(?:jpe?g|png|gif|webp|heic|heif|avif|mp4|mov|m4v|zip|tlpack|json|txt)\b"#, with: "<文件名>", options: .regularExpression)
        return t.count > 400 ? String(t.prefix(400)) + "…" : t
    }

    /// "清除所有数据": the problem log, crash reports and the core's counts log go too (the
    /// running marker stays: it tells the next launch whether this run ended normally).
    static func wipe() {
        queue.sync {
            let fm = FileManager.default
            for n in ["app.log", "app.1.log", "diagnostics.log", "diagnostics.1.log", "crashes"] { try? fm.removeItem(at: dir.appendingPathComponent(n)) }
            try? fm.createDirectory(at: dir.appendingPathComponent("crashes"), withIntermediateDirectories: true)
        }
        DispatchQueue.main.async { problemCount = 0; NotificationCenter.default.post(name: changed, object: nil) }
    }

    /// How many warnings and errors the log holds (capped at 200, like the list), kept up to date
    /// as they are written: the settings pages show it on every refresh, and re-reading the log
    /// file each time on the main thread made them stutter while a download was running.
    private(set) static var problemCount: Int = {
        DispatchQueue.global(qos: .utility).async {
            let n = recentProblems().count
            DispatchQueue.main.async { problemCount = n; NotificationCenter.default.post(name: changed, object: nil) }
        }
        return 0
    }()

    /// Warnings and errors, newest first.
    static func recentProblems(limit: Int = 200) -> [Entry] {
        queue.sync {
            var lines: [Entry] = []
            for f in [dir.appendingPathComponent("app.1.log"), file] {
                guard let d = try? Data(contentsOf: f) else { continue }
                for l in d.split(separator: 0x0A) { if let e = try? JSONDecoder().decode(Entry.self, from: l), e.level != .info { lines.append(e) } }
            }
            return Array(lines.reversed().prefix(limit))
        }
    }
}

/// Crash and exit watching: the system's own crash diagnostics (MetricKit, delivered on the next
/// launch), uncaught Objective-C exceptions, and a marker telling whether the last run ended
/// normally. Everything goes into the logs folder and the export.
final class CrashWatch: NSObject {
    static let shared = CrashWatch()
    /// The previous run did not end normally (crash, killed by the system, forced quit).
    private(set) var lastRunAbnormal = false
    private var marker: URL { AppLog.dir.appendingPathComponent("running.json") }
    static var crashesDir: URL { AppLog.dir.appendingPathComponent("crashes", isDirectory: true) }

    /// Keeps the 20 newest crash reports (each can be large), so the folder never grows without end.
    static func pruneCrashes(keep: Int = 20) {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: crashesDir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let dated = files.map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
        for (f, _) in dated.sorted(by: { $0.1 > $1.1 }).dropFirst(keep) { try? fm.removeItem(at: f) }
    }

    func start() {
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.crashesDir, withIntermediateDirectories: true)
        Self.pruneCrashes()
        if let d = try? Data(contentsOf: marker), let m = try? JSONSerialization.jsonObject(with: d) as? [String: Any], (m["active"] as? Bool) == true {
            lastRunAbnormal = true
            let v = m["version"] as? String ?? "?"
            AppLog.error("lifecycle", "上次运行（版本 \(v)）没有正常结束：崩溃、被系统终止（例如内存不足）或被强制退出")
        }
        setActive(true)
        AppLog.info("lifecycle", "启动 版本 \(Self.version) · \(Self.platform)")
        NSSetUncaughtExceptionHandler { e in
            // synchronous: the process is about to end
            let text = "未捕获的异常 \(e.name.rawValue)\n原因：\(AppLog.sanitize(e.reason ?? ""))\n\n" + e.callStackSymbols.joined(separator: "\n")
            let f = CrashWatch.crashesDir.appendingPathComponent("exception-\(Int(Date().timeIntervalSince1970)).txt")
            try? text.data(using: .utf8)?.write(to: f)
        }
        #if canImport(MetricKit)
        MXMetricManager.shared.add(self)
        #endif
        let nc = NotificationCenter.default
        #if canImport(UIKit)
        // a backgrounded app may be ended by the system at any time: that is a normal end
        nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in self?.setActive(false) }
        nc.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in self?.setActive(true) }
        nc.addObserver(forName: UIApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in self?.setActive(false) }
        nc.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { _ in AppLog.warn("memory", "系统内存警告") }
        #else
        nc.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in self?.setActive(false) }
        #endif
    }

    private func setActive(_ on: Bool) {
        let m: [String: Any] = ["active": on, "version": Self.version, "t": Date().timeIntervalSince1970]
        if let d = try? JSONSerialization.data(withJSONObject: m) { try? d.write(to: marker, options: .atomic) }
    }

    static var version: String {
        let i = Bundle.main.infoDictionary
        return "\(i?["CFBundleShortVersionString"] as? String ?? "?") (\(i?["CFBundleVersion"] as? String ?? "?"))"
    }
    static var platform: String {
        var sys = utsname(); uname(&sys)
        let model = withUnsafeBytes(of: &sys.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        return "\(model) · \(os)"
    }
}

#if canImport(MetricKit)
extension CrashWatch: MXMetricManagerSubscriber {
    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for p in payloads {
            let f = Self.crashesDir.appendingPathComponent("metrickit-\(Int(p.timeStampEnd.timeIntervalSince1970))-\(UUID().uuidString.prefix(6)).json")
            try? p.jsonRepresentation().write(to: f)
            Self.pruneCrashes()
            let crashes = p.crashDiagnostics?.count ?? 0
            var hangs = 0, cpu = 0, disk = 0
            #if os(iOS)
            hangs = p.hangDiagnostics?.count ?? 0
            disk = p.diskWriteExceptionDiagnostics?.count ?? 0
            #endif
            cpu = p.cpuExceptionDiagnostics?.count ?? 0
            let reasons = (p.crashDiagnostics ?? []).map { d in
                [d.exceptionType.map { "exception \($0)" }, d.signal.map { "signal \($0)" }, d.terminationReason].compactMap { $0 }.joined(separator: " ")
            }
            AppLog.error("crash", "系统崩溃诊断：崩溃 \(crashes)、卡死 \(hangs)、CPU 异常 \(cpu)、磁盘写入异常 \(disk)" + (reasons.isEmpty ? "" : "；" + reasons.joined(separator: " | ")))
        }
    }
}
#endif

/// Everything needed to understand a problem, in one ZIP to send to the developer.
enum Diagnostics {
    /// What the export contains (shown before exporting).
    static let contents = "包含：问题日志（错误和警告的时间、模块、原因）、统计日志（只有数字）、崩溃诊断、设备型号和系统版本、App 版本、资料库的数量统计和开关设置、导入记录的数量统计。不包含：图片、视频、帖子正文、作者、标签名、文件名、Cookie 或同步凭据。"

    /// Writes the ZIP; returns the number of files in it.
    @discardableResult
    static func export(to url: URL) throws -> Int {
        var info: [String: Any] = [
            "app_version": CrashWatch.version, "platform": CrashWatch.platform,
            "exported_at": ISO8601DateFormatter().string(from: Date()),
            "last_run_abnormal": CrashWatch.shared.lastRunAbnormal,
            "prefs": [
                "auto_tag": ModelStore.shared.autoTag, "has_tagger": ModelStore.shared.activeTaggerId != nil,
                "has_embedder": ModelStore.shared.activeEmbedderId != nil, "triage_mode": LibraryPrefs.triageMode,
                "headphones_only": AudioPolicy.headphonesOnly,
            ],
        ]
        #if canImport(UIKit)
        info["memory_gb"] = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
        info["low_power"] = ProcessInfo.processInfo.isLowPowerModeEnabled
        #endif
        let data = try JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted, .sortedKeys])
        return try Core.exportDiagnostics(to: url, appInfo: String(decoding: data, as: UTF8.self))
    }
}
