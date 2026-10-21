import AppKit

/// "导入 TwimShelf" in the Share menu (Photos, Finder…): hands the shared photos, videos
/// and folders to the app as loose media, then opens the app, which imports them and records
/// every file's result.
final class ShareViewController: NSViewController {
    private let collector = ShareCollector()
    private let detail = NSTextField(wrappingLabelWithString: "作为散装媒体导入（没有帖子正文和作者）")
    private let bar = NSProgressIndicator()
    private let button = NSButton(title: "取消", target: nil, action: nil)
    private var finished = false
    private var started = false

    override func loadView() {
        let title = NSTextField(labelWithString: "导入到 TwimShelf")
        title.font = .boldSystemFont(ofSize: 14)
        detail.textColor = .secondaryLabelColor
        detail.preferredMaxLayoutWidth = 320
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 1
        bar.style = .bar
        button.target = self
        button.action = #selector(buttonClicked)
        button.keyEquivalent = "\r"
        let st = NSStackView(views: [title, bar, detail, button])
        st.orientation = .vertical
        st.alignment = .centerX
        st.spacing = 12
        st.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        bar.widthAnchor.constraint(equalToConstant: 320).isActive = true
        view = st
        preferredContentSize = NSSize(width: 360, height: 200)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        guard !started else { return }
        started = true
        let providers = ShareCollector.providers(extensionContext)
        Task { [weak self] in
            guard let self else { return }
            do {
                let r = try await self.collector.run(providers) { p in
                    Task { @MainActor [weak self] in
                        self?.bar.doubleValue = p.total == 0 ? 0 : Double(p.done) / Double(p.total)
                        self?.detail.stringValue = "正在交给 TwimShelf：\(p.done) / \(p.total)" + (p.current.map { "\n\($0)" } ?? "")
                    }
                }
                await MainActor.run { self.done(r) }
            } catch {
                await MainActor.run { self.fail(error) }
            }
        }
    }

    private func done(_ r: ShareCollector.Result) {
        if collector.cancelled { extensionContext?.cancelRequest(withError: CocoaError(.userCancelled)); return }
        finished = true
        bar.doubleValue = 1
        var t = r.files == 0 ? "没有可以导入的图片或视频。"
            : "已交给 TwimShelf：\(r.files) 个文件（\(ByteCountFormatter.string(fromByteCount: r.bytes, countStyle: .file))），正在打开 App 导入。每个文件的结果都会记在「导入记录」里。"
        if !r.skipped.isEmpty { t += "\n\n没有交出的 \(r.skipped.count) 项：\n" + r.skipped.prefix(8).joined(separator: "\n") }
        detail.stringValue = t
        button.title = "完成"
        // the app's own scheme (debug builds have a separate one, so a test build is never launched instead)
        let scheme = Bundle.main.object(forInfoDictionaryKey: "TLAppURLScheme") as? String ?? "twimshelf"
        if r.files > 0, let u = URL(string: "\(scheme)://share") { NSWorkspace.shared.open(u) }
    }

    private func fail(_ e: Error) {
        finished = true
        collector.discard()
        detail.stringValue = "没有完成：\(e.localizedDescription)"
        button.title = "关闭"
    }

    @objc private func buttonClicked() {
        if finished { extensionContext?.completeRequest(returningItems: nil); return }
        collector.cancel()
        detail.stringValue = "正在取消…"
        button.isEnabled = false
    }
}
