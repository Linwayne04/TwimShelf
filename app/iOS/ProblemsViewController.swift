import UIKit

/// Recent warnings and errors (newest first), from the app log.
final class ProblemsViewController: FormViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        title = "问题记录"
        navigationItem.largeTitleDisplayMode = .never
        let list = AppLog.recentProblems()
        let f = DateFormatter(); f.dateFormat = "M月d日 HH:mm:ss"
        let rows: [Row] = list.isEmpty ? [.value("没有记录到问题", nil)] : list.enumerated().map { i, e in
            let l = UILabel()
            l.numberOfLines = 0
            let a = NSMutableAttributedString(string: "\(f.string(from: e.date)) · \(e.cat)\n", attributes: [.font: UIFont.preferredFont(forTextStyle: .caption1), .foregroundColor: e.level == .error ? UIColor.systemRed : UIColor.systemOrange])
            a.append(NSAttributedString(string: e.msg, attributes: [.font: UIFont.preferredFont(forTextStyle: .footnote)]))
            l.attributedText = a
            return .custom("p\(i)", l)
        }
        sections = [
            Section(id: "export", footer: Diagnostics.contents, rows: [
                .button("导出诊断信息…", icon: .init("stethoscope", .systemTeal), id: "b:diag2") { [weak self] in
                    (self?.navigationController?.viewControllers.first { $0 is ManageViewController } as? ManageViewController)?.exportDiagnostics() },
            ]),
            Section(id: "list", header: "最近 \(list.count) 条", rows: rows),
        ]
        reloadForm(animated: false)
    }
}
