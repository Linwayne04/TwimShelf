import AppKit
import SwiftUI

// MARK: - State

private struct ExternalDraft: Identifiable {
    var model: ExternalModel
    var isNew: Bool
    var id: String { model.id }
}

private enum PromptField: CaseIterable {
    case system, question, existing, vocabulary, context
    var title: String {
        switch self {
        case .system: "系统指令"
        case .question: "提问"
        case .existing: "已有标签"
        case .vocabulary: "资料库标签"
        case .context: "帖子文字"
        }
    }
    var note: String {
        switch self {
        case .system: "告诉模型它的角色和输出的格式。"
        case .question: "对每张图提出的问题，可以用下面三个占位符。"
        case .existing: "{existing}：这张图已经有的标签，让模型沿用而不是重复。"
        case .vocabulary: "{tags}：资料库里常用的标签，让模型尽量用已有的名字。"
        case .context: "{text}：帖子正文（已去掉 @提及和链接，最多 300 字，不含作者）。"
        }
    }
}

@MainActor
final class ModelsModel: ObservableObject {
    // prompts: the set being edited and its five texts (loaded once, so unsaved edits survive redraws)
    @Published var editingSet = PromptSets.defaultId
    @Published var system = ""
    @Published var question = ""
    @Published var existing = ""
    @Published var vocabulary = ""
    @Published var context = ""
    @Published var setName = ""
    @Published fileprivate var externalTests: [String: String] = [:]
    @Published fileprivate var draft: ExternalDraft?
    @Published var remote: [SyncService.RemoteModel] = []
    @Published var remoteState = "idle"     // idle | loading | done
    private var wasDownloading = false
    private var loadedSet: String?

    /// Loads the texts of the set being edited (once per set; unsaved edits are kept otherwise).
    func ensureLoaded() {
        if PromptSets.find(editingSet) == nil { editingSet = PromptSets.defaultId; loadedSet = nil }
        guard loadedSet != editingSet, let s = PromptSets.find(editingSet) else { return }
        loadedSet = editingSet
        setName = s.name
        apply(s.prompt)
    }
    func reloadEditing() { loadedSet = nil; ensureLoaded() }

    private func apply(_ p: AIEngine.Prompt) {
        system = p.system; question = p.prompt; existing = p.existing; vocabulary = p.vocabulary; context = p.context
    }
    func restoreDefaults() { apply(AIEngine.Prompt.defaults) }

    fileprivate func binding(_ f: PromptField) -> Binding<String> {
        switch f {
        case .system: Binding(get: { self.system }, set: { self.system = $0 })
        case .question: Binding(get: { self.question }, set: { self.question = $0 })
        case .existing: Binding(get: { self.existing }, set: { self.existing = $0 })
        case .vocabulary: Binding(get: { self.vocabulary }, set: { self.vocabulary = $0 })
        case .context: Binding(get: { self.context }, set: { self.context = $0 })
        }
    }

    /// A model download that ended: a failure is said (the list is re-read elsewhere).
    func tick(_ window: NSWindow?) {
        let d = Core.modelStatus()
        if wasDownloading, d?.running == false, d?.finished != true, let e = d?.error, e != "已取消" { macAlert(window, "下载失败", e) }
        wasDownloading = d?.running ?? false
    }

    func loadRemote() {
        remoteState = "loading"
        SyncService.shared.remoteModels { [weak self] list in
            self?.remote = list
            self?.remoteState = "done"
        }
    }

    // MARK: Prompts

    func savePrompt(_ window: NSWindow?) {
        let p = AIEngine.Prompt(system: system, prompt: question, context: context, existing: existing, vocabulary: vocabulary)
        guard var set = PromptSets.find(editingSet) else { return }
        let n = setName.trimmingCharacters(in: .whitespaces)
        guard p != set.prompt || (!n.isEmpty && n != set.name) else { return }
        set.prompt = p
        if !n.isEmpty, set.id != PromptSets.defaultId { set.name = n }
        PromptSets.save(set)
        objectWillChange.send()
        let store = ModelStore.shared
        guard !store.taggerIds.isEmpty else { macAlert(window, "提示词已保存", "新的提示词会用于以后的所有打标签。"); return }
        macChoose(window, title: "提示词已保存", message: "新的提示词会用于以后的所有打标签。也可以现在就用它重新标记整个资料库（你添加或认可的标签都会保留）。",
                  options: ["仅对以后生效", "立即全部重新标记…"]) { [weak self] i in
            if i == 1 { self?.retagAll(window) }
        }
    }

    func newSet(_ window: NSWindow?) {
        macPrompt(window, title: "新建提示词", message: "从「默认」复制一份，再修改。", placeholder: "名称") { [weak self] name in
            let n = name.trimmingCharacters(in: .whitespaces)
            guard !n.isEmpty else { return }
            self?.editingSet = PromptSets.add(name: n, from: AIEngine.Prompt.load()).id
            self?.reloadEditing()
        }
    }

    func deleteSet(_ window: NSWindow?) {
        guard let s = PromptSets.find(editingSet), s.id != PromptSets.defaultId else { return }
        macChoose(window, title: "删除提示词「\(s.name)」？", message: "使用它的模型会改用「默认」。", options: ["删除"]) { [weak self] _ in
            PromptSets.delete(s.id)
            self?.editingSet = PromptSets.defaultId
            self?.reloadEditing()
        }
    }

    // MARK: Tagging and models

    func retagAll(_ window: NSWindow?) {
        let store = ModelStore.shared
        let ids = store.taggerIds
        guard !ids.isEmpty else { return }
        macChoose(window, title: "全部重新标记", message: "选择用哪个模型重新分析整个资料库。", options: ids.map { store.displayName($0) }) { i in
            let model = ids[i]
            macChoose(window, title: "旧的 AI 标签怎么处理？", message: "你添加的标签和已认可的 AI 标签都会保留。",
                      options: ["保留，只添加新标签", "删除未认可的旧 AI 标签"]) { j in
                AutoTagger.shared.retagAll(model: model, replaceOld: j == 1)
            }
        }
    }

    func download(_ m: CatalogModel, _ window: NSWindow?) {
        macChoose(window, title: "下载 \(m.displayName)？", message: "大小约 \(ActivityCenter.bytes(m.bytes))，将使用当前网络下载。", options: ["下载"]) { _ in
            do { try Core.downloadModel(m.repo) } catch { macAlert(window, "无法下载", error.localizedDescription) }
        }
    }

    func delete(_ m: Core.ModelInfo, _ window: NSWindow?) {
        macChoose(window, title: "删除 \(ModelStore.shared.displayName(m.id))？", message: "之后需要时要重新下载或导入。", options: ["删除"]) { _ in
            // stop using it, release it, then delete the files (gigabytes) off the main thread
            AutoTagger.shared.stop()
            Task {
                await AIEngine.shared.unloadAll()
                await MainActor.run {
                    macRun(window, { try Core.deleteModel(m.id) }) { _ in ModelStore.shared.reload(); AutoTagger.shared.startIfEnabled() }
                }
            }
        }
    }

    func export(_ m: Core.ModelInfo, _ window: NSWindow?) {
        macSavePanel(m.id + ".zip") { url in
            macRun(window, { try Core.exportModelZip(m.id, to: url) }) { macAlert(window, "已导出", url.lastPathComponent) }
        }
    }

    func importModel(_ window: NSWindow?) {
        macOpenPanel([.zip, .folder], directories: true) { u in
            macRun(window, { try Core.importModel(u) }) { m in ModelStore.shared.reload(); macAlert(window, "已导入", ModelStore.shared.displayName(m.id)) }
        }
    }

    // MARK: External models

    func test(_ e: ExternalModel) {
        externalTests[e.id] = "正在测试 \(e.title)…"
        Task { @MainActor [weak self] in
            let r: String
            do { let t = try await ExternalAI.test(e); r = "✓ 测试成功：" + (t.isEmpty ? "（没有返回标签）" : t.joined(separator: "、")) }
            catch { r = "✗ 测试失败：" + error.localizedDescription }
            self?.externalTests[e.id] = r
        }
    }

    func edit(_ e: ExternalModel) { draft = ExternalDraft(model: e, isNew: ExternalModels.find(e.id) == nil) }

    func deleteExternal(_ e: ExternalModel, _ window: NSWindow?) {
        macChoose(window, title: "删除外部模型「\(e.title)」？", message: "它加过的标签会保留。", options: ["删除"]) { [weak self] _ in
            ExternalModels.remove(e.id); ModelStore.shared.adoptInstalled(); self?.objectWillChange.send()
        }
    }
}

// MARK: - Page

struct ModelsPageView: View {
    @EnvironmentObject private var env: PaneEnv
    @StateObject private var live = LiveTick()
    @StateObject private var m = ModelsModel()
    @State private var field = PromptField.system
    private let grid = [GridItem(.adaptive(minimum: 250), spacing: 14, alignment: .top)]

    var body: some View {
        let _ = live.count
        let store = ModelStore.shared
        SettingsCanvas {
            runningCard
            hero(store)
            promptCard(store)
            installed(store)
            external(store)
            downloadable(store)
            remote(store)

            Card(spacing: 0) {
                CardRow(symbol: "square.and.arrow.down.fill", color: .green, title: "导入模型", detail: "可导入任意标准 MLX 模型文件夹或其 ZIP，避免重复下载。") {
                    Button("导入…") { m.importModel(env.window) }
                }
            }
        }
        .onAppear {
            live.onTick = { [weak m] in m?.tick(env.window) }
            live.start(every: 1)
            m.ensureLoaded()
            if m.remoteState == "idle", !SyncService.shared.reachablePeers.isEmpty { m.loadRemote() }
        }
        .onDisappear { live.stop() }
        .sheet(item: $m.draft) { d in ExternalEditor(draft: d) { m.draft = nil } }
    }

    // MARK: Blocks

    /// What is running (tagging, a model download), with the buttons that stop it.
    @ViewBuilder private var runningCard: some View {
        let acts = ActivityCenter.shared.activities.filter { $0.kind == .tagging || $0.kind == .model }
        if !acts.isEmpty {
            Card(tint: .accentColor, spacing: 14) {
                ForEach(acts) { ActivityRow(activity: $0) }
                HStack(spacing: 8) {
                    Spacer()
                    if acts.contains(where: { $0.kind == .tagging }) { Button("停止标记") { AutoTagger.shared.stop() } }
                    if acts.contains(where: { $0.kind == .model }) { Button("取消模型下载") { Core.cancelModelDownload() } }
                }
            }
        }
    }

    /// The tagging at a glance: a ring of how much is analysed, the switch, the default models.
    private func hero(_ store: ModelStore) -> some View {
        let c = AutoTagger.shared.counts
        let failures = Core.aiFailures()
        let value = c.total > 0 ? Double(c.done) / Double(c.total) : 0
        let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)
        return VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 22) {
                ZStack {
                    ProgressRing(value: value, lineWidth: 11, color: .purple)
                    VStack(spacing: 0) {
                        Text("\(Int((value * 100).rounded()))%").font(.system(size: 24, weight: .bold, design: .rounded)).monospacedDigit()
                        Text("已分析").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .frame(width: 104, height: 104)
                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("AI 打标签").font(.system(size: 20, weight: .bold, design: .rounded))
                        Text("\(c.done) / \(c.total) 个媒体已被分析").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    Toggle(isOn: Binding(get: { store.autoTag }, set: { store.autoTag = $0; if $0 { AutoTagger.shared.startIfEnabled() } })) {
                        Text("自动标记新媒体").font(.system(size: 13.5, weight: .medium))
                    }
                    .toggleStyle(.switch)
                    Text("只有尚未被任何模型分析过的媒体会被自动标记；更换默认模型不会重新标记。你添加或认可的标签永远不会被删除。")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: 12) {
                defaultPicker("打标签模型", symbol: "eye.fill", color: .purple, ids: store.taggerIds, selected: store.activeTaggerId, name: { store.displayName($0) }) { store.activeTaggerId = $0 }
                defaultPicker("语义搜索模型", symbol: "magnifyingglass", color: .teal, ids: store.embedders.map(\.id), selected: store.activeEmbedderId, name: { store.displayName($0) }) {
                    store.activeEmbedderId = $0; Task { await AutoTagger.shared.embedMissingLabels() }
                }
            }

            if let e = AutoTagger.shared.lastError { Banner(text: e, symbol: "exclamationmark.octagon.fill", color: .red) }
            if !failures.isEmpty {
                // shown, never dropped silently: which media, why, and a way to try again
                let reasons = Dictionary(grouping: failures, by: \.reason).sorted { $0.value.count > $1.value.count }
                HStack(alignment: .top, spacing: 10) {
                    Banner(text: "这台设备无法分析 \(failures.count) 个媒体：" + reasons.prefix(2).map { "\($0.value.count) 个 \($0.key)" }.joined(separator: "；") + "。同一账户里的其他设备仍会分析它们。")
                    VStack(spacing: 6) {
                        Button("详情…") {
                            let lines = failures.prefix(30).map { "\($0.mediaId.prefix(12))… · 试了 \($0.attempts) 次 · \($0.reason)" }
                            macAlert(env.window, "这台设备无法分析的媒体", (lines + (failures.count > 30 ? ["……还有 \(failures.count - 30) 个"] : [])).joined(separator: "\n")
                                     + "\n\n它们没有被标记为已分析：同一账户里的其他设备仍会分析它们，结果会同步回来。")
                        }
                        Button("重试") { Core.aiFailuresClear(); AutoTagger.shared.startIfEnabled(); NotificationCenter.default.post(name: AutoTagger.progressChanged, object: nil) }
                    }
                }
            }
            if !store.taggerIds.isEmpty {
                HStack { Spacer(); Button { m.retagAll(env.window) } label: { Label("全部重新标记…", systemImage: "arrow.triangle.2.circlepath") } }
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            shape.fill(LinearGradient(colors: [Color.purple.opacity(0.18), Color.indigo.opacity(0.08), Color.blue.opacity(0.05)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(shape.fill(Color(nsColor: .controlBackgroundColor).opacity(0.55)))
                .overlay(shape.strokeBorder(Color.primary.opacity(0.08)))
                .shadow(color: Color.purple.opacity(0.12), radius: 16, y: 6)
        }
    }

    private func defaultPicker(_ title: String, symbol: String, color: Color, ids: [String], selected: String?, name: @escaping (String) -> String, set: @escaping (String) -> Void) -> some View {
        HStack(spacing: 10) {
            IconTile(symbol: symbol, color: color, size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                if ids.isEmpty { Text("未安装").font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary) }
                else {
                    Picker("", selection: Binding(get: { selected ?? "" }, set: { if !$0.isEmpty { set($0) } })) {
                        if selected == nil { Text("未选择").tag("") }
                        ForEach(ids, id: \.self) { Text(name($0)).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.7), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: Prompts

    private func promptCard(_ store: ModelStore) -> some View {
        let sets = PromptSets.all
        let isDefault = m.editingSet == PromptSets.defaultId
        return VStack(alignment: .leading, spacing: 10) {
            SectionHeading("提示词", note: "可以建立多套提示词，每个模型（内置或外部）各用一套，在下面的模型卡片上选择；没有指定的用「默认」。提示词在设备之间同步。")
            Card(spacing: 14) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(sets, id: \.id) { s in
                            ChipButton(title: s.name, symbol: s.id == PromptSets.defaultId ? "star.fill" : "text.bubble", selected: m.editingSet == s.id) { m.editingSet = s.id; m.reloadEditing() }
                        }
                        ChipButton(title: "新建…", symbol: "plus", dashed: true) { m.newSet(env.window) }
                    }
                }
                .accessibilityIdentifier("promptSetPopup")
                if !isDefault {
                    HStack(spacing: 10) {
                        TextField("名称", text: $m.setName).textFieldStyle(.roundedBorder)
                        Button("删除这套", role: .destructive) { m.deleteSet(env.window) }
                    }
                }
                Picker("", selection: $field) {
                    ForEach(PromptField.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
                PlaceholderEditor(text: m.binding(field), placeholder: field.title, minHeight: 130)
                    .id(field)
                Text(field.note).font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Spacer()
                    Button("恢复默认") { m.restoreDefaults() }
                    Button("保存提示词") { m.savePrompt(env.window) }.buttonStyle(.borderedProminent)
                }
            }
        }
    }

    /// Which prompt set a model uses.
    private func promptMenu(for model: String) -> some View {
        Menu {
            Picker("提示词", selection: Binding(get: { PromptSets.setId(forModel: model) }, set: { PromptSets.assign($0, to: model); live.poke() })) {
                ForEach(PromptSets.all, id: \.id) { Text($0.name).tag($0.id) }
            }
            .pickerStyle(.inline)
        } label: {
            Label("提示词：" + (PromptSets.find(PromptSets.setId(forModel: model))?.name ?? "默认"), systemImage: "text.bubble")
        }
        .menuStyle(.borderlessButton).fixedSize()
        .accessibilityIdentifier("prompt-" + model)
    }

    // MARK: Models

    @ViewBuilder private func installed(_ store: ModelStore) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeading("已安装（\(store.installed.count)）", note: "标准 Hugging Face / MLX 文件夹格式（config.json、分词器与 .safetensors），可以多个并存。")
            if store.installed.isEmpty {
                Card { Text("尚未安装模型，从下面的「可下载」里选一个，或导入。").foregroundStyle(.secondary) }
            } else {
                LazyVGrid(columns: grid, spacing: 14) {
                    ForEach(store.installed, id: \.id) { mi in
                        let isDefault = mi.vision ? store.activeTaggerId == mi.id : store.activeEmbedderId == mi.id
                        Card(spacing: 12) {
                            HStack(alignment: .top, spacing: 10) {
                                IconTile(symbol: mi.vision ? "eye.fill" : "magnifyingglass", color: mi.vision ? .purple : .teal, size: 36)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(store.displayName(mi.id)).font(.system(size: 14, weight: .semibold)).lineLimit(2)
                                    HStack(spacing: 5) {
                                        Pill(text: mi.vision ? "看图打标签" : "语义搜索", color: mi.vision ? .purple : .teal)
                                        Pill(text: ActivityCenter.bytes(mi.bytes), color: .secondary)
                                    }
                                }
                                Spacer(minLength: 4)
                                Menu {
                                    Button("导出 ZIP…") { m.export(mi, env.window) }
                                    Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([mi.url]) }
                                    Divider()
                                    Button("删除…", role: .destructive) { m.delete(mi, env.window) }
                                } label: { Image(systemName: "ellipsis.circle").font(.system(size: 16)) }
                                    .menuStyle(.borderlessButton).fixedSize()
                            }
                            Spacer(minLength: 0)
                            HStack(spacing: 8) {
                                if mi.vision { promptMenu(for: mi.id) }
                                Spacer(minLength: 0)
                                if isDefault { Pill(text: "默认", color: .yellow, symbol: "star.fill") }
                                else {
                                    Button("设为默认") {
                                        if mi.vision { store.activeTaggerId = mi.id } else { store.activeEmbedderId = mi.id; Task { await AutoTagger.shared.embedMissingLabels() } }
                                    }
                                }
                            }
                        }
                        .frame(minHeight: 116)
                    }
                }
            }
        }
    }

    @ViewBuilder private func external(_ store: ModelStore) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeading("外部模型", note: "OpenAI 兼容接口（OpenAI、Grok、OpenRouter、Ollama、LM Studio 等）。只填地址是本地服务；填了 API Key 和模型名称是云端模型。模型列表在设备间同步，API Key 只保存在各自设备的钥匙串里。")
            LazyVGrid(columns: grid, spacing: 14) {
                ForEach(ExternalModels.all, id: \.id) { e in
                    Card(spacing: 10) {
                        HStack(alignment: .top, spacing: 10) {
                            IconTile(symbol: e.isLocal ? "desktopcomputer" : "cloud.fill", color: .blue, size: 36)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(e.title).font(.system(size: 14, weight: .semibold)).lineLimit(2)
                                HStack(spacing: 5) {
                                    Pill(text: e.kindLabel, color: .blue)
                                    if !e.host.isEmpty { Pill(text: e.host, color: .secondary) }
                                }
                                if !e.model.isEmpty { Text(e.model).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                            }
                            Spacer(minLength: 4)
                            Menu {
                                Button("测试") { m.test(e) }
                                Button("编辑…") { m.edit(e) }
                                Divider()
                                Button("删除…", role: .destructive) { m.deleteExternal(e, env.window) }
                            } label: { Image(systemName: "ellipsis.circle").font(.system(size: 16)) }
                                .menuStyle(.borderlessButton).fixedSize()
                        }
                        if let r = m.externalTests[e.id] { Text(r).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
                        Spacer(minLength: 0)
                        HStack(spacing: 8) {
                            promptMenu(for: e.id)
                            Spacer(minLength: 0)
                            if e.id == store.activeTaggerId { Pill(text: "默认", color: .yellow, symbol: "star.fill") }
                            else { Button("设为默认") { store.activeTaggerId = e.id } }
                        }
                    }
                    .frame(minHeight: 116)
                }
                Button { m.edit(.new()) } label: {
                    VStack(spacing: 8) {
                        Image(systemName: "plus.circle.fill").font(.system(size: 26)).foregroundStyle(.tint)
                        Text(ExternalModels.all.isEmpty ? "添加外部模型" : "再添加一个").font(.system(size: 13.5, weight: .medium))
                    }
                    .frame(maxWidth: .infinity, minHeight: 116)
                    .background(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Color.secondary.opacity(0.45), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder private func downloadable(_ store: ModelStore) -> some View {
        let catalog = ModelCatalog.all.filter { !store.isInstalled(repo: $0.repo) }
        if !catalog.isEmpty {
            let downloading = Core.modelStatus().flatMap { $0.running ? $0.repo : nil }
            let unfinished = Dictionary(Core.interruptedModels().map { ($0.repo, $0.bytes) }, uniquingKeysWith: max)
            let progress = ActivityCenter.shared.activities.first { $0.kind == .model }?.progress
            VStack(alignment: .leading, spacing: 10) {
                SectionHeading("可下载", note: "推荐：\(ModelCatalog.recommendedTagger.displayName)。全部为 MLX 4-bit，均不超过 14B。下载会使用当前网络。")
                LazyVGrid(columns: grid, spacing: 14) {
                    ForEach(catalog, id: \.repo) { cm in
                        let part = unfinished[cm.repo]
                        Card(spacing: 10) {
                            HStack(alignment: .top, spacing: 10) {
                                IconTile(symbol: "arrow.down.circle.fill", color: .teal, size: 36)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(cm.displayName).font(.system(size: 14, weight: .semibold)).lineLimit(2)
                                    Text(cm.note).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                }
                                Spacer(minLength: 4)
                                if cm.repo == ModelCatalog.recommendedTagger.repo { Pill(text: "推荐", color: .green, symbol: "hand.thumbsup.fill") }
                            }
                            Spacer(minLength: 0)
                            if downloading == cm.repo { SlimBar(value: progress ?? 0) }
                            HStack {
                                Text(part.map { "未完成 \(ActivityCenter.bytes($0)) / \(ActivityCenter.bytes(cm.bytes))" } ?? ActivityCenter.bytes(cm.bytes))
                                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                Spacer()
                                Button(downloading == cm.repo ? "下载中…" : part != nil ? "继续下载" : "下载") { m.download(cm, env.window) }
                                    .disabled(downloading != nil)
                            }
                        }
                        .frame(minHeight: 116)
                    }
                }
            }
        }
    }

    @ViewBuilder private func remote(_ store: ModelStore) -> some View {
        if SyncService.shared.hasAccount {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeading("其他设备上的模型", note: "模型不会自动同步。这里列出同一同步账户、当前在线的设备上有而本机没有的模型，点击「拉取」才会通过局域网传输，校验通过后安装。",
                               trailing: AnyView(Button("查询") { m.loadRemote() }.disabled(m.remoteState == "loading" || SyncService.shared.reachablePeers.isEmpty)))
                Card(spacing: 10) {
                    if m.remoteState == "loading" { Text("正在查询其他设备…").foregroundStyle(.secondary) }
                    else if m.remote.isEmpty {
                        Text(SyncService.shared.reachablePeers.isEmpty ? "没有在线的同账户设备" : (m.remoteState == "done" ? "其他设备上没有本机缺少的模型" : "点「查询」看看其他设备上有什么")).foregroundStyle(.secondary)
                    }
                    ForEach(m.remote, id: \.info.id) { r in
                        CardRow(symbol: "laptopcomputer.and.iphone", color: .indigo, title: store.displayName(r.info.id), detail: "\(r.peer.name) · \(ActivityCenter.bytes(r.info.bytes))") {
                            Button("拉取") {
                                do { try SyncService.shared.pull(r); m.remote.removeAll { $0 == r } }
                                catch { macAlert(env.window, "无法拉取", error.localizedDescription) }
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - External model editor

/// Add or edit an external model: name, address, key, model name.
private struct ExternalEditor: View {
    let draft: ExternalDraft
    let close: () -> Void
    @State private var name: String
    @State private var url: String
    @State private var key: String
    @State private var model: String
    @State private var error: String?

    init(draft: ExternalDraft, close: @escaping () -> Void) {
        self.draft = draft
        self.close = close
        _name = State(initialValue: draft.model.name)
        _url = State(initialValue: draft.model.url)
        _key = State(initialValue: draft.model.apiKey ?? "")
        _model = State(initialValue: draft.model.model)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                IconTile(symbol: "network", color: .blue, size: 40)
                VStack(alignment: .leading, spacing: 3) {
                    Text(draft.isNew ? "添加外部模型" : "编辑 \(draft.model.title)").font(.system(size: 17, weight: .semibold))
                    Text("只填地址 = 本地服务（模型名称不填时用服务上的第一个模型）。填了 API Key 和模型名称 = 云端模型。").font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(spacing: 10) {
                TextField("名称（可不填）", text: $name).accessibilityIdentifier("extName")
                TextField("例如 https://api.x.ai/v1 或 http://127.0.0.1:11434", text: $url).accessibilityIdentifier("extURL")
                SecureField("API Key（本地服务不填）", text: $key).accessibilityIdentifier("extKey")
                TextField("模型名称，例如 grok-2-vision（本地可不填）", text: $model).accessibilityIdentifier("extModel")
            }
            .textFieldStyle(.roundedBorder)
            if let error { Banner(text: error, symbol: "exclamationmark.triangle.fill", color: .red) }
            HStack {
                Spacer()
                Button("取消", role: .cancel) { close() }.keyboardShortcut(.cancelAction)
                Button("保存") { save() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
        }
        .padding(22)
        .frame(width: 460)
    }

    private func save() {
        var m = draft.model
        m.name = name.trimmingCharacters(in: .whitespaces)
        m.url = url.trimmingCharacters(in: .whitespaces)
        m.model = model.trimmingCharacters(in: .whitespaces)
        let k = key.trimmingCharacters(in: .whitespaces)
        guard !m.url.isEmpty, ExternalAI.endpoint(m.url, "models") != nil else { error = "请填写地址"; return }
        if !k.isEmpty, m.model.isEmpty { error = "云端模型需要填写模型名称"; return }
        m.apiKey = k.isEmpty ? nil : k
        ExternalModels.save(m)
        if ModelStore.shared.activeTaggerId == nil { ModelStore.shared.activeTaggerId = m.id }
        close()
    }
}
