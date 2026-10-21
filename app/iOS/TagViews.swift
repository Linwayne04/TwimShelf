import UIKit

/// Quick tag adder opened by the "+" chip: type to filter existing tags (by popularity) or add
/// a new one; stays open so several tags can be added in a row.
final class TagPickerViewController: UITableViewController, UISearchBarDelegate {
    var onDone: (() -> Void)?
    private let media: FeedItem
    private var postScope: Core.MediaScope
    private var applyToPost = false
    private let search = UISearchBar()
    private let all = Core.allTags()
    private var added: [String] = []
    private var query = ""

    init(media: FeedItem, scope: Core.MediaScope, wholePost: Bool = false) {
        self.media = media
        self.postScope = scope
        applyToPost = wholePost
        super.init(style: .insetGrouped)
    }
    required init?(coder: NSCoder) { fatalError() }

    private var targetIDs: [String] { applyToPost ? postScope.ids : [media.mediaId] }
    private var existing: Set<String> { postScope.commonTags(targetIDs) }
    private var suggestions: [TagCount] {
        let q = query.lowercased()
        return all.filter { !existing.contains($0.label) && (q.isEmpty || $0.label.contains(q)) }.userFirst.prefix(40).map { $0 }
    }
    private var canCreate: Bool {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return !q.isEmpty && !all.contains { $0.label == q } && !existing.contains(q)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "添加标签"
        if postScope.pendingCount > 0 { navigationItem.prompt = "含 \(postScope.pendingCount) 个待下载媒体" }
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in self?.close() })
        navigationItem.rightBarButtonItem?.accessibilityIdentifier = "pickerDone"
        // Let the sheet's glass show through: no opaque bar or table backgrounds.
        search.searchBarStyle = .minimal
        search.backgroundImage = UIImage()
        tableView.backgroundColor = .clear
        view.backgroundColor = .clear
        search.placeholder = "输入或选择标签"
        search.delegate = self
        search.autocapitalizationType = .none
        search.returnKeyType = .done
        search.searchTextField.accessibilityIdentifier = "tagPickerField"
        search.sizeToFit()
        tableView.tableHeaderView = search
        tableView.keyboardDismissMode = .onDrag
        if !media.isLoose {
            let seg = UISegmentedControl(items: ["这张媒体", postScope.title])
            seg.selectedSegmentIndex = applyToPost ? 1 : 0
            seg.addAction(UIAction { [weak self] _ in self?.applyToPost = seg.selectedSegmentIndex == 1; self?.added = []; self?.tableView.reloadData() }, for: .valueChanged)
            navigationItem.titleView = seg
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        search.becomeFirstResponder()
    }

    private func close() {
        onDone?()
        dismiss(animated: true)
    }

    private func add(_ label: String) {
        let l = label.trimmingCharacters(in: .whitespaces).lowercased()
        guard !l.isEmpty, !existing.contains(l) else { return }
        do { try Core.action(.tag, media: applyToPost ? [] : [media.mediaId], posts: applyToPost ? [media.postId] : [], label: l) }
        catch {
            let a = UIAlertController(title: "无法添加标签", message: error.localizedDescription, preferredStyle: .alert)
            a.addAction(UIAlertAction(title: "好", style: .default)); present(a, animated: true); return
        }
        if let refreshed = try? Core.postScope(media.postId) { postScope = refreshed }
        (navigationItem.titleView as? UISegmentedControl)?.setTitle(postScope.title, forSegmentAt: 1)
        added.append(l)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        query = ""
        search.text = ""
        tableView.performBatchUpdates({ tableView.reloadSections(IndexSet(integersIn: 0..<3), with: .automatic) })
        NotificationCenter.default.post(name: .libraryChanged, object: nil)
    }

    func searchBar(_ searchBar: UISearchBar, textDidChange text: String) {
        query = text
        UIView.performWithoutAnimation { tableView.reloadSections(IndexSet(integersIn: 0..<3), with: .none) }
    }

    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        if !query.trimmingCharacters(in: .whitespaces).isEmpty { add(query) } else { close() }
    }

    override func numberOfSections(in tableView: UITableView) -> Int { 3 }
    override func tableView(_ tv: UITableView, numberOfRowsInSection s: Int) -> Int {
        switch s { case 0: canCreate ? 1 : 0; case 1: added.count; default: suggestions.count }
    }
    override func tableView(_ tv: UITableView, titleForHeaderInSection s: Int) -> String? {
        switch s { case 1: added.isEmpty ? nil : "刚刚添加"; case 2: suggestions.isEmpty ? nil : (query.isEmpty ? "常用标签" : "匹配的标签"); default: nil }
    }

    override func tableView(_ tv: UITableView, cellForRowAt ip: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
        var c = UIListContentConfiguration.valueCell()
        switch ip.section {
        case 0:
            c.text = "添加「\(query.trimmingCharacters(in: .whitespaces).lowercased())」"
            c.image = UIImage(systemName: "plus.circle.fill")
            c.textProperties.color = .tintColor
        case 1:
            c.text = added[ip.row]
            c.image = UIImage(systemName: "checkmark.circle.fill")
            c.imageProperties.tintColor = .systemGreen
            cell.selectionStyle = .none
        default:
            let t = suggestions[ip.row]
            c.text = t.label
            c.secondaryText = "\(postScope.taggedCount(t.label, ids: targetIDs))/\(targetIDs.count) 已添加"
            c.image = UIImage(systemName: t.ai > 0 && t.user == 0 ? "sparkles" : "tag")
        }
        cell.contentConfiguration = c
        return cell
    }

    override func tableView(_ tv: UITableView, didSelectRowAt ip: IndexPath) {
        tv.deselectRow(at: ip, animated: true)
        switch ip.section {
        case 0: add(query)
        case 2: add(suggestions[ip.row].label)
        default: break
        }
    }
}

/// Shows where each tag of a media came from: you, AI (and which models), or both.
final class TagSourcesViewController: UITableViewController {
    private let item: FeedItem

    init(item: FeedItem) {
        self.item = item
        super.init(style: .insetGrouped)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "标签来源"
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
    }

    override func tableView(_ tv: UITableView, numberOfRowsInSection s: Int) -> Int { item.tags.count }
    override func tableView(_ tv: UITableView, titleForFooterInSection s: Int) -> String? {
        "蓝色：你添加的 · 紫色：AI 添加的 · 绿色：AI 添加并经你认可的（同时属于你和 AI）。"
    }

    override func tableView(_ tv: UITableView, cellForRowAt ip: IndexPath) -> UITableViewCell {
        let t = item.tags[ip.row]
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        var c = UIListContentConfiguration.subtitleCell()
        c.text = t.label
        let who = t.isUser && t.isAI ? "我和 AI 共同" : (t.isAI ? "AI" : "我")
        let models = t.models.map { ModelStore.shared.displayName($0) }
        c.secondaryText = models.isEmpty ? who : "\(who) · \(models.joined(separator: "、"))"
        c.secondaryTextProperties.color = .secondaryLabel
        c.image = UIImage(systemName: t.isAI ? (t.isUser ? "checkmark.seal.fill" : "sparkles") : "person.fill")
        c.imageProperties.tintColor = TagChip.color(t)
        cell.contentConfiguration = c
        cell.selectionStyle = .none
        return cell
    }
}
