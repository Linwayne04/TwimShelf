import UIKit
import UniformTypeIdentifiers

/// Installed models (several can coexist), defaults, re-tag all, catalog downloads, and
/// import/export in the standard Hugging Face / MLX folder format.
final class ModelsViewController: FormViewController, UIDocumentPickerDelegate {
    private var observers: [NSObjectProtocol] = []
    private var cards: [Activity.Kind: ActivityCardView] = [:]
    private var lastDownloadRunning = false
    private var remote: [SyncService.RemoteModel] = []
    private var remoteLoading = false
    private var remoteChecked = false

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "AI 模型"
        navigationItem.largeTitleDisplayMode = .never
        let nc = NotificationCenter.default
        observers = [ActivityCenter.changed, ModelStore.changed, AutoTagger.progressChanged, AIEngine.Prompt.changed, ExternalModels.changed].map {
            nc.addObserver(forName: $0, object: nil, queue: .main) { [weak self] _ in self?.tick() }
        }
        build()
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    private func tick() {
        let running = Core.modelStatus()?.running ?? false
        if lastDownloadRunning, !running {
            if let s = Core.modelStatus() {
                if s.finished { ModelStore.shared.reload() } else if let e = s.error, e != "已取消" { alert("下载失败", e) }
            }
        }
        lastDownloadRunning = running
        build()
    }

    private func card(_ a: Activity) -> ActivityCardView {
        let c = cards[a.kind] ?? ActivityCardView()
        cards[a.kind] = c
        c.update(a)
        return c
    }

    private func build() {
        let store = ModelStore.shared
        let counts = AutoTagger.shared.counts
        var s: [Section] = []
        if !AIEngine.isSupported {
            s.append(Section(id: "sim", footer: "当前运行在 iOS 模拟器中，Metal 推理不可用。模型可以管理与导入导出，但打标签与语义搜索需要在真机或 Mac 上运行。", rows: [
                .value("模拟器", "仅管理", icon: .init("exclamationmark.triangle.fill", .systemOrange))]))
        }
        let acts = ActivityCenter.shared.activities.filter { $0.kind == .tagging || $0.kind == .model }
        if !acts.isEmpty {
            var rows: [Row] = acts.map { .custom("act-\($0.kind.rawValue)", card($0)) }
            if acts.contains(where: { $0.kind == .tagging }) { rows.append(.button("停止标记", icon: .init("stop.fill", .systemRed), destructive: true) { AutoTagger.shared.stop() }) }
            if acts.contains(where: { $0.kind == .model }) { rows.append(.button("取消模型下载", icon: .init("xmark", .systemRed), destructive: true) { Core.cancelModelDownload() }) }
            s.append(Section(id: "act", header: "进行中", rows: rows))
        }
        var auto: [Row] = [
            .toggle("自动标记新媒体", store.autoTag, icon: .init("wand.and.stars", .systemPurple)) { on in
                store.autoTag = on
                if on { AutoTagger.shared.startIfEnabled() }
            },
            .value("已分析", "\(counts.done) / \(counts.total)", icon: .init("photo.stack.fill", .systemBlue)),
        ]
        if let e = AutoTagger.shared.lastError { auto.append(.value("错误", e, icon: .init("exclamationmark.octagon.fill", .systemRed))) }
        let failures = Core.aiFailures()
        if !failures.isEmpty {
            // shown, never dropped silently: which media, why, and a way to try again
            auto.append(.navigation("这台设备无法分析", detail: "\(failures.count) 个", icon: .init("exclamationmark.triangle.fill", .systemOrange), id: "n:aifail") { [weak self] in
                let lines = failures.prefix(30).map { "\($0.mediaId.prefix(12))… · 试了 \($0.attempts) 次 · \($0.reason)" }
                let a = UIAlertController(title: "这台设备无法分析的媒体", message: (lines + (failures.count > 30 ? ["……还有 \(failures.count - 30) 个"] : [])).joined(separator: "\n")
                    + "\n\n它们没有被标记为已分析：同一账户里的其他设备仍会分析它们，结果会同步回来。", preferredStyle: .alert)
                a.addAction(UIAlertAction(title: "重试", style: .default) { _ in Core.aiFailuresClear(); AutoTagger.shared.startIfEnabled(); self?.build() })
                a.addAction(UIAlertAction(title: "好", style: .cancel))
                self?.present(a, animated: true)
            })
        }
        auto.append(.navigation("提示词", detail: "\(PromptSets.all.count) 套", icon: .init("text.bubble.fill", .systemOrange), id: "n:prompt") { [weak self] in
            let vc = PromptSetsViewController()
            vc.onRetagAll = { [weak self] in self?.retagAll() }
            self?.navigationController?.pushViewController(vc, animated: true)
        })
        if !store.taggerIds.isEmpty {
            auto.append(.button("全部重新标记…", icon: .init("arrow.clockwise.circle.fill", .systemIndigo)) { [weak self] in self?.retagAll() })
        }
        s.append(Section(id: "auto", header: "打标签", footer: "只有尚未被任何模型分析过的媒体会被自动标记，更换默认模型不会重新标记。需要时可在照片的长按菜单中单独重新标记，或在这里全部重新标记。你添加或认可的标签永远不会被删除。", rows: auto))

        s.append(Section(id: "defaults", header: "默认模型", rows: [
            .navigation("打标签", detail: store.activeTaggerId.map { store.displayName($0) } ?? "未安装", icon: .init("eye.fill", .systemPink)) { [weak self] in self?.choose(.tagger) },
            .navigation("语义搜索", detail: store.activeEmbedder.map { store.displayName($0.id) } ?? "未安装", icon: .init("text.magnifyingglass", .systemTeal)) { [weak self] in self?.choose(.embedder) },
        ]))

        let installed: [Row] = store.installed.map { m in
            let isDefault = m.id == store.activeTaggerId || m.id == store.activeEmbedderId
            return .navigation(store.displayName(m.id), detail: (isDefault ? "默认 · " : "") + (m.vision ? PromptSets.name(forModel: m.id) + " · " : "") + ActivityCenter.bytes(m.bytes),
                               icon: .init(m.vision ? "eye" : "text.magnifyingglass", m.vision ? .systemPink : .systemTeal), id: "m:\(m.id)") { [weak self] in self?.actions(for: m) }
        }
        s.append(Section(id: "installed", header: "已安装（\(store.installed.count)）", footer: "模型使用标准的 Hugging Face / MLX 文件夹格式（config.json、分词器与 .safetensors），可以多个并存。",
                         rows: installed.isEmpty ? [.value("尚未安装模型", nil, icon: .init("tray", .systemGray))] : installed))

        // external models: used exactly like the built-in ones
        var ext: [Row] = ExternalModels.all.map { e in
            .navigation(e.title, detail: (e.id == store.activeTaggerId ? "默认 · " : "") + e.kindLabel + " · " + PromptSets.name(forModel: e.id),
                        icon: .init(e.isLocal ? "server.rack" : "cloud.fill", e.isLocal ? .systemGreen : .systemBlue), id: "x:\(e.id)") { [weak self] in
                self?.navigationController?.pushViewController(ExternalModelViewController(model: e), animated: true)
            }
        }
        ext.append(.button("添加外部模型…", icon: .init("plus.circle.fill", .systemBlue), id: "b:addExternal") { [weak self] in
            self?.navigationController?.pushViewController(ExternalModelViewController(model: .new()), animated: true)
        })
        s.append(Section(id: "external", header: "外部模型", footer: "OpenAI 兼容接口（OpenAI、Grok、OpenRouter、Ollama、LM Studio 等）。只填地址是本地服务；填了 API Key 和模型名称是云端模型。模型列表在设备间同步，API Key 只保存在各自设备的钥匙串里。", rows: ext))

        let downloading = Core.modelStatus().flatMap { $0.running ? $0.repo : nil }
        let unfinished = Dictionary(Core.interruptedModels().map { ($0.repo, $0.bytes) }, uniquingKeysWith: max)
        let catalog: [Row] = ModelCatalog.all.filter { !store.isInstalled(repo: $0.repo) }.map { m in
            .navigation(m.displayName, detail: downloading == m.repo ? "下载中…" : unfinished[m.repo].map { "未完成 \(ActivityCenter.bytes($0)) / \(ActivityCenter.bytes(m.bytes)) · 继续" } ?? ActivityCenter.bytes(m.bytes),
                        icon: .init(m.role == .tagger ? "icloud.and.arrow.down.fill" : "icloud.and.arrow.down", m.role == .tagger ? .systemBlue : .systemTeal), id: "d:\(m.repo)") { [weak self] in self?.offerDownload(m) }
        }
        if !catalog.isEmpty {
            s.append(Section(id: "catalog", header: "可下载", footer: "推荐：\(ModelCatalog.recommendedTagger.displayName)（按本机内存）。全部为 MLX 4-bit，均不超过 14B。下载使用的是你当前的网络，请注意流量。", rows: catalog))
        }
        if SyncService.shared.hasAccount {
            var rows: [Row] = remote.map { r in
                .navigation(store.displayName(r.info.id), detail: "\(r.peer.name) · \(ActivityCenter.bytes(r.info.bytes))",
                            icon: .init("arrow.down.to.line.circle.fill", .systemIndigo), id: "r:\(r.peer.device):\(r.info.id)") { [weak self] in self?.confirmPull(r) }
            }
            if remoteLoading { rows.insert(.value("正在查询其他设备…", nil, icon: .init("hourglass", .systemGray), id: "r:loading"), at: 0) }
            else if remote.isEmpty { rows.append(.value(SyncService.shared.reachablePeers.isEmpty ? "没有在线的同账户设备" : (remoteChecked ? "其他设备上没有本机缺少的模型" : "点下方按钮查询"), nil, icon: .init("laptopcomputer.and.iphone", .systemGray), id: "r:none")) }
            rows.append(.button("查询其他设备上的模型", icon: .init("arrow.clockwise", .systemBlue), enabled: !remoteLoading && !SyncService.shared.reachablePeers.isEmpty, id: "r:refresh") { [weak self] in self?.loadRemote() })
            s.append(Section(id: "remote", header: "其他设备上的模型", footer: "模型不会自动同步。这里列出同一同步账户、当前在线的设备上有而本机没有的模型，点击后才会通过局域网拉取，并在校验通过后安装。", rows: rows))
        }
        s.append(Section(id: "io", header: "导入", footer: "可导入任意标准 MLX 模型文件夹，或其 ZIP（例如从另一台设备导出后隔空投送过来的），避免重复下载。", rows: [
            .button("导入模型文件夹或 ZIP…", icon: .init("square.and.arrow.down.fill", .systemGreen)) { [weak self] in self?.pickModel() },
        ]))
        sections = s
        reloadForm()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if !remoteChecked, !SyncService.shared.reachablePeers.isEmpty { loadRemote() }
    }

    private func loadRemote() {
        remoteLoading = true
        build()
        SyncService.shared.remoteModels { [weak self] list in
            self?.remote = list
            self?.remoteLoading = false
            self?.remoteChecked = true
            self?.build()
        }
    }

    private func confirmPull(_ r: SyncService.RemoteModel) {
        if Core.modelStatus()?.running == true { return alert("已有模型正在下载") }
        let a = UIAlertController(title: "从「\(r.peer.name)」拉取？", message: "\(ModelStore.shared.displayName(r.info.id))，约 \(ActivityCenter.bytes(r.info.bytes))。通过局域网直接传输，不使用外网流量。", preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "取消", style: .cancel))
        a.addAction(UIAlertAction(title: "拉取", style: .default) { [weak self] _ in
            do { try SyncService.shared.pull(r); self?.remote.removeAll { $0 == r }; self?.build() } catch { self?.alert("无法拉取", error.localizedDescription) }
        })
        present(a, animated: true)
    }

    private enum Role { case tagger, embedder }

    private func choose(_ role: Role) {
        let store = ModelStore.shared
        let list = role == .tagger ? store.taggerIds : store.embedders.map(\.id)
        guard !list.isEmpty else { return alert("还没有可用的模型", "先下载、导入或添加一个模型。") }
        let sheet = UIAlertController(title: role == .tagger ? "默认打标签模型" : "默认语义搜索模型", message: "更换后不会重新标记已分析的媒体。", preferredStyle: .actionSheet)
        for id in list {
            let current = (role == .tagger ? store.activeTaggerId : store.activeEmbedderId) == id
            sheet.addAction(UIAlertAction(title: (current ? "✓ " : "") + store.displayName(id), style: .default) { _ in
                if role == .tagger { store.activeTaggerId = id } else { store.activeEmbedderId = id; Task { await AutoTagger.shared.embedMissingLabels() } }
            })
        }
        sheet.addAction(UIAlertAction(title: "取消", style: .cancel))
        anchor(sheet)
        present(sheet, animated: true)
    }

    private func retagAll() {
        let store = ModelStore.shared
        let pickModel = UIAlertController(title: "全部重新标记", message: "选择用哪个模型重新分析整个资料库。", preferredStyle: .actionSheet)
        for id in store.taggerIds {
            pickModel.addAction(UIAlertAction(title: store.displayName(id), style: .default) { [weak self] _ in self?.retagAll(model: id) })
        }
        pickModel.addAction(UIAlertAction(title: "取消", style: .cancel))
        anchor(pickModel)
        present(pickModel, animated: true)
    }

    private func retagAll(model: String) {
        let a = UIAlertController(title: "旧的 AI 标签怎么处理？", message: "你添加的标签和已认可的 AI 标签都会保留。", preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "保留，只添加新标签", style: .default) { _ in AutoTagger.shared.retagAll(model: model, replaceOld: false) })
        a.addAction(UIAlertAction(title: "删除未认可的旧 AI 标签", style: .destructive) { _ in AutoTagger.shared.retagAll(model: model, replaceOld: true) })
        a.addAction(UIAlertAction(title: "取消", style: .cancel))
        present(a, animated: true)
    }

    private func offerDownload(_ m: CatalogModel) {
        if Core.modelStatus()?.running == true { return alert("已有模型正在下载") }
        let a = UIAlertController(title: "下载 \(m.displayName)？", message: "\(m.note)\n大小约 \(ActivityCenter.bytes(m.bytes))，将使用当前网络下载。", preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "取消", style: .cancel))
        a.addAction(UIAlertAction(title: "下载", style: .default) { [weak self] _ in
            do { try Core.downloadModel(m.repo); self?.build() } catch { self?.alert("无法下载", error.localizedDescription) }
        })
        present(a, animated: true)
    }

    private func actions(for m: Core.ModelInfo) {
        let store = ModelStore.shared
        let sheet = UIAlertController(title: store.displayName(m.id), message: "\(m.modelType ?? "") · \(ActivityCenter.bytes(m.bytes))", preferredStyle: .actionSheet)
        if m.vision, store.activeTaggerId != m.id {
            sheet.addAction(UIAlertAction(title: "设为默认打标签模型", style: .default) { _ in store.activeTaggerId = m.id })
        }
        if m.vision {
            sheet.addAction(UIAlertAction(title: "提示词：\(PromptSets.name(forModel: m.id))…", style: .default) { [weak self] _ in self?.choosePrompt(for: m.id) })
        }
        if !m.vision, store.activeEmbedderId != m.id {
            sheet.addAction(UIAlertAction(title: "设为默认语义搜索模型", style: .default) { _ in store.activeEmbedderId = m.id })
        }
        sheet.addAction(UIAlertAction(title: "导出为 ZIP…", style: .default) { [weak self] _ in self?.export(m) })
        sheet.addAction(UIAlertAction(title: "删除", style: .destructive) { [weak self] _ in
            let c = UIAlertController(title: "删除 \(store.displayName(m.id))？", message: "之后需要时要重新下载或导入。", preferredStyle: .alert)
            c.addAction(UIAlertAction(title: "取消", style: .cancel))
            c.addAction(UIAlertAction(title: "删除", style: .destructive) { _ in
                // stop using it, release it, then delete the files (gigabytes) off the main thread
                AutoTagger.shared.stop()
                Task {
                    await AIEngine.shared.unloadAll()
                    await MainActor.run {
                        self?.runBusy("正在删除模型…", { try Core.deleteModel(m.id) }) { _ in
                            store.reload(); self?.build(); AutoTagger.shared.startIfEnabled()
                        }
                    }
                }
            })
            self?.present(c, animated: true)
        })
        sheet.addAction(UIAlertAction(title: "取消", style: .cancel))
        anchor(sheet)
        present(sheet, animated: true)
    }

    private func choosePrompt(for model: String) {
        let sheet = UIAlertController(title: "\(ModelStore.shared.displayName(model)) 使用的提示词", message: nil, preferredStyle: .actionSheet)
        let current = PromptSets.setId(forModel: model)
        for p in PromptSets.all {
            sheet.addAction(UIAlertAction(title: (p.id == current ? "✓ " : "") + p.name, style: .default) { [weak self] _ in PromptSets.assign(p.id, to: model); self?.build() })
        }
        sheet.addAction(UIAlertAction(title: "取消", style: .cancel))
        anchor(sheet)
        present(sheet, animated: true)
    }

    private func anchor(_ sheet: UIAlertController) { anchorSheet(sheet) }

    private func export(_ m: Core.ModelInfo) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("model-export", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let out = dir.appendingPathComponent(m.id).appendingPathExtension("zip")
        runBusy("正在打包模型…", { try Core.exportModelZip(m.id, to: out) }) { [weak self] in
            guard let self else { return }
            let share = UIActivityViewController(activityItems: [out], applicationActivities: nil)
            share.popoverPresentationController?.sourceView = self.view
            share.popoverPresentationController?.sourceRect = CGRect(x: self.view.bounds.midX, y: 80, width: 1, height: 1)
            share.completionWithItemsHandler = { _, _, _, _ in try? FileManager.default.removeItem(at: dir) }
            self.present(share, animated: true)
        }
    }

    private func pickModel() {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder, .zip], asCopy: false)
        picker.delegate = self
        present(picker, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        runBusy("正在导入模型…", {
            let ok = url.startAccessingSecurityScopedResource()
            defer { if ok { url.stopAccessingSecurityScopedResource() } }
            return try Core.importModel(url)
        }) { [weak self] m in
            ModelStore.shared.reload()
            self?.build()
            self?.alert("已导入", ModelStore.shared.displayName(m.id))
        }
    }
}

/// Edits the AI tagging prompt (an app setting). Saving applies to all future tagging; the user
/// can also re-tag the whole library right away.
final class PromptViewController: FormViewController {
    var onRetagAll: (() -> Void)?
    private var set: PromptSet
    private let nameField = UITextField()
    init(set: PromptSet) { self.set = set; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError() }
    private let system = PlaceholderTextView(placeholder: "系统指令")
    private let prompt = PlaceholderTextView(placeholder: "每张图片的提问")
    private let context = PlaceholderTextView(placeholder: "帖子文字的附加说明，{text} 会被替换为帖子正文")
    private let existing = PlaceholderTextView(placeholder: "已有标签的说明，{existing} 会被替换为这张图片现有的标签")
    private let vocabulary = PlaceholderTextView(placeholder: "资料库标签的说明，{tags} 会被替换为最常用的已有标签")

    override func viewDidLoad() {
        super.viewDidLoad()
        title = set.name
        navigationItem.largeTitleDisplayMode = .never
        nameField.text = set.name
        nameField.placeholder = "名称"
        nameField.isEnabled = set.id != PromptSets.defaultId
        nameField.accessibilityIdentifier = "promptName"
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "保存", primaryAction: UIAction { [weak self] _ in self?.save() })
        navigationItem.rightBarButtonItem?.accessibilityIdentifier = "promptSave"
        system.accessibilityIdentifier = "promptSystem"
        prompt.accessibilityIdentifier = "promptPrompt"
        context.accessibilityIdentifier = "promptContext"
        fill(set.prompt)
        build()
    }

    private func fill(_ p: AIEngine.Prompt) { system.text = p.system; prompt.text = p.prompt; context.text = p.context; existing.text = p.existing; vocabulary.text = p.vocabulary }

    private func build() {
        let users = ModelStore.shared.taggerIds.filter { PromptSets.setId(forModel: $0) == set.id }.map { ModelStore.shared.displayName($0) }
        sections = [
            Section(id: "name", header: "名称", footer: users.isEmpty ? "还没有模型使用这套提示词。在模型的设置里可以选择。" : "使用它的模型：" + users.joined(separator: "、"), rows: [.custom("name", nameField)]),
            Section(id: "system", header: "系统指令", footer: "模型的角色与输出约束。", rows: [.custom("system", system)]),
            Section(id: "prompt", header: "提问", footer: "对每张图片的提问。无论怎么写，程序只会从回答里提取 JSON 字符串数组作为标签。", rows: [.custom("prompt", prompt)]),
            Section(id: "existing", header: "已有标签", footer: "{existing} 会被替换成这张图片现有的标签（改名后的名字）。图片还没有标签时这一段不会发送。", rows: [.custom("existing", existing)]),
            Section(id: "vocabulary", header: "资料库标签", footer: "{tags} 会被替换成资料库里最常用的 150 个标签，让模型直接沿用已有的叫法，而不是另造近义词。", rows: [.custom("vocabulary", vocabulary)]),
            Section(id: "context", header: "帖子文字", footer: "{text} 会被替换成帖子正文（已去掉 @提及和链接，最多 300 字，不含作者）。帖子没有正文时这一段不会发送。", rows: [.custom("context", context)]),
            Section(id: "reset", rows: [.button("恢复默认提示词", icon: .init("arrow.counterclockwise", .systemGray)) { [weak self] in self?.fill(AIEngine.Prompt.defaults) }]
                    + (set.id == PromptSets.defaultId || PromptSets.find(set.id) == nil ? [] : [.button("删除这套提示词", icon: .init("trash", .systemRed), destructive: true, id: "b:deletePrompt") { [weak self] in
                        guard let self else { return }
                        PromptSets.delete(self.set.id)
                        self.navigationController?.popViewController(animated: true)
                    }])),
        ]
        reloadForm(animated: false)
    }

    private func save() {
        view.endEditing(true)
        let p = AIEngine.Prompt(system: system.text, prompt: prompt.text, context: context.text, existing: existing.text, vocabulary: vocabulary.text)
        let name = (nameField.text ?? "").trimmingCharacters(in: .whitespaces)
        guard p != set.prompt || (!name.isEmpty && name != set.name) else { navigationController?.popViewController(animated: true); return }
        set.prompt = p
        if !name.isEmpty { set.name = name }
        PromptSets.save(set)
        let a = UIAlertController(title: "提示词已保存", message: "新的提示词会用于以后的所有打标签。也可以现在就用它重新标记整个资料库（你添加或认可的标签都会保留）。", preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "仅对以后生效", style: .cancel) { [weak self] _ in self?.navigationController?.popViewController(animated: true) })
        if !ModelStore.shared.taggerIds.isEmpty {
            let retag = onRetagAll
            a.addAction(UIAlertAction(title: "立即全部重新标记…", style: .default) { [weak self] _ in
                self?.navigationController?.popViewController(animated: true)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { retag?() }
            })
        }
        present(a, animated: true)
    }
}


/// The prompt sets: 默认 plus any number of the user's own; each model uses one of them.
final class PromptSetsViewController: FormViewController {
    var onRetagAll: (() -> Void)?
    private var observer: NSObjectProtocol?

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "提示词"
        navigationItem.largeTitleDisplayMode = .never
        observer = NotificationCenter.default.addObserver(forName: PromptSets.changed, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.build() } }
        build()
    }
    deinit { observer.map(NotificationCenter.default.removeObserver) }
    override func viewWillAppear(_ animated: Bool) { super.viewWillAppear(animated); build() }

    private func build() {
        let a = PromptSets.assignments
        let rows: [Row] = PromptSets.all.map { p in
            let n = ModelStore.shared.taggerIds.filter { (a[$0] ?? PromptSets.defaultId) == p.id }.count
            return .navigation(p.name, detail: n > 0 ? "\(n) 个模型使用" : nil, icon: .init("text.bubble", p.id == PromptSets.defaultId ? .systemOrange : .systemIndigo), id: "p:\(p.name)") { [weak self] in self?.open(p) }
        }
        sections = [
            Section(id: "sets", header: "提示词", footer: "每个模型（内置或外部）可以使用不同的一套提示词，在模型的设置里选择；没有指定的用「默认」。提示词在设备之间同步。", rows: rows),
            Section(id: "add", rows: [.button("新建提示词…", icon: .init("plus.circle.fill", .systemBlue), id: "b:newPrompt") { [weak self] in self?.newSet() }]),
        ]
        reloadForm(animated: false)
    }

    private func open(_ p: PromptSet) {
        let vc = PromptViewController(set: p)
        vc.onRetagAll = onRetagAll
        navigationController?.pushViewController(vc, animated: true)
    }

    private func newSet() {
        let a = UIAlertController(title: "新建提示词", message: "从「默认」复制一份，再修改。", preferredStyle: .alert)
        a.addTextField { $0.placeholder = "名称"; $0.accessibilityIdentifier = "newPromptName" }
        a.addAction(UIAlertAction(title: "取消", style: .cancel))
        a.addAction(UIAlertAction(title: "创建", style: .default) { [weak self] _ in
            let name = (a.textFields?.first?.text ?? "").trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return }
            self?.open(PromptSets.add(name: name, from: AIEngine.Prompt.load()))
        })
        present(a, animated: true)
    }
}

/// Adds or edits an external model: name, address, key, model name; its prompt set; default;
/// a test request; delete.
final class ExternalModelViewController: FormViewController {
    private var model: ExternalModel
    private let nameField = UITextField(), urlField = UITextField(), keyField = UITextField(), modelField = UITextField()
    private var testResult: String?
    private var testing = false

    init(model: ExternalModel) { self.model = model; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError() }

    private var isNew: Bool { ExternalModels.find(model.id) == nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = isNew ? "添加外部模型" : model.title
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "保存", primaryAction: UIAction { [weak self] _ in self?.save() })
        navigationItem.rightBarButtonItem?.accessibilityIdentifier = "externalSave"
        for (f, ph, id, text) in [(nameField, "名称（可不填）", "extName", model.name), (urlField, "例如 https://api.x.ai/v1 或 http://192.168.1.5:11434", "extURL", model.url),
                                  (keyField, "API Key（本地服务不填）", "extKey", model.apiKey ?? ""), (modelField, "模型名称，例如 grok-2-vision（本地可不填）", "extModel", model.model)] {
            f.placeholder = ph; f.text = text; f.accessibilityIdentifier = id
            f.autocapitalizationType = .none; f.autocorrectionType = .no; f.clearButtonMode = .whileEditing
        }
        urlField.keyboardType = .URL
        keyField.isSecureTextEntry = true
        build()
    }

    private func read() -> ExternalModel {
        var m = model
        m.name = (nameField.text ?? "").trimmingCharacters(in: .whitespaces)
        m.url = (urlField.text ?? "").trimmingCharacters(in: .whitespaces)
        m.model = (modelField.text ?? "").trimmingCharacters(in: .whitespaces)
        return m
    }

    private func build() {
        let store = ModelStore.shared
        var s: [Section] = [
            Section(id: "conn", header: "连接", footer: "只填地址 = 本地服务（Ollama、LM Studio 等，模型名称不填时用服务上的第一个模型）。填了 API Key 和模型名称 = 云端模型。API Key 只保存在这台设备的钥匙串里，不会同步。",
                    rows: [.custom("name", nameField), .custom("url", urlField), .custom("key", keyField), .custom("model", modelField)]),
        ]
        if !isNew {
            s.append(Section(id: "use", header: "使用", rows: [
                .menu("提示词", value: PromptSets.name(forModel: model.id), icon: .init("text.bubble.fill", .systemOrange), id: "m:prompt") { [weak self] in
                    guard let self else { return UIMenu() }
                    let cur = PromptSets.setId(forModel: self.model.id)
                    return UIMenu(children: PromptSets.all.map { p in UIAction(title: p.name, state: p.id == cur ? .on : .off) { _ in PromptSets.assign(p.id, to: self.model.id); self.build() } })
                },
                store.activeTaggerId == model.id
                    ? .value("默认打标签模型", "是", icon: .init("star.fill", .systemYellow), id: "v:default")
                    : .button("设为默认打标签模型", icon: .init("star", .systemYellow), id: "b:default") { [weak self] in guard let self else { return }; store.activeTaggerId = self.model.id; self.build() },
            ]))
        }
        var test: [Row] = [.button(testing ? "正在测试…" : "测试连接", icon: .init("bolt.horizontal.fill", .systemGreen), enabled: !testing, id: "b:test") { [weak self] in self?.runTest() }]
        if let r = testResult { test.append(.value(r, nil, icon: .init(r.hasPrefix("成功") ? "checkmark.circle.fill" : "xmark.octagon.fill", r.hasPrefix("成功") ? .systemGreen : .systemRed), id: "v:test")) }
        s.append(Section(id: "test", footer: "发送一张小的灰色测试图，检查地址、Key 和模型是否可用（会产生一次很小的调用）。", rows: test))
        if !isNew {
            s.append(Section(id: "del", rows: [.button("删除这个外部模型", icon: .init("trash", .systemRed), destructive: true, id: "b:deleteExternal") { [weak self] in
                guard let self else { return }
                ExternalModels.remove(self.model.id)
                ModelStore.shared.adoptInstalled()
                self.navigationController?.popViewController(animated: true)
            }]))
        }
        sections = s
        reloadForm(animated: false)
    }

    private func save() {
        view.endEditing(true)
        let m = read()
        guard !m.url.isEmpty, ExternalAI.endpoint(m.url, "models") != nil else { return alert("请填写地址") }
        let key = (keyField.text ?? "").trimmingCharacters(in: .whitespaces)
        if !key.isEmpty, m.model.isEmpty { return alert("云端模型需要填写模型名称") }
        m.apiKey = key.isEmpty ? nil : key
        ExternalModels.save(m)
        model = m
        if ModelStore.shared.activeTaggerId == nil { ModelStore.shared.activeTaggerId = m.id }
        navigationController?.popViewController(animated: true)
    }

    private func runTest() {
        view.endEditing(true)
        let m = read()
        let key = (keyField.text ?? "").trimmingCharacters(in: .whitespaces)
        m.apiKey = key.isEmpty ? nil : key   // the test uses what is typed (saved with 保存)
        testing = true; testResult = nil; build()
        Task { @MainActor in
            do {
                let tags = try await ExternalAI.test(m)
                testResult = "成功：" + (tags.isEmpty ? "（没有返回标签）" : tags.joined(separator: "、"))
            } catch { testResult = "失败：" + error.localizedDescription }
            if isNew { m.apiKey = nil }
            testing = false
            build()
        }
    }
}
