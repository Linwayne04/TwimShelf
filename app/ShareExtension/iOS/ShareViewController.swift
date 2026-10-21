import UIKit

/// "导入 TwimShelf" in the share sheet (Photos, Files…): hands the shared photos and
/// videos to the app as loose media. The app imports them the next time it is active (right
/// away when it is already running) and records every file's result.
final class ShareViewController: UIViewController {
    private let collector = ShareCollector()
    private let titleLabel = UILabel()
    private let detail = UILabel()
    private let bar = UIProgressView(progressViewStyle: .default)
    private let button = UIButton(type: .system)
    private var finished = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        titleLabel.text = "导入到 TwimShelf"
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        detail.font = .preferredFont(forTextStyle: .subheadline)
        detail.textColor = .secondaryLabel
        detail.numberOfLines = 0
        detail.textAlignment = .center
        detail.text = "作为散装媒体导入（没有帖子正文和作者）"
        button.setTitle("取消", for: .normal)
        button.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        button.addAction(UIAction { [weak self] _ in self?.buttonTapped() }, for: .touchUpInside)
        let icon = UIImageView(image: UIImage(systemName: "square.and.arrow.down.on.square.fill"))
        icon.tintColor = .systemBlue
        icon.preferredSymbolConfiguration = .init(pointSize: 40, weight: .regular)
        let st = UIStackView(arrangedSubviews: [icon, titleLabel, bar, detail, button])
        st.axis = .vertical
        st.alignment = .center
        st.spacing = 16
        st.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(st)
        NSLayoutConstraint.activate([
            st.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            st.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor, constant: 12),
            st.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor, constant: -12),
            bar.widthAnchor.constraint(equalTo: st.widthAnchor),
        ])
    }

    private var started = false

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // viewDidAppear can run again (a sheet over it, rotation): start the copy only once
        guard !finished, !started else { return }
        started = true
        let providers = ShareCollector.providers(extensionContext)
        Task { [weak self] in
            guard let self else { return }
            do {
                let r = try await self.collector.run(providers) { p in
                    Task { @MainActor [weak self] in
                        self?.bar.setProgress(p.total == 0 ? 0 : Float(p.done) / Float(p.total), animated: true)
                        self?.detail.text = "正在交给 TwimShelf：\(p.done) / \(p.total)" + (p.current.map { "\n\($0)" } ?? "")
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
        bar.setProgress(1, animated: true)
        var t: String
        if r.files == 0 {
            t = "没有可以导入的图片或视频。"
        } else {
            t = "已交给 TwimShelf：\(r.files) 个文件（\(ByteCountFormatter.string(fromByteCount: r.bytes, countStyle: .file))）。\n打开 TwimShelf 后会自动导入为散装媒体，每个文件的结果都会记在「导入记录」里。"
        }
        if !r.skipped.isEmpty { t += "\n\n没有交出的 \(r.skipped.count) 项：\n" + r.skipped.prefix(8).joined(separator: "\n") }
        detail.text = t
        button.setTitle("完成", for: .normal)
    }

    private func fail(_ e: Error) {
        finished = true
        collector.discard()
        detail.text = "没有完成：\(e.localizedDescription)"
        button.setTitle("关闭", for: .normal)
    }

    private func buttonTapped() {
        if finished { extensionContext?.completeRequest(returningItems: nil); return }
        collector.cancel()
        detail.text = "正在取消…"
        button.isEnabled = false
    }
}
