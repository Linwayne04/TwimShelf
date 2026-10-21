import UIKit

extension UIViewController {
    /// Asks where an import or download should go: no folder, a new folder (suggested name), or
    /// an existing one. `done(nil)` = no folder.
    func chooseTargetFolder(title: String, suggested: String?, done: @escaping (String?) -> Void) {
        let a = UIAlertController(title: title, message: "涉及的每个帖子（包括资料库里已有的部分）都会放进这个文件夹。", preferredStyle: .actionSheet)
        a.addAction(UIAlertAction(title: "不放入文件夹", style: .default) { _ in done(nil) })
        if let s = suggested, !s.isEmpty { a.addAction(UIAlertAction(title: "新文件夹「\(s)」", style: .default) { _ in done(s) }) }
        for f in Core.folders().prefix(8) { a.addAction(UIAlertAction(title: "「\(f.name)」", style: .default) { _ in done(f.name) }) }
        a.addAction(UIAlertAction(title: "取消", style: .cancel))
        anchorSheet(a)
        present(a, animated: true)
    }

    /// Where a sheet that is shown as a bubble points: at the row of a form that was just tapped, or
    /// at the middle of the page. (A sheet pointing at the middle covered the very rows it was about.)
    func anchorSheet(_ sheet: UIViewController) {
        guard let pc = sheet.popoverPresentationController else { return }
        pc.sourceView = view
        if let row = (self as? FormViewController)?.tappedRowRect {
            pc.sourceRect = row
            pc.permittedArrowDirections = [.up, .down]
        } else {
            pc.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
        }
    }
}
