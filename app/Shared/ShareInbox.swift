import Foundation

/// Files shared into TwimShelf (from Photos, Files or Finder) wait in the app group's
/// container. The share extension only copies files — it never decodes an image, so its memory
/// stays flat however many photos and videos are shared — into `Shares/Inbox/<id>.partial`, and
/// renames the folder to `<id>` once every file is in. The app imports complete folders as loose
/// media (one import at a time, like every other import) and removes what it imported; problem
/// files move to `Shares/Kept/<id>`, listed in that import's record and deleted with it.
/// An interrupted import leaves the folder in the inbox: the next run imports it again, and what
/// was already imported counts as a duplicate.
enum ShareInbox {
    static let groupID = Bundle.main.object(forInfoDictionaryKey: "TwimShelfAppGroup") as? String ?? ""
    /// Posted (Darwin notification) by the extension when a share is complete.
    static let darwinName = "local.twitterlibrary.share-inbox"
    /// Posted (NotificationCenter) after the app imported shares; object = [ImportReport].
    static let imported = Notification.Name("ShareInbox.imported")
    /// Posted when a share could not be imported; object = message. The share stays in the
    /// inbox and is tried again the next time the app becomes active.
    static let failed = Notification.Name("ShareInbox.failed")

    static var shares: URL? {
        #if DEBUG
        // test runs against a synthetic library never touch real shares
        if let d = ProcessInfo.processInfo.environment["TL_LIBRARY_DIR"] { return URL(fileURLWithPath: d).appendingPathComponent(".shares", isDirectory: true) }
        #endif
        #if DEBUG && os(macOS)
        let folder = "Shares-Debug"   // matches the debug extension
        #else
        let folder = "Shares"
        #endif
        guard !groupID.isEmpty else { return nil }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID)?.appendingPathComponent(folder, isDirectory: true)
    }
    static var inbox: URL? { shares?.appendingPathComponent("Inbox", isDirectory: true) }
    static var kept: URL? { shares?.appendingPathComponent("Kept", isDirectory: true) }

    /// Folders holding the app's own copies of import sources (deleted together with a record).
    static var ownedRoots: [URL] {
        var v: [URL] = []
        if let s = shares { v.append(s) }
        #if os(iOS)
        v.append(FileManager.default.temporaryDirectory)   // files picked in Files are copied here
        if let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first { v.append(docs.appendingPathComponent("Inbox")) }
        #endif
        return v
    }

    /// Complete shares, oldest first. Partial ones older than a day (an extension that was
    /// stopped half-way) are removed.
    static func pending() -> [URL] {
        guard let inbox else { return [] }
        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(at: inbox, includingPropertiesForKeys: [.creationDateKey, .isDirectoryKey])) ?? []
        var ready: [(URL, Date)] = []
        for u in items {
            let v = try? u.resourceValues(forKeys: [.creationDateKey, .isDirectoryKey])
            guard v?.isDirectory == true else { continue }
            let created = v?.creationDate ?? .distantPast
            if u.pathExtension == "partial" {
                if created < Date().addingTimeInterval(-86_400) { try? fm.removeItem(at: u) }
                continue
            }
            ready.append((u, created))
        }
        return ready.sorted { $0.1 < $1.1 }.map(\.0)
    }

    private static var running = false

    /// Imports every complete share off the main thread, then posts `imported` with the reports.
    static func importPending() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !running, !pending().isEmpty else { return }
        running = true
        DispatchQueue.global(qos: .userInitiated).async {
            var reports: [ImportReport] = []
            var failure: String?
            // repeat: a share completing while we import is picked up in the same run
            while let next = pending().first {
                let keep = kept?.appendingPathComponent(next.lastPathComponent, isDirectory: true)
                do { reports.append(try Core.importLooseDir(next, consume: true, keepTo: keep)) }
                catch {
                    // never set a share aside without a record: it stays in the inbox, the reason
                    // is shown, and it is tried again next time (no retry loop within this run)
                    failure = "\(pending().count) 个分享暂时没能导入（\(error.localizedDescription)），下次打开 App 时会再试。文件仍然保存着。"
                    break
                }
            }
            DispatchQueue.main.async {
                running = false
                if let failure { NotificationCenter.default.post(name: ShareInbox.failed, object: failure) }
                guard !reports.isEmpty else { return }
                NotificationCenter.default.post(name: .libraryChanged, object: nil)
                NotificationCenter.default.post(name: imported, object: reports)
            }
        }
    }

    /// "清除所有数据": shares waiting to be imported and files kept from earlier shares.
    static func wipe() {
        guard let shares else { return }
        let fm = FileManager.default
        for sub in ["Inbox", "Kept"] { try? fm.removeItem(at: shares.appendingPathComponent(sub, isDirectory: true)) }
    }

    /// One-line summary for a toast.
    static func summary(_ reports: [ImportReport]) -> String {
        let added = reports.reduce(0) { $0 + ($1.newMedia ?? $1.media) }
        let dup = reports.reduce(0) { $0 + ($1.duplicateMedia ?? 0) }
        let problems = reports.reduce(0) { $0 + $1.skipped.count }
        var t = "已从分享导入 \(added) 个散装媒体"
        if dup > 0 { t += "，\(dup) 个已在资料库里" }
        if problems > 0 { t += "，\(problems) 个没有导入（见「导入记录」）" }
        return t
    }

    /// Calls `handler` on the main queue whenever the extension finishes a share.
    static func observe(_ handler: @escaping () -> Void) {
        observer = handler
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterAddObserver(center, nil, { _, _, _, _, _ in
            DispatchQueue.main.async { ShareInbox.observer?() }
        }, darwinName as CFString, nil, .deliverImmediately)
    }
    nonisolated(unsafe) private static var observer: (() -> Void)?
}
