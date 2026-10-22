import Foundation
import CoreImage
import ImageIO
import AVFoundation
import MLX
import MLXLMCommon
import MLXVLM
import MLXEmbedders
#if os(iOS)
import os
#endif

/// Runs the on-device MLX models. The vision model only produces tags and the embedder only
/// produces vectors for tag matching; neither output is ever shown as free text.
actor AIEngine {
    static let shared = AIEngine()

    enum EngineError: LocalizedError {
        case simulator, notInstalled(String), notEnoughMemory(need: UInt64, available: UInt64)
        var errorDescription: String? {
            switch self {
            case .simulator: "iOS 模拟器不支持 Metal 推理，请在真机或 Mac 上运行。"
            case .notInstalled(let r): "模型未安装：\(r)"
            case .notEnoughMemory(let need, let avail):
                "这台设备现在的可用内存不够运行这个模型（需要约 \(ByteCountFormatter.string(fromByteCount: Int64(need), countStyle: .memory))，可用 \(ByteCountFormatter.string(fromByteCount: Int64(avail), countStyle: .memory))）。没有加载模型；同一账户里的其他设备会继续标记，结果会同步过来。"
            }
        }
    }

    /// Whether this model can tag here: external ones always; built-in ones need Metal.
    nonisolated static func canRun(_ model: String) -> Bool { ExternalModels.isExternal(model) || isSupported }

    /// Memory a built-in model needs when loaded (weights plus working memory), and whether it
    /// fits in what this process may still use. iOS ends an app that goes over its limit without
    /// any warning that arrives in time (a model loads in a few seconds), so the check comes
    /// before loading, never after. On the Mac there is no such limit.
    nonisolated static func memoryCheck(_ model: String) -> EngineError? {
        #if os(iOS)
        guard !ExternalModels.isExternal(model), let info = Core.installedModels().first(where: { $0.id == model }) else { return nil }
        let need = info.bytes + info.bytes / 4 + 500_000_000
        let available = UInt64(os_proc_available_memory())
        return available < need ? .notEnoughMemory(need: need, available: available) : nil
        #else
        return nil
        #endif
    }

    static var isSupported: Bool {
        #if targetEnvironment(simulator)
        false
        #else
        true
        #endif
    }

    private var tagger: (repo: String, container: ModelContainer)?
    private var embedder: (repo: String, container: EmbedderModelContainer)?
    private var idleUnload: Task<Void, Never>?

    // MARK: One GPU job at a time
    //
    // An actor is re-entrant: while one inference awaits, another call (a search embedding, a
    // single re-tag, or unloading on a memory warning) could enter and drive MLX / Metal from a
    // second thread at the same time — that crashed in Metal's command-buffer code. Every MLX
    // operation, unloading included, therefore runs through this first-come-first-served gate.
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private func acquire() async {
        idleUnload?.cancel()
        idleUnload = nil
        if !busy { busy = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }
    private func release() {
        if waiters.isEmpty {
            busy = false
            guard tagger != nil || embedder != nil else { return }
            // Keep weights between images in a batch, but not for the rest of the app's life.
            idleUnload = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: 30_000_000_000) }
                catch { return }
                await self?.unloadIfIdle()
            }
        } else { waiters.removeFirst().resume() }
    }

    private func unloadIfIdle() {
        guard !Task.isCancelled, !busy, waiters.isEmpty else { return }
        idleUnload = nil
        releaseModels()
    }

    private func releaseModels() {
        let before = MLX.Memory.snapshot()
        tagger = nil
        embedder = nil
        MLX.GPU.clearCache()
        let after = MLX.Memory.snapshot()
        AppLog.info("memory", "AI unloaded: active \(before.activeMemory) -> \(after.activeMemory), cache \(before.cacheMemory) -> \(after.cacheMemory) bytes")
    }
    private func exclusive<T>(_ body: () async throws -> T) async rethrows -> T {
        await acquire()
        defer { release() }
        return try await body()
    }

    /// Releases the models (after the running inference, never during it).
    func unloadAll() async {
        await exclusive {
            releaseModels()
        }
    }

    // MARK: Tagging

    #if DEBUG
    /// Isolated diagnostic: synthetic input, no tags or media are written to the library.
    func auditIdleMemory(to output: URL) async {
        var lines: [String] = []
        func record(_ label: String) {
            let s = MLX.Memory.snapshot()
            lines.append("\(label): active=\(s.activeMemory) cache=\(s.cacheMemory) tagger=\(tagger != nil) embedder=\(embedder != nil)")
            try? lines.joined(separator: "\n").write(to: output, atomically: true, encoding: .utf8)
        }
        record("baseline")
        do {
            guard let model = Core.installedModels().first(where: { $0.vision }) else {
                record("SKIP: no vision model installed"); return
            }
            for round in 1...2 {
                let image = CIImage(color: CIColor(red: 0.2, green: 0.4, blue: 0.8)).cropped(to: CGRect(x: 0, y: 0, width: 448, height: 448))
                _ = try await tags(for: image, repo: model.id)
                record("round \(round) after inference")
                try await Task.sleep(nanoseconds: 35_000_000_000)
                record("round \(round) after idle")
                guard tagger == nil, embedder == nil else { record("FAIL: idle models retained"); return }
            }
            record("PASS")
        } catch {
            lines.append("ERROR: \(error.localizedDescription)")
            try? lines.joined(separator: "\n").write(to: output, atomically: true, encoding: .utf8)
        }
    }
    #endif

    /// The tagging prompt is an in-app setting (Settings → AI 模型 → 提示词). The bundled
    /// AIPrompt.txt only supplies the defaults.
    struct Prompt: Codable, Equatable {
        var system = "你是一个图片标注器。你只输出 JSON 字符串数组，不输出任何其他文字。"
        var prompt = "为这张图片生成 5 到 10 个简短的中文标签，每个标签 1 到 6 个字。只输出 JSON 字符串数组。"
        var context = "帖子文字（仅供参考）：\n{text}"
        /// This media's current tags ({existing}).
        var existing = "这张图片目前已有的标签：{existing}"
        /// The library's tags ({tags}), so the model reuses names instead of inventing synonyms.
        var vocabulary = "资料库里已有的标签（描述同一事物时直接用原词）：{tags}"

        init(system: String? = nil, prompt: String? = nil, context: String? = nil, existing: String? = nil, vocabulary: String? = nil) {
            if let system { self.system = system }; if let prompt { self.prompt = prompt }; if let context { self.context = context }
            if let existing { self.existing = existing }; if let vocabulary { self.vocabulary = vocabulary }
        }
        init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            let def = Prompt()
            system = try c.decodeIfPresent(String.self, forKey: .system) ?? def.system
            prompt = try c.decodeIfPresent(String.self, forKey: .prompt) ?? def.prompt
            context = try c.decodeIfPresent(String.self, forKey: .context) ?? def.context
            existing = try c.decodeIfPresent(String.self, forKey: .existing) ?? Prompt.defaults.existing
            vocabulary = try c.decodeIfPresent(String.self, forKey: .vocabulary) ?? Prompt.defaults.vocabulary
        }

        private static let key = "ai.prompt"
        /// Bumped when the default prompt changes in a way saved prompts must follow; older
        /// saved prompts are replaced once (the user agreed to this for version 2).
        private static let version = 2
        private static let versionKey = "ai.prompt.version"
        static let changed = Notification.Name("AIPromptChanged")

        /// The prompt in use: the shared setting (the same on every device of the sync account),
        /// or the defaults.
        static func load() -> Prompt {
            migrateLocal()
            if let s = Core.setting(key), let p = try? JSONDecoder().decode(Prompt.self, from: Data(s.utf8)) { return p }
            return defaults
        }
        /// Saved here and sent to every device (the defaults clear the setting everywhere).
        static func save(_ p: Prompt) {
            if p == defaults { Core.setSetting(key, nil) }
            else if let d = try? JSONEncoder().encode(p) { Core.setSetting(key, String(decoding: d, as: UTF8.self)) }
            NotificationCenter.default.post(name: changed, object: nil)
        }

        /// Earlier versions kept a custom prompt on this device only: hand it to the shared
        /// setting once (unless another device already shared one).
        private static func migrateLocal() {
            let ud = UserDefaults.standard
            if ud.integer(forKey: versionKey) < version { ud.removeObject(forKey: key); ud.set(version, forKey: versionKey) }
            guard let d = ud.data(forKey: key) else { return }
            if Core.setting(key) == nil, (try? JSONDecoder().decode(Prompt.self, from: d)) != nil { Core.setSetting(key, String(decoding: d, as: UTF8.self)) }
            ud.removeObject(forKey: key)
        }

        /// Defaults from the bundled AIPrompt.txt ([system] / [prompt] / [context] sections).
        static var defaults: Prompt {
            guard let url = Bundle.main.url(forResource: "AIPrompt", withExtension: "txt"), let raw = try? String(contentsOf: url, encoding: .utf8) else { return Prompt() }
            var p = Prompt(), section: String?, buf: [String] = []
            func flush() {
                let text = buf.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    switch section {
                    case "system": p.system = text; case "prompt": p.prompt = text; case "context": p.context = text
                    case "existing": p.existing = text; case "vocabulary": p.vocabulary = text
                    default: break
                    }
                }
                buf = []
            }
            for line in raw.components(separatedBy: .newlines) {
                if line.hasPrefix("#") { continue }
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("[") && t.hasSuffix("]") { flush(); section = String(t.dropFirst().dropLast()); continue }
                buf.append(line)
            }
            flush()
            return p
        }
    }

    /// Post text for the model: @mentions and links removed, trimmed to 300 characters. Author
    /// name and handle are never passed.
    nonisolated static func cleanContext(_ text: String?) -> String? {
        guard var t = text else { return nil }
        t = t.replacingOccurrences(of: #"https?://\S+"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"@[A-Za-z0-9_]{1,15}"#, with: "", options: .regularExpression)
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        return t.count > 300 ? String(t.prefix(300)) + "…" : t
    }

    private func loadTagger(_ repo: String) async throws -> ModelContainer {
        if let t = tagger, t.repo == repo { return t.container }
        guard Self.isSupported else { throw EngineError.simulator }
        tagger = nil
        MLX.GPU.clearCache()
        guard let dir = Core.installedModels().first(where: { $0.id == repo })?.url, FileManager.default.fileExists(atPath: dir.appendingPathComponent("config.json").path) else {
            throw EngineError.notInstalled(repo)
        }
        MLX.GPU.set(cacheLimit: 128 * 1024 * 1024)
        if let e = Self.memoryCheck(repo) { throw e }
        let c = try await VLMModelFactory.shared.loadContainer(from: dir, using: LocalTokenizerLoader())
        tagger = (repo, c)
        return c
    }

    /// Tags for one image. The model also sees the post text, the media's current tags and the
    /// library's existing tags, so it keeps fitting tags and reuses existing names verbatim.
    func tags(for image: CIImage, repo: String, postText: String? = nil, existing: [String] = [], vocabulary: [String] = []) async throws -> [String] {
        // an external model runs elsewhere: no GPU gate, works in the simulator too
        if let m = ExternalModels.find(repo) {
            return try await ExternalAI.tags(for: image, model: m, postText: postText, existing: existing, vocabulary: vocabulary)
        }
        return try await exclusive { try await tagsUnlocked(for: image, repo: repo, postText: postText, existing: existing, vocabulary: vocabulary) }
    }

    private func tagsUnlocked(for image: CIImage, repo: String, postText: String?, existing: [String], vocabulary: [String]) async throws -> [String] {
        let container = try await loadTagger(repo)
        let p = PromptSets.prompt(forModel: repo)
        let session = ChatSession(
            container, instructions: p.system,
            generateParameters: GenerateParameters(maxTokens: 160, temperature: 0.1),
            processing: .init(resize: CGSize(width: 448, height: 448)))
        let question = p.question(existing: existing, vocabulary: vocabulary, postText: postText)
        let out = try await session.respond(to: question, image: .ciImage(image), video: nil)
        return Self.parseTags(out)
    }

    /// Accepts a JSON array or, failing that, a delimited list; normalizes and de-duplicates.
    static func parseTags(_ raw: String) -> [String] {
        var text = raw
        if let r = text.range(of: "</think>") { text = String(text[r.upperBound...]) }
        var items: [String] = []
        if let a = text.firstIndex(of: "["), let b = text.lastIndex(of: "]"), a < b,
           let arr = try? JSONSerialization.jsonObject(with: Data(text[a...b].utf8)) as? [Any] {
            items = arr.compactMap { $0 as? String }
        } else {
            items = text.components(separatedBy: CharacterSet(charactersIn: ",，、;；\n#")).map { $0 }
        }
        var seen = Set<String>()
        return items.map { $0.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'“”[]()（）。."))).lowercased() }
            .filter { !$0.isEmpty && $0.count <= 12 && seen.insert($0).inserted }
            .prefix(12).map { $0 }
    }

    // MARK: Embeddings

    private func loadEmbedder(_ repo: String) async throws -> EmbedderModelContainer {
        if let e = embedder, e.repo == repo { return e.container }
        guard Self.isSupported else { throw EngineError.simulator }
        embedder = nil
        MLX.GPU.clearCache()
        MLX.GPU.set(cacheLimit: 128 * 1024 * 1024)
        guard let dir = Core.installedModels().first(where: { $0.id == repo })?.url, FileManager.default.fileExists(atPath: dir.appendingPathComponent("config.json").path) else {
            throw EngineError.notInstalled(repo)
        }
        if let e = Self.memoryCheck(repo) { throw e }
        let c = try await EmbedderModelFactory.shared.loadContainer(from: dir, using: LocalTokenizerLoader())
        embedder = (repo, c)
        return c
    }

    /// L2-normalized embeddings, one per text (texts are embedded individually: labels are short
    /// and this avoids padding effects with last-token pooling).
    func embed(_ texts: [String], repo: String) async throws -> [[Float]] {
        try await exclusive { try await embedUnlocked(texts, repo: repo) }
    }

    private func embedUnlocked(_ texts: [String], repo: String) async throws -> [[Float]] {
        let container = try await loadEmbedder(repo)
        return await container.perform { ctx in
            texts.map { t in
                let ids = ctx.tokenizer.encode(text: t, addSpecialTokens: true)
                let input = MLXArray(ids.map { Int32($0) }).expandedDimensions(axis: 0)
                let mask = MLXArray.ones(input.shape, dtype: .int32)
                let out = ctx.model(input, positionIds: nil, tokenTypeIds: nil, attentionMask: mask)
                let pooled = ctx.pooling(out, mask: mask, normalize: true)
                pooled.eval()
                return pooled.asArray(Float.self)
            }
        }
    }

    /// Qwen3-Embedding is trained with an instruction prefix on queries (documents are embedded plain).
    nonisolated static func queryText(_ term: String) -> String {
        "Instruct: Given a search keyword, retrieve image tags with the same or closely related meaning\nQuery: \(term)"
    }

    /// Vectors for search terms if an embedder is installed; nil otherwise (substring matching still applies).
    func queryVectors(_ terms: [String]) async -> (model: String, vectors: [[Float]?])? {
        guard Self.isSupported, let repo = ModelStore.shared.activeEmbedderId, !terms.isEmpty else { return nil }
        guard let v = try? await embed(terms.map(Self.queryText), repo: repo) else { return nil }
        return (repo, v.map { Optional($0) })
    }

    // MARK: Image preparation

    /// Downsampled still for a photo, or a representative frame for an MP4.
    nonisolated static func stillImage(path: String, kind: String) -> CIImage? {
        let url = URL(fileURLWithPath: path)
        if kind == "video" {
            let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: 896, height: 896)
            let asset = AVURLAsset(url: url)
            let dur = CMTimeGetSeconds(asset.duration)
            let t = CMTime(seconds: dur.isFinite && dur > 1 ? dur * 0.33 : 0, preferredTimescale: 600)
            return (try? gen.copyCGImage(at: t, actualTime: nil)).map { fitForModel(CIImage(cgImage: $0)) }
        }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 896,
              ] as CFDictionary) else { return nil }
        return fitForModel(CIImage(cgImage: cg))
    }

    /// Vision models cut the picture into 28–32 px patches after scaling it into 448 × 448: a
    /// very thin strip (e.g. 22 × 900) or a tiny icon came out narrower than one patch and the
    /// model refused it ("Width: 22 must be larger than factor: 32"). Pads the short side with
    /// black up to a quarter of the long side and scales tiny images up, so every image fits.
    nonisolated static func fitForModel(_ image: CIImage) -> CIImage {
        let e = image.extent
        guard e.width >= 1, e.height >= 1, e.width.isFinite, e.height.isFinite else { return image }
        var img = image.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
        var w = e.width, h = e.height
        let minSide: CGFloat = 112
        if min(w, h) < minSide {
            let k = min(minSide / min(w, h), 896 / max(w, h))
            if k > 1 { img = img.transformed(by: CGAffineTransform(scaleX: k, y: k)); w *= k; h *= k }
        }
        let W = max(w, (h / 4).rounded(.up)), H = max(h, (w / 4).rounded(.up))
        guard W > w || H > h else { return img }
        let canvas = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: W, height: H))
        return img.transformed(by: CGAffineTransform(translationX: ((W - w) / 2).rounded(), y: ((H - h) / 2).rounded())).composited(over: canvas)
    }
}
