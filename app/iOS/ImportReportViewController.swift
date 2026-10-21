import UIKit

/// One import report: every file or folder that was not imported as a normal new media, with its
/// path inside the source, the reason, and what it matches. The files can be exported unchanged.
final class ImportReportViewController: FormViewController {
    private let report: ImportReport
    private let file: String

    init(report: ImportReport, file: String) { self.report = report; self.file = file; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "导入详情"
        navigationItem.largeTitleDisplayMode = .never
        let summary = UILabel()
        summary.numberOfLines = 0
        summary.font = .preferredFont(forTextStyle: .subheadline)
        summary.text = report.summary
        var s: [Section] = [Section(id: "summary", footer: report.source.map { "来源：" + URL(fileURLWithPath: $0).lastPathComponent }, rows: [.custom("summary", summary)])]
        if report.grouped.contains(where: { $0.items.contains(where: \.isFile) }) {
            s.append(Section(id: "export", footer: "把有问题的文件按类别原样放进一个 ZIP（不做任何改动），附「说明.txt」列出每一项的路径和原因。需要导入时的原文件还在。", rows: [
                .button("把这些文件原样导出…", icon: .init("square.and.arrow.up", .systemBlue)) { [weak self] in self?.export() },
            ]))
        }
        s.append(Section(id: "delete", footer: "删除这条记录。导入时 App 保存的来源副本（从「文件」选取时系统复制给 App 的 ZIP、分享时留下的问题文件）会一起删除，释放空间；删除后不能再从这里导出问题文件。", rows: [
            .button("删除这条导入记录…", icon: .init("trash", .systemRed), destructive: true, id: "b:deleteReport") { [weak self] in
                guard let self else { return }
                self.confirmDeleteImportReports([self.file], what: "这条导入记录") { [weak self] in self?.navigationController?.popViewController(animated: true) }
            },
        ]))
        for g in report.grouped {
            let rows: [Row] = g.items.prefix(500).enumerated().map { i, it in
                let l = UILabel()
                l.numberOfLines = 0
                let a = NSMutableAttributedString(string: it.path + "\n", attributes: [.font: UIFont.preferredFont(forTextStyle: .footnote).withTraits(.traitBold)])
                a.append(NSAttributedString(string: it.reason, attributes: [.font: UIFont.preferredFont(forTextStyle: .footnote), .foregroundColor: UIColor.secondaryLabel]))
                if let same = it.sameAs { a.append(NSAttributedString(string: "\n对应：" + same, attributes: [.font: UIFont.preferredFont(forTextStyle: .footnote), .foregroundColor: UIColor.secondaryLabel])) }
                l.attributedText = a
                return .custom("\(g.category)-\(i)", l)
            }
            s.append(Section(id: g.category, header: "\(ImportIssue.title(g.category))（\(g.items.count)）",
                             footer: g.items.count > 500 ? "只列出前 500 项；导出的 ZIP 和说明.txt 包含全部。" : nil, rows: rows))
        }
        sections = s
        reloadForm(animated: false)
    }

    private func export() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("import-issues", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let out = dir.appendingPathComponent("导入问题文件.zip")
        runBusy("正在导出…", { try Core.exportImportIssues(report: self.file, to: out) }) { [weak self] _ in
            guard let self else { return }
            let share = UIActivityViewController(activityItems: [out], applicationActivities: nil)
            share.popoverPresentationController?.sourceView = self.view
            share.popoverPresentationController?.sourceRect = CGRect(x: self.view.bounds.midX, y: 120, width: 1, height: 1)
            share.completionWithItemsHandler = { _, _, _, _ in try? FileManager.default.removeItem(at: dir) }
            self.present(share, animated: true)
        }
    }
}

/// Saved import reports, newest first.
final class ImportHistoryViewController: FormViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        title = "导入记录"
        navigationItem.largeTitleDisplayMode = .never
    }
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        build()
    }

    private func build() {
        let f = DateFormatter(); f.dateFormat = "M月d日 HH:mm"
        let list = Core.importReports()
        sections = [Section(id: "list", footer: "每次导入都会记下每个没有正常导入的文件和文件夹。", rows: list.isEmpty ? [.value("还没有导入记录", nil)] : list.map { r in
            .navigation(f.string(from: r.date) + " · " + URL(fileURLWithPath: r.source).lastPathComponent, detail: r.issues == 0 ? "全部正常" : "\(r.issues) 项",
                        icon: .init(r.issues == 0 ? "checkmark.circle" : "exclamationmark.circle", r.issues == 0 ? .systemGreen : .systemOrange), id: "r:" + r.file) { [weak self] in
                guard let rep = try? Core.importReport(r.file) else { return }
                self?.navigationController?.pushViewController(ImportReportViewController(report: rep, file: r.file), animated: true)
            }
        })]
        if !list.isEmpty {
            sections.append(Section(id: "deleteAll", rows: [
                .button("删除全部导入记录…", icon: .init("trash", .systemRed), destructive: true, id: "b:deleteAllReports") { [weak self] in
                    self?.confirmDeleteImportReports(list.map(\.file), what: "全部 \(list.count) 条导入记录") { self?.build() }
                },
            ]))
        }
        reloadForm(animated: false)
    }
}

extension UIViewController {
    /// Deletes import records after a confirmation; the app's own copies of their sources go too.
    func confirmDeleteImportReports(_ files: [String], what: String, done: @escaping () -> Void) {
        let a = UIAlertController(title: "删除\(what)？", message: "删除后无法再查看，也不能再导出其中的问题文件。App 里保存的来源副本会一起删除；你在「文件」里的原始文件不受影响。", preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "取消", style: .cancel))
        a.addAction(UIAlertAction(title: "删除", style: .destructive) { [weak self] _ in
            do {
                let r = try Core.deleteImportReports(files, owned: ShareInbox.ownedRoots)
                let msg = r.sources > 0 ? "同时删除了 \(r.sources) 份 App 内保存的来源副本，共释放 \(ActivityCenter.bytes(r.bytes))" : "释放 \(ActivityCenter.bytes(r.bytes))"
                let ok = UIAlertController(title: "已删除 \(r.reports) 条记录", message: msg, preferredStyle: .alert)
                ok.addAction(UIAlertAction(title: "好", style: .default) { _ in done() })
                self?.present(ok, animated: true)
            } catch {
                let e = UIAlertController(title: "删除失败", message: error.localizedDescription, preferredStyle: .alert)
                e.addAction(UIAlertAction(title: "好", style: .cancel))
                self?.present(e, animated: true)
            }
        })
        present(a, animated: true)
    }
}

extension UIFont {
    func withTraits(_ t: UIFontDescriptor.SymbolicTraits) -> UIFont {
        fontDescriptor.withSymbolicTraits(t).map { UIFont(descriptor: $0, size: pointSize) } ?? self
    }
}

extension UIViewController {
    /// Import finished: summary, with the details one tap away when something needs attention.
    func showImportResult(_ r: ImportReport, extra: String = "") {
        let a = UIAlertController(title: "导入完成", message: r.summary + extra, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "好", style: .cancel))
        if let f = r.reportFile, !(r.issues ?? []).isEmpty {
            a.addAction(UIAlertAction(title: "查看详情…", style: .default) { [weak self] _ in
                let vc = ImportReportViewController(report: r, file: f)
                if let nav = (self as? UINavigationController) ?? self?.navigationController { nav.pushViewController(vc, animated: true) }
                else { self?.present(UINavigationController(rootViewController: vc), animated: true) }
            })
        }
        present(a, animated: true)
    }
}
