import UIKit

/// All tags with counts (tap to rename or merge) and the active renames (undo).
final class TagManagerViewController: FormViewController {
    private var observer: NSObjectProtocol?

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "标签"
        navigationItem.largeTitleDisplayMode = .never
        observer = NotificationCenter.default.addObserver(forName: .libraryChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.build() }
        }
        build()
    }
    deinit { observer.map(NotificationCenter.default.removeObserver) }

    private func build() {
        let tags = Core.allTags()
        let renames = Core.tagRenames()
        var s: [Section] = []
        if !renames.isEmpty {
            s.append(Section(id: "renames", header: "已改名", footer: "改名不会改写任何标签记录：旧名字的标签显示为新名字，正在进行的 AI 标记和其他设备也一样。撤销后旧名字重新单独显示。", rows: renames.map { r in
                .button("「\(r.old)」→「\(r.current)」  撤销", icon: .init("arrow.uturn.backward", .systemOrange), id: "u:" + r.old) { [weak self] in
                    try? Core.undoRename(r.old)
                    NotificationCenter.default.post(name: .libraryChanged, object: nil)
                    self?.build()
                }
            }))
        }
        s.append(Section(id: "tags", header: "全部标签（\(tags.count)）", footer: "点按标签可以重命名；改成已有的名字会把两个标签合并。", rows: tags.isEmpty ? [.value("还没有标签", nil)] : tags.prefix(2000).map { t in
            .navigation(t.label, detail: "\(t.count) 个" + (t.ai > 0 && t.user == 0 ? " · AI" : ""), icon: .init(t.user > 0 ? "tag.fill" : "sparkles", t.user > 0 ? .systemBlue : .systemPurple), id: "t:" + t.label) { [weak self] in
                self?.rename(t)
            }
        }))
        sections = s
        reloadForm()
    }

    private func rename(_ t: TagCount) {
        let a = UIAlertController(title: "重命名标签「\(t.label)」", message: "\(t.count) 个媒体会改用新名字；新名字已存在时两者合并。", preferredStyle: .alert)
        a.addTextField { $0.text = t.label; $0.clearButtonMode = .whileEditing }
        a.addAction(UIAlertAction(title: "取消", style: .cancel))
        a.addAction(UIAlertAction(title: "重命名", style: .default) { [weak self] _ in
            let new = (a.textFields?.first?.text ?? "").trimmingCharacters(in: .whitespaces)
            guard !new.isEmpty, new.lowercased() != t.label else { return }
            do { try Core.renameTag(t.label, to: new); NotificationCenter.default.post(name: .libraryChanged, object: nil); self?.build() }
            catch { self?.alert("无法重命名", error.localizedDescription) }
        })
        present(a, animated: true)
    }
}
