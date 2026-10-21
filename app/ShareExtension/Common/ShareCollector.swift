import Foundation
import UniformTypeIdentifiers

/// Hands shared photos, videos and folders to the app: copies each file, one at a time, into a
/// new share folder in the app group (`Shares/Inbox/<id>.partial`, renamed to `<id>` when every
/// file is in), then tells the app. Nothing is decoded or read into memory — files are copied by
/// the file system (a clone on APFS) — so memory stays flat for hundreds of photos and videos.
/// HEIC, MOV, ProRAW and anything else are copied as they are; the app decides what it can import
/// and lists the rest in the import record.
final class ShareCollector: @unchecked Sendable {
    static let groupID = Bundle.main.object(forInfoDictionaryKey: "TwimShelfAppGroup") as? String ?? ""
    static let darwinName = "local.twitterlibrary.share-inbox"
    #if DEBUG && os(macOS)
    /// Debug builds share into their own folder, so a test share never reaches the real app.
    static let sharesFolder = "Shares-Debug"
    #else
    static let sharesFolder = "Shares"
    #endif

    struct Progress: Sendable { var done = 0; var total = 0; var files = 0; var current: String? = nil }
    struct Result: Sendable { var files = 0; var skipped: [String] = []; var bytes: Int64 = 0 }

    enum Failure: LocalizedError {
        case noContainer
        var errorDescription: String? { "无法访问 TwimShelf 的共享文件夹（App 组未授权）。请先打开一次 TwimShelf 再试。" }
    }

    private let lock = NSLock()
    private var _cancelled = false
    private var current: Foundation.Progress?
    var cancelled: Bool { lock.withLock { _cancelled } }
    private var partial: URL?
    /// The inbox (`Shares/Inbox` in the app group); tests pass their own folder.
    private let inboxOverride: URL?
    init(inbox: URL? = nil) { inboxOverride = inbox }

    func cancel() {
        lock.withLock { _cancelled = true; current?.cancel() }
    }

    /// Copies every image, movie or folder among `providers`. Returns what was handed over.
    func run(_ providers: [NSItemProvider], progress: @escaping @Sendable (Progress) -> Void) async throws -> Result {
        let fm = FileManager.default
        guard let shares = inboxOverride ?? fm.containerURL(forSecurityApplicationGroupIdentifier: Self.groupID)?.appendingPathComponent(Self.sharesFolder + "/Inbox", isDirectory: true) else { throw Failure.noContainer }
        let id = "share-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(8))"
        let dir = shares.appendingPathComponent(id + ".partial", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        partial = dir
        var p = Progress(total: providers.count)
        var r = Result()
        progress(p)
        for (i, provider) in providers.enumerated() {
            if cancelled { break }
            p.current = provider.suggestedName
            progress(p)
            do {
                if let n = try await copy(provider, into: dir) { r.files += n.files; r.bytes += n.bytes }
                else { r.skipped.append("第 \(i + 1) 项（\(provider.suggestedName ?? "未命名")）：不是图片、视频或文件夹") }
            } catch {
                if cancelled { break }
                r.skipped.append("第 \(i + 1) 项（\(provider.suggestedName ?? "未命名")）：\(error.localizedDescription)")
            }
            p.done = i + 1
            p.files = r.files
            progress(p)
        }
        if cancelled { discard(); return r }
        if r.files == 0 { discard(); return r }
        try fm.moveItem(at: dir, to: shares.appendingPathComponent(id, isDirectory: true))
        partial = nil
        if inboxOverride != nil { return r }
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName(Self.darwinName as CFString), nil, nil, true)
        return r
    }

    /// Removes a share that was cancelled or stopped half-way.
    func discard() {
        if let partial { try? FileManager.default.removeItem(at: partial) }
        partial = nil
    }

    /// The most faithful file type a provider offers: the original movie, else the original
    /// still (never a Live Photo bundle or a preview), else a folder, else a file URL.
    private func pick(_ p: NSItemProvider) -> (String, UTType)? {
        let ids = p.registeredTypeIdentifiers
        let types = ids.compactMap { id in UTType(id).map { (id, $0) } }.filter { !$0.0.contains("live-photo") && !$0.0.contains("private") }
        if let m = types.first(where: { $0.1.conforms(to: .movie) }) { return m }
        // Photos also offers a converted JPEG: keep the original HEIC / HEIF / AVIF when there is one
        let originals: [UTType] = [.heic, .heif, UTType("public.avif")].compactMap { $0 }
        if let o = types.first(where: { t in originals.contains { t.1.conforms(to: $0) } }) { return o }
        if let i = types.first(where: { $0.1.conforms(to: .image) }) { return i }
        if let f = types.first(where: { $0.1.conforms(to: .folder) }) { return f }
        if let u = types.first(where: { $0.1.conforms(to: .fileURL) }) { return u }
        return nil
    }

    private struct Copied { var files: Int; var bytes: Int64 }

    private func copy(_ provider: NSItemProvider, into dir: URL) async throws -> Copied? {
        guard let (id, type) = pick(provider) else { return nil }
        if type.conforms(to: .fileURL) {
            // Finder / Files hand over a file URL: copy that file (or folder) if it is media
            let url: URL = try await withCheckedThrowingContinuation { c in
                _ = provider.loadItem(forTypeIdentifier: id, options: nil) { item, error in
                    if let u = item as? URL { c.resume(returning: u) }
                    else if let d = item as? Data, let u = URL(dataRepresentation: d, relativeTo: nil) { c.resume(returning: u) }
                    else { c.resume(throwing: error ?? CocoaError(.fileReadUnknown)) }
                }
            }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let t = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
            guard let t, t.conforms(to: .image) || t.conforms(to: .movie) || t.conforms(to: .folder) else { return nil }
            return try place(url, name: url.lastPathComponent, into: dir)
        }
        return try await withCheckedThrowingContinuation { c in
            let prog = provider.loadFileRepresentation(forTypeIdentifier: id) { url, error in
                // the file exists only until this returns: copy it now
                guard let url else { c.resume(throwing: error ?? CocoaError(.fileReadUnknown)); return }
                var name = provider.suggestedName ?? url.deletingPathExtension().lastPathComponent
                let ext = url.pathExtension.isEmpty ? (type.preferredFilenameExtension ?? "") : url.pathExtension
                if !ext.isEmpty, (name as NSString).pathExtension.lowercased() != ext.lowercased() { name += "." + ext }
                do { c.resume(returning: try self.place(url, name: name, into: dir)) } catch { c.resume(throwing: error) }
            }
            lock.withLock { current = prog }
        }
    }

    /// Copies a file or folder under a free name (clone on APFS; never read into memory).
    private func place(_ src: URL, name: String, into dir: URL) throws -> Copied {
        let fm = FileManager.default
        let clean = name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        var dst = dir.appendingPathComponent(clean.isEmpty ? "未命名" : clean)
        var k = 2
        while fm.fileExists(atPath: dst.path) {
            let base = (clean as NSString).deletingPathExtension, ext = (clean as NSString).pathExtension
            dst = dir.appendingPathComponent(ext.isEmpty ? "\(base) (\(k))" : "\(base) (\(k)).\(ext)")
            k += 1
        }
        try fm.copyItem(at: src, to: dst)
        var files = 0
        var bytes: Int64 = 0
        if let e = fm.enumerator(at: dst, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]), (try? dst.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            for case let u as URL in e {
                let v = try? u.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                if v?.isRegularFile == true { files += 1; bytes += Int64(v?.fileSize ?? 0) }
            }
        } else {
            files = 1
            bytes = Int64((try? dst.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        return Copied(files: files, bytes: bytes)
    }

    /// Attachments of every input item.
    static func providers(_ context: NSExtensionContext?) -> [NSItemProvider] {
        (context?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
    }
}
