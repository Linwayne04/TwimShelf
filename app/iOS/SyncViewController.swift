import UIKit

/// Six digit tiles with a draining countdown bar. Updated in place (no list reloads), so the
/// one-second countdown never makes the screen stutter.
final class PairingCodeView: UIView {
    private let tiles: [UILabel] = (0..<6).map { _ in UILabel() }
    private let bar = SlimProgressBar()
    private let caption = UILabel()
    private(set) var code: String?

    override init(frame: CGRect) {
        super.init(frame: frame)
        let row = UIStackView(arrangedSubviews: tiles)
        row.spacing = 8
        row.distribution = .fillEqually
        for t in tiles {
            t.font = .monospacedDigitSystemFont(ofSize: 34, weight: .bold).rounded
            t.textAlignment = .center
            t.backgroundColor = UIColor.tintColor.withAlphaComponent(0.12)
            t.textColor = .tintColor
            t.layer.cornerRadius = 12
            t.layer.cornerCurve = .continuous
            t.clipsToBounds = true
            t.heightAnchor.constraint(equalToConstant: 58).isActive = true
        }
        caption.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        caption.textColor = .secondaryLabel
        caption.textAlignment = .center
        let st = UIStackView(arrangedSubviews: [row, bar, caption])
        st.axis = .vertical
        st.spacing = 12
        st.translatesAutoresizingMaskIntoConstraints = false
        addSubview(st)
        NSLayoutConstraint.activate([st.topAnchor.constraint(equalTo: topAnchor, constant: 8), st.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
                                     st.leadingAnchor.constraint(equalTo: leadingAnchor), st.trailingAnchor.constraint(equalTo: trailingAnchor),
                                     bar.heightAnchor.constraint(equalToConstant: 4)])
        accessibilityIdentifier = "pairingCode"
        isAccessibilityElement = true
    }
    required init?(coder: NSCoder) { fatalError() }

    func update(code: String, secondsLeft: UInt64) {
        if code != self.code {
            self.code = code
            accessibilityLabel = code
            for (i, t) in tiles.enumerated() {
                t.text = String(Array(code)[safe: i] ?? " ")
                t.transform = CGAffineTransform(scaleX: 0.6, y: 0.6)
                t.alpha = 0
                UIView.animate(withDuration: 0.45, delay: Double(i) * 0.05, usingSpringWithDamping: 0.6, initialSpringVelocity: 0.8) {
                    t.transform = .identity; t.alpha = 1
                }
            }
        }
        bar.set(Double(secondsLeft) / 300)
        caption.text = String(format: "%d:%02d 后失效 · 最多尝试 5 次", Int(secondsLeft) / 60, Int(secondsLeft) % 60)
        accessibilityValue = caption.text
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

/// LAN sync: create an account, admit devices with a 6-digit code, or join one.
final class SyncViewController: FormViewController {
    private var observers: [NSObjectProtocol] = []
    private let codeView = PairingCodeView()
    private let stats = StatsCardView()
    private var joining = false
    private var countdown: Timer?

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "局域网同步"
        navigationItem.largeTitleDisplayMode = .never
        observers = [SyncService.changed, ActivityCenter.changed].map {
            NotificationCenter.default.addObserver(forName: $0, object: nil, queue: .main) { [weak self] _ in self?.tick() }
        }
        countdown = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.updateCode() }
        build()
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver); countdown?.invalidate() }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if SyncService.shared.status?.pairingCode != nil { SyncService.shared.cancelPairing() }
    }

    private func tick() {
        let svc = SyncService.shared
        if joining, let j = svc.status?.join, !j.running {
            joining = false
            if svc.adoptJoinResultIfAny() {
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                alert("已加入", "这台设备会自动与同一账户的其他设备同步。")
            } else if let e = j.error {
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                alert("加入失败", e)
            }
        }
        build()
    }

    /// Countdown: touches only the code view.
    private func updateCode() {
        guard let st = SyncService.shared.status, let code = st.pairingCode else { return }
        let left = max(0, Int(st.pairingSecondsLeft ?? 0) - Int(Date().timeIntervalSince(lastStatusAt)))
        codeView.update(code: code, secondsLeft: UInt64(left))
    }
    private var lastStatusAt = Date()

    private func ago(_ t: UInt64) -> String {
        guard t > 0 else { return "从未" }
        let s = Int(Date().timeIntervalSince1970) - Int(t)
        return s < 60 ? "刚刚" : s < 3600 ? "\(s / 60) 分钟前" : s < 86400 ? "\(s / 3600) 小时前" : "\(s / 86400) 天前"
    }

    private func build() {
        let svc = SyncService.shared
        let st = svc.status
        lastStatusAt = Date()
        stats.update(ActivityCenter.shared.stats)
        var s: [Section] = []
        if svc.localNetworkDenied {
            s.append(Section(id: "denied", header: "无法访问本地网络", footer: "TwimShelf 没有「本地网络」权限，无法发现和连接其他设备。请在「设置 › 隐私与安全性 › 本地网络」中打开 TwimShelf，然后回到这里。", rows: [
                .button("打开设置", icon: .init("gear", .systemRed), id: "b:settings") { UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!) },
            ]))
        }

        if let n = ActivityCenter.shared.stats?.newerOps, n > 0 {
            s.append(Section(id: "newer", header: "请更新这台设备", footer: LibraryStats.newerOpsText, rows: [
                .value("待生效的同步记录", "\(n) 条", icon: .init("arrow.up.circle.fill", .systemOrange), id: "newerOps")]))
        }
        if svc.hasAccount, let acct = st?.accountId {
            s.append(Section(id: "me", header: "本机", rows: [
                .custom("stats", stats),
                .value("设备", st?.deviceName, icon: .init("laptopcomputer.and.iphone", .systemBlue)),
                .value("账户", String(acct.prefix(8)).uppercased(), icon: .init("person.badge.key.fill", .systemIndigo)),
                .value("状态", (st?.syncing ?? 0) > 0 ? "正在同步…" : "空闲", icon: .init("arrow.triangle.2.circlepath", .systemTeal), id: "status"),
                .button("立即同步", icon: .init("arrow.clockwise", .systemGreen)) { svc.syncNow() },
            ] + (svc.note.map { [.value($0, nil, icon: .init("info.circle", .systemGray), id: "syncNote")] } ?? [])))
            if let code = st?.pairingCode {
                codeView.update(code: code, secondsLeft: st?.pairingSecondsLeft ?? 0)
                s.append(Section(id: "pair", header: "添加新设备", footer: "在新设备上打开「局域网同步」，选择这台设备并输入上面的验证码。", rows: [
                    .custom("code", codeView),
                    .button("取消", icon: .init("xmark", .systemRed), destructive: true) { svc.cancelPairing() },
                ]))
            } else {
                s.append(Section(id: "pair", header: "添加新设备", rows: [
                    .button("显示验证码…", icon: .init("plus.viewfinder", .systemBlue)) { _ = svc.beginPairing(); svc.refreshStatus() }]))
            }
            let mine = svc.peers.values.filter { $0.account == acct }.sorted { $0.name < $1.name }
            let known = st?.peers ?? []
            var rows: [Row] = mine.map { p in
                let info = known.first { $0.device == p.device }
                var detail = "在线 · " + (info.map { $0.lastError == nil ? "同步于" + self.ago($0.lastSync) : "出错" } ?? "等待同步")
                if let skew = info?.skewText { detail += " · ⚠︎ " + skew }
                return .value(p.name, detail, icon: .init(info?.skewText == nil ? "checkmark.icloud.fill" : "clock.badge.exclamationmark.fill", info?.skewText == nil ? .systemGreen : .systemOrange), id: "peer-\(p.device)")
            }
            for k in known where !mine.contains(where: { $0.device == k.device }) {
                rows.append(.value(k.name, "离线 · 上次同步" + ago(k.lastSync), icon: .init("icloud.slash.fill", .systemGray), id: "peer-\(k.device)"))
            }
            if rows.isEmpty { rows = [.value("暂无其他设备", nil, icon: .init("wifi", .systemGray))] }
            s.append(Section(id: "peers", header: "账户中的设备", footer: "同一账户的设备在局域网中自动发现并互相同步帖子、媒体、标签及其来源。没有中心设备，任意一台离线后再上线都会追上。", rows: rows))
            s.append(Section(id: "leave", footer: "仅让这台设备停止同步，不删除任何数据，也不影响其他设备。", rows: [
                .button("退出同步账户", icon: .init("rectangle.portrait.and.arrow.right", .systemRed), destructive: true) { [weak self] in self?.confirmLeave() }]))
        } else {
            s.append(Section(id: "create", header: "第一台设备", footer: "在第一台设备上创建同步账户，然后用它给其他设备显示验证码。", rows: [
                .button("创建同步账户", icon: .init("person.crop.circle.badge.plus", .systemBlue)) { svc.createAccount() }]))
            let joinable = svc.peers.values.filter { $0.account != nil }.sorted { $0.name < $1.name }
            var rows: [Row] = joinable.map { p in
                .navigation(p.name, detail: p.host == nil ? "正在解析…" : "加入", icon: .init("desktopcomputer", .systemIndigo), id: "join-\(p.device)") { [weak self] in self?.promptCode(p) }
            }
            if joining { rows.insert(.value("正在配对…", nil, icon: .init("hourglass", .systemOrange), id: "joining"), at: 0) }
            if rows.isEmpty { rows = [.value("正在局域网中查找设备…", nil, icon: .init("dot.radiowaves.left.and.right", .systemTeal))] }
            s.append(Section(id: "join", header: "加入已有账户", footer: "先在已加入账户的设备上点「显示验证码」。", rows: rows))
        }
        sections = s
        reloadForm()
    }

    private func promptCode(_ p: SyncService.Peer) {
        let a = UIAlertController(title: "加入「\(p.name)」的账户", message: "输入那台设备上显示的 6 位验证码", preferredStyle: .alert)
        a.addTextField { $0.keyboardType = .numberPad; $0.placeholder = "000000"; $0.textContentType = .oneTimeCode; $0.accessibilityIdentifier = "codeField" }
        a.addAction(UIAlertAction(title: "取消", style: .cancel))
        a.addAction(UIAlertAction(title: "加入", style: .default) { [weak self] _ in
            do { try SyncService.shared.join(peer: p, code: a.textFields?.first?.text ?? ""); self?.joining = true; self?.build() }
            catch { self?.alert("无法加入", error.localizedDescription) }
        })
        present(a, animated: true)
    }

    private func confirmLeave() {
        let a = UIAlertController(title: "退出同步账户？", message: "数据会保留在本机。以后需要用验证码重新加入。", preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "取消", style: .cancel))
        a.addAction(UIAlertAction(title: "退出", style: .destructive) { _ in SyncService.shared.leaveAccount() })
        present(a, animated: true)
    }
}
