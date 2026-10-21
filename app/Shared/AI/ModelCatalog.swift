import Foundation

/// Curated on-device models (MLX, 4-bit, all ≤ 14B parameters). Taggers are vision-language
/// models used only to emit tags; the embedder is used only for semantic tag matching.
struct CatalogModel: Hashable {
    enum Role { case tagger, embedder }
    let repo: String
    let displayName: String
    let role: Role
    let bytes: UInt64
    let note: String
    let uncensored: Bool
}

enum ModelCatalog {
    static let all: [CatalogModel] = [
        .init(repo: "EZCon/Huihui-Qwen3-VL-2B-Instruct-abliterated-4bit-mlx", displayName: "Qwen3-VL 2B 无审查",
              role: .tagger, bytes: 1_800_000_000, note: "适合 iPhone · 约 3 GB 内存", uncensored: true),
        .init(repo: "mlx-community/Qwen2.5-VL-3B-Instruct-abliterated-4bit", displayName: "Qwen2.5-VL 3B 无审查",
              role: .tagger, bytes: 2_330_000_000, note: "适合 iPhone Pro · 约 4 GB 内存", uncensored: true),
        .init(repo: "EZCon/Huihui-Qwen3-VL-4B-Instruct-abliterated-4bit-mlx", displayName: "Qwen3-VL 4B 无审查",
              role: .tagger, bytes: 3_110_000_000, note: "适合 iPad / iPhone Pro Max · 约 5 GB 内存", uncensored: true),
        .init(repo: "alexgusevski/Huihui-Qwen3-VL-8B-Instruct-abliterated-q4-mlx", displayName: "Qwen3-VL 8B 无审查",
              role: .tagger, bytes: 5_770_000_000, note: "适合 M 系列 iPad 与 Mac · 约 8 GB 内存", uncensored: true),
        .init(repo: "mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ", displayName: "Qwen3 Embedding 0.6B",
              role: .embedder, bytes: 350_000_000, note: "语义搜索 · 多语言（中文效果好）", uncensored: false),
    ]
    static var taggers: [CatalogModel] { all.filter { $0.role == .tagger } }
    static var embedders: [CatalogModel] { all.filter { $0.role == .embedder } }
    static func find(_ repo: String) -> CatalogModel? { all.first { $0.repo == repo } }

    /// A sensible default for this device's memory.
    static var recommendedTagger: CatalogModel {
        let gb = Double(ProcessInfo.processInfo.physicalMemory) / 1e9
        let pick = gb >= 15 ? 3 : gb >= 7.5 ? 2 : 0
        return taggers[pick]
    }
}

/// Installed models and which ones are the defaults. Several models can be installed at once;
/// the defaults are per-device settings (never synced). Changing a default does not re-tag anything.
final class ModelStore {
    static let shared = ModelStore()
    static let changed = Notification.Name("ModelStoreChanged")

    /// Model folders live next to (not inside) the library so a reset of the library or a test
    /// library never forces a re-download.
    static var modelsDirectory: URL {
        #if DEBUG
        if let d = ProcessInfo.processInfo.environment["TL_MODELS_DIR"] { return URL(fileURLWithPath: d, isDirectory: true) }
        #endif
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        #if DEBUG && os(macOS)
        // the debug build never touches the installed app's models (TL_MODELS_DIR can point at a copy)
        return base.appendingPathComponent("TwimShelf-Models-Debug", isDirectory: true)
        #else
        return base.appendingPathComponent("TwimShelf-Models", isDirectory: true)
        #endif
    }

    /// Points the core at the models folder, moving models from the old in-library location.
    func configure() {
        let fm = FileManager.default
        let dst = Self.modelsDirectory
        try? fm.createDirectory(at: dst, withIntermediateDirectories: true)
        let old = Core.libraryDirectory.appendingPathComponent("models", isDirectory: true)
        if let items = try? fm.contentsOfDirectory(at: old, includingPropertiesForKeys: nil) {
            for it in items where !fm.fileExists(atPath: dst.appendingPathComponent(it.lastPathComponent).path) {
                do { try fm.moveItem(at: it, to: dst.appendingPathComponent(it.lastPathComponent)) }
                catch { AppLog.warn("models", "无法移动模型文件夹（\(error.localizedDescription)），保留在原处") }
            }
            // the old folder goes only once it is empty: a model that could not be moved (or one
            // with the same name already at the new place) is kept, never deleted unseen
            if (try? fm.contentsOfDirectory(atPath: old.path))?.isEmpty == true { try? fm.removeItem(at: old) }
        }
        Core.setModelsDirectory(dst)
        Self.excludeFromBackup(dst)
        Self.excludeFromBackup(Core.libraryDirectory)
        reload()
    }

    /// Media and models must not go into iCloud backups (they can be tens of GB and the app
    /// syncs on the LAN only). The flag on a directory covers everything inside it.
    static func excludeFromBackup(_ url: URL) {
        var u = url
        var v = URLResourceValues()
        v.isExcludedFromBackup = true
        try? u.setResourceValues(v)
    }

    private(set) var installed: [Core.ModelInfo] = []

    func reload() {
        installed = Core.installedModels()
        adoptInstalled()
    }

    var taggers: [Core.ModelInfo] { installed.filter(\.vision) }
    /// Every model that can tag: built-in vision models, then external ones (no difference in
    /// use: each can be the default and appears in every re-tag menu).
    var taggerIds: [String] { taggers.map(\.id) + ExternalModels.all.map(\.id) }
    var embedders: [Core.ModelInfo] { installed.filter { !$0.vision } }

    var activeTaggerId: String? {
        get { UserDefaults.standard.string(forKey: "ai.tagger.id") }
        set { UserDefaults.standard.set(newValue, forKey: "ai.tagger.id"); notify() }
    }
    var activeEmbedderId: String? {
        get { UserDefaults.standard.string(forKey: "ai.embedder.id") }
        set { UserDefaults.standard.set(newValue, forKey: "ai.embedder.id"); notify() }
    }
    var autoTag: Bool {
        get { UserDefaults.standard.object(forKey: "ai.autotag") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "ai.autotag"); notify() }
    }

    func info(_ id: String?) -> Core.ModelInfo? { id.flatMap { i in installed.first { $0.id == i } } }
    var activeTagger: Core.ModelInfo? { info(activeTaggerId) }
    var activeEmbedder: Core.ModelInfo? { info(activeEmbedderId) }

    /// Friendly name for a model id (catalog name when known, else the folder name).
    func displayName(_ id: String) -> String {
        if let e = ExternalModels.find(id) { return e.title + "（\(e.kindLabel)）" }
        let repo = installed.first { $0.id == id }?.repo ?? id.replacingOccurrences(of: "--", with: "/")
        return ModelCatalog.find(repo)?.displayName ?? id.components(separatedBy: "--").last ?? id
    }

    func isInstalled(repo: String) -> Bool { installed.contains { $0.repo == repo } }
    func id(forRepo repo: String) -> String? { installed.first { $0.repo == repo }?.id }

    /// Keeps defaults valid and picks one when none is set; never triggers re-tagging.
    func adoptInstalled() {
        if activeTaggerId.map({ id in !taggerIds.contains(id) }) ?? true {
            UserDefaults.standard.set(taggers.first(where: { $0.repo == ModelCatalog.recommendedTagger.repo })?.id ?? taggers.first?.id, forKey: "ai.tagger.id")
        }
        if activeEmbedderId.map({ id in !embedders.contains { $0.id == id } }) ?? true {
            UserDefaults.standard.set(embedders.first?.id, forKey: "ai.embedder.id")
        }
        notify()
    }

    func wipe() {
        ["ai.tagger.id", "ai.embedder.id", "ai.autotag"].forEach { UserDefaults.standard.removeObject(forKey: $0) }
        installed = []
        Task { await AIEngine.shared.unloadAll() }
    }

    private func notify() { DispatchQueue.main.async { NotificationCenter.default.post(name: Self.changed, object: nil) } }
}
