import Foundation
import SwiftUI

/// One part of a post a search term can match.
enum SearchField: String, CaseIterable { case tags, text, author }

/// A condition word of the token style.
enum SearchKeyword: Hashable {
    case field(SearchField)
    case scope(SearchScope)
    /// Only "最近添加" posts.
    case recent
    /// Only media imported from outside (散装: loose ZIPs and the share extension).
    case external
    /// "文件夹": the next word is a folder's name (until then a pending capsule).
    case folder
    /// "视频" / "照片": only that kind of media.
    case media(MediaKind)

    struct Info { let word: String; let aliases: [String]; let symbol: String; let hint: String }

    static let all: [SearchKeyword] = [.field(.tags), .field(.text), .field(.author), .scope(.mine), .scope(.ai), .scope(.common), .scope(.both), .media(.video), .media(.photo), .folder, .recent, .external]

    var info: Info {
        switch self {
        case .field(.tags): Info(word: "标签", aliases: [], symbol: "tag", hint: "在标签里找")
        case .field(.text): Info(word: "贴文", aliases: ["正文", "帖子"], symbol: "text.quote", hint: "在帖子正文里找")
        case .field(.author): Info(word: "用户", aliases: ["作者"], symbol: "person", hint: "在作者名和 @用户名 里找")
        case .scope(.mine): Info(word: "我的", aliases: [], symbol: "person.crop.circle", hint: "只看我加的标签")
        case .scope(.ai): Info(word: "AI", aliases: ["ai"], symbol: "sparkles", hint: "只看 AI 加的标签")
        case .scope(.common): Info(word: "共同", aliases: [], symbol: "checkmark.seal", hint: "只看我和 AI 都加了的标签")
        case .scope(.both): Info(word: "全部", aliases: [], symbol: "circle.grid.2x2", hint: "我的和 AI 的标签都看（默认）")
        case .media(.video): Info(word: "视频", aliases: ["影片"], symbol: "video", hint: "只看视频")
        case .media(.photo): Info(word: "照片", aliases: ["图片"], symbol: "photo", hint: "只看照片")
        case .folder: Info(word: "文件夹", aliases: [], symbol: "folder", hint: "只看一个文件夹：接着输入文件夹名")
        case .recent: Info(word: "最近", aliases: ["最近添加"], symbol: "clock.badge.checkmark", hint: "只看最近添加的帖子")
        case .external: Info(word: "外部导入", aliases: ["散装", "导入"], symbol: "square.and.arrow.down", hint: "只看散装媒体：导入的 ZIP 和从分享来的")
        }
    }

    /// The keyword a typed word stands for (exact word or alias), if any.
    static func from(_ word: String) -> SearchKeyword? {
        let w = word.trimmingCharacters(in: .whitespaces)
        return all.first { $0.info.word == w || $0.info.aliases.contains(w) || $0.info.word.lowercased() == w.lowercased() }
    }

    /// Stored in a token's representedObject.
    var key: String {
        switch self {
        case .field(let f): "f:" + f.rawValue
        case .scope(let s): "s:" + s.rawValue
        case .recent: "r:recent"
        case .external: "x:external"
        case .folder: TokenQuery.pendingFolder
        case .media(let k): "k:" + k.rawValue
        }
    }
}

/// What the capsules in a token search field ask for. Conditions apply to the whole search;
/// every text capsule must match (as with several search terms).
struct TokenQuery: Equatable {
    var fields: Set<SearchField> = []
    var scopes: Set<SearchScope> = []
    var terms: [String] = []
    var folder: String?
    var recent = false
    var external = false
    /// 视频 / 照片 capsules: one of them narrows to that kind; both (or none) mean no limit.
    var kinds: Set<MediaKind> = []
    var kind: MediaKind? { kinds.count == 1 ? kinds.first : nil }

    static let pendingFolder = "p:folder"
    static func termKey(_ t: String) -> String { "t:" + t }
    static func folderKey(_ name: String) -> String { "d:" + name }

    /// Where the words are looked for. No field capsule = everywhere (tags, post text, authors);
    /// a field capsule (标签 / 贴文 / 用户) limits it to those. 我的 / AI / 共同 are about who
    /// added a tag, so with only those it is tags. 文件夹 / 最近 / 外部导入 only narrow which
    /// posts are searched (as do 视频 / 照片, which narrow the kind of media) and keep the default.
    var searchFields: SearchFields {
        if fields.isEmpty {
            return scopes.subtracting([.both]).isEmpty ? SearchFields(tags: true, text: true, author: true) : SearchFields()
        }
        return SearchFields(tags: fields.contains(.tags), text: fields.contains(.text), author: fields.contains(.author))
    }

    /// "共同" wins (the narrowest); "我的" with "AI" is either; none = either.
    var scope: SearchScope {
        if scopes.contains(.common) { return .common }
        if scopes.contains(.mine) && scopes.contains(.ai) { return .both }
        if scopes.contains(.mine) { return .mine }
        if scopes.contains(.ai) { return .ai }
        return .both
    }

    /// Reads the capsules of a field.
    init(keys: [String]) {
        for k in keys {
            if k.hasPrefix("f:"), let f = SearchField(rawValue: String(k.dropFirst(2))) { fields.insert(f) }
            else if k.hasPrefix("s:"), let s = SearchScope(rawValue: String(k.dropFirst(2))) { scopes.insert(s) }
            else if k.hasPrefix("t:") { let t = String(k.dropFirst(2)).lowercased(); if !terms.contains(t) { terms.append(t) } }
            else if k.hasPrefix("d:") { folder = String(k.dropFirst(2)) }
            else if k == "r:recent" { recent = true }
            else if k == "x:external" { external = true }
            else if k.hasPrefix("k:"), let m = MediaKind(rawValue: String(k.dropFirst(2))) { kinds.insert(m) }
        }
    }
    init() {}

    /// Splits typed text at spaces (half or full width): every complete word becomes a capsule
    /// key; the unfinished rest stays as text. A word right after "文件夹" is the folder's name.
    static func split(_ text: String) -> (keys: [String], rest: String) {
        let seps: Set<Character> = [" ", "\u{3000}", "\n", "\t"]
        guard let last = text.lastIndex(where: { seps.contains($0) }) else { return ([], text) }
        let done = text[..<last].split(whereSeparator: { seps.contains($0) }).map(String.init)
        let rest = String(text[text.index(after: last)...])
        var keys: [String] = []
        for w in done {
            if keys.last == pendingFolder { keys[keys.count - 1] = folderKey(w); continue }
            keys.append(SearchKeyword.from(w)?.key ?? termKey(w))
        }
        return (keys, rest)
    }
}

/// Recent search terms (this device only; cleared with the library).
enum SearchHistory {
    private static let key = "search.history"
    static var items: [String] { UserDefaults.standard.stringArray(forKey: key) ?? [] }
    static func add(_ t: String) {
        let t = t.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        UserDefaults.standard.set(Array(([t] + items.filter { $0 != t }).prefix(12)), forKey: key)
    }
    static func clear() { UserDefaults.standard.removeObject(forKey: key) }
}

/// Where the searched words occur in a shown text (case- and width-insensitive), so every match
/// can be highlighted in the results.
enum SearchHighlight {
    static func ranges(of terms: [String], in text: String) -> [NSRange] {
        let ns = text as NSString
        var out: [NSRange] = []
        for t in Set(terms.map { $0.trimmingCharacters(in: .whitespaces) }) where !t.isEmpty {
            var from = 0
            while from < ns.length {
                let r = ns.range(of: t, options: [.caseInsensitive, .widthInsensitive, .diacriticInsensitive], range: NSRange(location: from, length: ns.length - from))
                if r.location == NSNotFound { break }
                out.append(r)
                from = r.location + max(r.length, 1)
            }
        }
        return out
    }

    /// Marks every match in `s` with the given attributes.
    static func apply(_ terms: [String], to s: NSMutableAttributedString, _ attrs: [NSAttributedString.Key: Any]) {
        guard !terms.isEmpty else { return }
        for r in ranges(of: terms, in: s.string) { s.addAttributes(attrs, range: r) }
    }
}

extension Array where Element == TagCount {
    /// Tags someone added by hand first, then tags only AI gave; each group by popularity.
    var userFirst: [TagCount] {
        let mine = filter { $0.user > 0 }, ai = filter { $0.user == 0 }
        return mine.sorted { $0.count > $1.count } + ai.sorted { $0.count > $1.count }
    }
}


// MARK: - Exporting a search result

/// The two switches of the export popover, remembered between exports.
enum SearchExportPrefs {
    static var tags: Bool {
        get { UserDefaults.standard.object(forKey: "export.tags") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "export.tags") }
    }
    static var folders: Bool {
        get { UserDefaults.standard.object(forKey: "export.folders") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "export.folders") }
    }
    /// A plain zip of the media only: no tags, no folders (those switches are off and locked then).
    static var mediaOnly: Bool {
        get { UserDefaults.standard.bool(forKey: "export.mediaOnly") }
        set { UserDefaults.standard.set(newValue, forKey: "export.mediaOnly") }
    }
    static var options: ExportOptions {
        mediaOnly ? ExportOptions(tags: false, folders: false, mediaOnly: true) : ExportOptions(tags: tags, folders: folders, mediaOnly: false)
    }

    /// The file name of an export of a search, with its extension: "TwimShelf 搜索结果
    /// 2026-10-21 1530.tlpack" (".zip" for a plain media export).
    static func fileName(now: Date = Date()) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HHmm"
        return "TwimShelf 搜索结果 \(f.string(from: now))." + (mediaOnly ? "zip" : "tlpack")
    }
}

/// What the export button next to the search field opens (a small popover on Mac and iPhone):
/// the media of the current search result are exported, and the only choices are whether tags
/// and folder memberships come along.
struct SearchExportView: View {
    let count: Int
    let onExport: () -> Void
    @State private var tags = SearchExportPrefs.tags
    @State private var folders = SearchExportPrefs.folders
    @State private var mediaOnly = SearchExportPrefs.mediaOnly

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text("导出搜索结果").font(.headline)
                Text(count == 0 ? "当前没有搜索结果" : "\(count) 个媒体" + (mediaOnly ? "" : "，连同帖子正文、作者和链接")).font(.footnote).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 14) {
                // with 以纯媒体导出 on, these two show as off and cannot be changed; what they were
                // before comes back when it is turned off
                row("包含标签信息", "我的标签、AI 标签，以及打标签的模型",
                    Binding(get: { tags && !mediaOnly }, set: { tags = $0; SearchExportPrefs.tags = $0 }), locked: mediaOnly)
                row("包含所在文件夹信息", "每个媒体所在的文件夹",
                    Binding(get: { folders && !mediaOnly }, set: { folders = $0; SearchExportPrefs.folders = $0 }), locked: mediaOnly)
                Divider()
                row("以纯媒体导出", "只有图片和视频的 ZIP，每个帖子一个文件夹，没有本应用也能打开。不含标签、文件夹和正文，不能导回本应用。",
                    $mediaOnly, locked: false)
                    .onChange(of: mediaOnly) { _, v in SearchExportPrefs.mediaOnly = v }
            }
            Button(action: onExport) { Text("导出").frame(maxWidth: .infinity) }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(count == 0)
                .accessibilityIdentifier("searchExportGo")
        }
        .padding(20)
        .frame(width: 340)
    }

    /// A title and a note on the left, the switch at the trailing edge.
    private func row(_ title: String, _ detail: String, _ on: Binding<Bool>, locked: Bool) -> some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: on).labelsHidden().toggleStyle(.switch).disabled(locked)
                .accessibilityLabel(title)
        }
        .opacity(locked ? 0.55 : 1)
    }
}
