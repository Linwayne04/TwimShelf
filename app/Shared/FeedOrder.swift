import Foundation

/// Random feed order drawn from the system's cryptographic random number generator
/// (`SystemRandomNumberGenerator`, i.e. arc4random). Each media gets a random rank the first
/// time it is seen and keeps it until the next reshuffle, so the order stays put while you tag,
/// delete or sync, and media that arrive later land at random positions.
struct FeedOrder {
    private var rank: [String: UInt64] = [:]
    private var rng = SystemRandomNumberGenerator()

    mutating func reshuffle() { rank.removeAll(keepingCapacity: true) }

    /// Posts, each with exactly one random rank (its own draw, never "the best of its media":
    /// that favoured posts with many media near the top), each post's media in their order.
    /// Nothing about the content (text, ids, hashes, dates) enters the order.
    mutating func posts(_ items: [FeedItem]) -> [[FeedItem]] {
        var by: [String: [FeedItem]] = [:]
        for it in items { by[it.postId, default: []].append(it) }
        var keyed: [(UInt64, [FeedItem])] = []
        keyed.reserveCapacity(by.count)
        for (post, media) in by {
            let k = "post:" + post
            let r: UInt64
            if let v = rank[k] { r = v } else { r = rng.next(); rank[k] = r }
            keyed.append((r, media.sorted { $0.ordinal < $1.ordinal }))
        }
        keyed.sort { $0.0 < $1.0 }
        return keyed.map(\.1)
    }

    mutating func apply(_ items: [FeedItem]) -> [FeedItem] {
        var keyed: [(UInt64, FeedItem)] = []
        keyed.reserveCapacity(items.count)
        for it in items {
            let r: UInt64
            if let v = rank[it.mediaId] { r = v } else { r = rng.next(); rank[it.mediaId] = r }
            keyed.append((r, it))
        }
        keyed.sort { $0.0 < $1.0 }
        return keyed.map(\.1)
    }
}

/// Library-wide view preferences shared by iOS and macOS.
enum LibraryPrefs {
    static let changed = Notification.Name("LibraryPrefsChanged")

    /// Only media whose file failed verification.
    static var badOnly: Bool {
        get { UserDefaults.standard.bool(forKey: "filter.bad") }
        set { UserDefaults.standard.set(newValue, forKey: "filter.bad"); NotificationCenter.default.post(name: changed, object: nil) }
    }

    /// Triage mode: the home screen shows one post at a time to keep / delete / file.
    static var triageMode: Bool {
        get { UserDefaults.standard.bool(forKey: "triage.mode") }
        set { UserDefaults.standard.set(newValue, forKey: "triage.mode"); NotificationCenter.default.post(name: changed, object: nil) }
    }

    /// Open landscape videos in landscape automatically (iPhone).
    /// Home background (gradient + halftone that follows the device's tilt). On by default.
    static var backdrop: Bool {
        get { UserDefaults.standard.object(forKey: "home.backdrop") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "home.backdrop"); NotificationCenter.default.post(name: changed, object: nil) }
    }

    /// 视频禁用手势: the player leaves out the drags for seeking, volume and brightness (long press for
    /// speed and double tap for pause stay). Swiping sideways then turns to the next photo or video
    /// of the list, and dragging down closes the player, as in the photo viewer.
    static var playerGesturesOff: Bool {
        get { UserDefaults.standard.bool(forKey: "player.noGestures") }
        set { UserDefaults.standard.set(newValue, forKey: "player.noGestures") }
    }

    static var autoLandscape: Bool {
        get { UserDefaults.standard.bool(forKey: "player.autoLandscape") }
        set { UserDefaults.standard.set(newValue, forKey: "player.autoLandscape") }
    }

    /// Semantic / substring matching for search terms (Settings → 搜索). On by default, but only
    /// in effect (and only switchable) once a semantic search model is installed and chosen.
    static var fuzzySearch: Bool {
        get { semanticSearchAvailable && (UserDefaults.standard.object(forKey: "search.fuzzy") as? Bool ?? true) }
        set { UserDefaults.standard.set(newValue, forKey: "search.fuzzy"); NotificationCenter.default.post(name: changed, object: nil) }
    }

    /// A semantic search (embedding) model is installed and selected.
    static var semanticSearchAvailable: Bool { ModelStore.shared.activeEmbedder != nil }
    static let semanticSearchNeedsModel = "语义模糊搜索需要语义搜索模型：先在「AI 模型」中下载并选择一个。"

    static let keepChoices: [(days: Int, title: String)] = [(7, "7 天"), (30, "30 天"), (90, "90 天"), (365, "1 年"), (0, "永不")]
    static func keepTitle(_ d: Int) -> String { keepChoices.first { $0.days == d }?.title ?? "\(d) 天" }
}

/// The folders offered under the card in 整理 (Mac and iOS), in the spirit of photo-sorting
/// apps' album bar: the ones you filed into most recently first, then the rest by name. The
/// order is taken once when 整理 opens and kept while you work (new folders go at the end), so a
/// folder never moves under the pointer or the finger between two posts.
enum TriageFolders {
    private static let key = "triage.recentFolders"
    private static var recent: [String] { UserDefaults.standard.stringArray(forKey: key) ?? [] }

    /// Remembers a folder that a post was just filed into (this device only).
    static func used(_ name: String) {
        var r = recent.filter { $0 != name }
        r.insert(name, at: 0)
        UserDefaults.standard.set(Array(r.prefix(40)), forKey: key)
    }

    /// Folders that still exist: recently used first, then by name.
    static func ordered() -> [String] {
        let all = Core.folders().map(\.name)
        let live = Set(all)
        let rec = recent.filter { live.contains($0) }
        let taken = Set(rec)
        return rec + all.filter { !taken.contains($0) }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Keeps a session's order: names that are gone drop out, new ones go at the end.
    static func refreshed(_ current: [String]) -> [String] {
        let now = ordered()
        let live = Set(now)
        let kept = current.filter { live.contains($0) }
        let known = Set(kept)
        return kept + now.filter { !known.contains($0) }
    }
}
