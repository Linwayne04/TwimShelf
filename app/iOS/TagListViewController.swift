import UIKit

/// Every tag in the library with the number of media it is on (in total, added or endorsed by
/// you, from AI). Tap or long-press: show only this tag on the home screen, search it, put all
/// its media into a folder, rename it, or delete it. Tags whose media are all gone are not listed.
final class TagListViewController: UITableViewController, UISearchResultsUpdating {
    private var all: [TagCount] = []
    private var shown: [TagCount] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "标签"
        navigationItem.largeTitleDisplayMode = .never
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "t")
        tableView.accessibilityIdentifier = "tagList"
        let sc = UISearchController(searchResultsController: nil)
        sc.searchResultsUpdater = self
        sc.obscuresBackgroundDuringPresentation = false
        sc.searchBar.placeholder = "筛选标签"
        navigationItem.searchController = sc
        navigationItem.hidesSearchBarWhenScrolling = false
        let more = UIBarButtonItem(image: UIImage(systemName: "ellipsis.circle"), menu: UIMenu(children: [
            UIAction(title: "改名记录", image: UIImage(systemName: "clock.arrow.circlepath")) { [weak self] _ in
                self?.navigationController?.pushViewController(TagManagerViewController(), animated: true) },
            UIMenu(options: .displayInline, children: [
                UIAction(title: "删除全部 AI 标签…", image: UIImage(systemName: "sparkles"), attributes: .destructive) { [weak self] _ in self?.confirmRemoveAI() },
            ]),
        ]))
        more.accessibilityLabel = "更多"
        more.accessibilityIdentifier = "tagListMore"
        navigationItem.rightBarButtonItem = more
        load()
    }

    private func load() {
        DispatchQueue.global(qos: .userInitiated).async {
            let tags = Core.allTags()
            DispatchQueue.main.async { self.all = tags; self.filter(self.navigationItem.searchController?.searchBar.text ?? "") }
        }
    }

    func updateSearchResults(for sc: UISearchController) { filter(sc.searchBar.text ?? "") }
    private func filter(_ q: String) {
        let k = q.trimmingCharacters(in: .whitespaces).lowercased()
        shown = k.isEmpty ? all : all.filter { $0.label.contains(k) }
        tableView.reloadData()
    }

    override func tableView(_ tv: UITableView, titleForHeaderInSection section: Int) -> String? {
        all.isEmpty ? nil : "共 \(all.count) 个标签 · 长按可改名、删除等"
    }
    override func tableView(_ tv: UITableView, numberOfRowsInSection section: Int) -> Int { shown.count }
    override func tableView(_ tv: UITableView, cellForRowAt ip: IndexPath) -> UITableViewCell {
        let c = tv.dequeueReusableCell(withIdentifier: "t", for: ip)
        let t = shown[ip.row]
        var cfg = UIListContentConfiguration.valueCell()
        cfg.text = t.label
        cfg.secondaryText = "\(t.count) 个媒体"
        cfg.image = UIImage(systemName: t.user > 0 ? "tag.fill" : "sparkles")
        cfg.imageProperties.tintColor = t.user > 0 ? .systemBlue : .systemPurple
        var detail = UIListContentConfiguration.subtitleCell()
        detail.text = t.label
        detail.secondaryText = "共 \(t.count) 个媒体 · 我的 \(t.user) · AI \(t.ai)"
        detail.secondaryTextProperties.color = .secondaryLabel
        detail.image = cfg.image
        detail.imageProperties.tintColor = cfg.imageProperties.tintColor
        c.contentConfiguration = detail
        c.accessibilityIdentifier = "tagRow-\(t.label)"
        c.accessoryType = .disclosureIndicator
        return c
    }

    override func tableView(_ tv: UITableView, didSelectRowAt ip: IndexPath) {
        tv.deselectRow(at: ip, animated: true)
        showOnHome(shown[ip.row].label)
    }

    override func tableView(_ tv: UITableView, contextMenuConfigurationForRowAt ip: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
        let t = shown[ip.row]
        return UIContextMenuConfiguration(actionProvider: { [weak self] _ in
            UIMenu(title: "\(t.label)（\(t.count) 个媒体）", children: [
                UIAction(title: "在主页只看此标签", image: UIImage(systemName: "line.3.horizontal.decrease.circle")) { _ in self?.showOnHome(t.label) },
                UIAction(title: "全部加入文件夹…", image: UIImage(systemName: "folder.badge.plus")) { _ in self?.toFolder(t) },
                UIAction(title: "重命名或合并…", image: UIImage(systemName: "pencil")) { _ in self?.rename(t) },
                UIMenu(options: .displayInline, children: [
                    UIAction(title: "删除标签…", image: UIImage(systemName: "trash"), attributes: .destructive) { _ in self?.confirmDelete(t) },
                ]),
            ])
        })
    }

    /// Back to the home screen, showing only media with this tag.
    private func showOnHome(_ label: String) {
        NotificationCenter.default.post(name: FeedViewController.showLabelNote, object: label)
        navigationController?.popToRootViewController(animated: true)
        navigationController?.presentingViewController?.dismiss(animated: true)
    }

    private func toFolder(_ t: TagCount) {
        let a = UIAlertController(title: "把「\(t.label)」的 \(t.count) 个媒体放入文件夹", message: nil, preferredStyle: .actionSheet)
        let put: (String) -> Void = { [weak self] name in
            do {
                let n = try Core.tagToFolder(t.label, folder: name)
                NotificationCenter.default.post(name: .libraryChanged, object: nil)
                let ok = UIAlertController(title: "已放入「\(name)」", message: n == t.count ? "\(n) 个媒体" : "新加入 \(n) 个媒体（其余的已经在里面）", preferredStyle: .alert)
                ok.addAction(UIAlertAction(title: "好", style: .default))
                self?.present(ok, animated: true)
            } catch { AppLog.error("tags", "放入文件夹失败：\(error.localizedDescription)") }
        }
        for f in Core.folders() { a.addAction(UIAlertAction(title: "\(f.name)（\(f.count)）", style: .default) { _ in put(f.name) }) }
        a.addAction(UIAlertAction(title: "新建文件夹…", style: .default) { [weak self] _ in
            let n = UIAlertController(title: "新建文件夹", message: nil, preferredStyle: .alert)
            n.addTextField { $0.placeholder = "文件夹名称"; $0.text = t.label }
            n.addAction(UIAlertAction(title: "取消", style: .cancel))
            n.addAction(UIAlertAction(title: "创建并放入", style: .default) { _ in
                let name = (n.textFields?.first?.text ?? "").trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { put(name) }
            })
            self?.present(n, animated: true)
        })
        a.addAction(UIAlertAction(title: "取消", style: .cancel))
        a.popoverPresentationController?.sourceView = view
        a.popoverPresentationController?.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
        present(a, animated: true)
    }

    /// Every AI tag goes; tags I added or endorsed stay.
    private func confirmRemoveAI() {
        let n = all.reduce(0) { $0 + $1.ai }
        guard n > 0 else {
            let a = UIAlertController(title: "没有 AI 标签", message: nil, preferredStyle: .alert)
            a.addAction(UIAlertAction(title: "好", style: .default))
            return present(a, animated: true)
        }
        let a = UIAlertController(title: "删除全部 \(n) 个 AI 标签？", message: "只有 AI 加的标签会消失；你认可过的会保留为你的标签。会同步到其他设备，无法撤销。AI 不会自动重新分析这些媒体，需要时可以在「AI 模型」里重新标记。", preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "取消", style: .cancel))
        a.addAction(UIAlertAction(title: "删除 AI 标签", style: .destructive) { [weak self] _ in
            do {
                try Core.removeAITags()
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                NotificationCenter.default.post(name: .libraryChanged, object: nil)
                ActivityCenter.shared.refreshStats()
                self?.load()
            } catch {
                AppLog.error("tags", "删除 AI 标签失败：\(error.localizedDescription)")
                let e = UIAlertController(title: "无法删除 AI 标签", message: error.localizedDescription, preferredStyle: .alert)
                e.addAction(UIAlertAction(title: "好", style: .default))
                self?.present(e, animated: true)
            }
        })
        present(a, animated: true)
    }

    /// The tag goes from every media; the media stay.
    private func confirmDelete(_ t: TagCount) {
        let a = UIAlertController(title: "删除标签「\(t.label)」？",
                                  message: "会从 \(t.count) 个媒体上去掉这个标签（我加的和 AI 加的都去掉），并同步到其他设备。媒体本身不会删除。",
                                  preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "取消", style: .cancel))
        a.addAction(UIAlertAction(title: "删除标签", style: .destructive) { [weak self] _ in
            do {
                try Core.deleteTag(t.label)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                NotificationCenter.default.post(name: .libraryChanged, object: nil)
                ActivityCenter.shared.refreshStats()
                self?.load()
            } catch {
                AppLog.error("tags", "删除标签失败：\(error.localizedDescription)")
                let e = UIAlertController(title: "无法删除标签", message: error.localizedDescription, preferredStyle: .alert)
                e.addAction(UIAlertAction(title: "好", style: .default))
                self?.present(e, animated: true)
            }
        })
        present(a, animated: true)
    }

    private func rename(_ t: TagCount) {
        let a = UIAlertController(title: "重命名「\(t.label)」", message: "改成已有的标签名即为合并。可以在「改名记录」里撤销。", preferredStyle: .alert)
        a.addTextField { $0.text = t.label }
        a.addAction(UIAlertAction(title: "取消", style: .cancel))
        a.addAction(UIAlertAction(title: "重命名", style: .default) { [weak self] _ in
            let to = (a.textFields?.first?.text ?? "").trimmingCharacters(in: .whitespaces)
            guard !to.isEmpty, to != t.label else { return }
            _ = try? Core.renameTag(t.label, to: to)
            NotificationCenter.default.post(name: .libraryChanged, object: nil)
            self?.load()
        })
        present(a, animated: true)
    }
}
