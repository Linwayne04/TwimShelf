import AppKit
import SwiftUI

@MainActor
final class SyncModel: ObservableObject {
    @Published var joining = false

    /// A pairing that ended: adopt the account, or say why not.
    func tick(_ window: NSWindow?) {
        let svc = SyncService.shared
        guard joining, let j = svc.status?.join, !j.running else { return }
        joining = false
        if svc.adoptJoinResultIfAny() { macAlert(window, "已加入", "这台 Mac 会自动与同一账户的其他设备同步。") }
        else if let e = j.error { macAlert(window, "加入失败", e) }
    }

    func join(_ p: SyncService.Peer, _ window: NSWindow?) {
        macPrompt(window, title: "加入「\(p.name)」的账户", message: "输入那台设备上显示的 6 位验证码", placeholder: "000000") { [weak self] code in
            do { try SyncService.shared.join(peer: p, code: code); self?.joining = true }
            catch { macAlert(window, "无法加入", error.localizedDescription) }
        }
    }
}

struct SyncPageView: View {
    @EnvironmentObject private var env: PaneEnv
    @StateObject private var live = LiveTick()
    @StateObject private var m = SyncModel()

    var body: some View {
        let _ = live.count
        let svc = SyncService.shared
        let st = svc.status
        SettingsCanvas {
            if svc.localNetworkDenied {
                Card(tint: .red, spacing: 12) {
                    CardRow(symbol: "wifi.exclamationmark", color: .red, title: "无法访问本地网络",
                            detail: "TwimShelf 没有「本地网络」权限，无法发现和连接其他设备。请在「系统设置 › 隐私与安全性 › 本地网络」中打开 TwimShelf。") {
                        Button("打开系统设置…") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork")!) }
                    }
                }
            }
            if let n = ActivityCenter.shared.stats?.newerOps, n > 0 {
                Card(tint: .orange, spacing: 8) {
                    CardRow(symbol: "arrow.up.circle.fill", color: .orange, title: "请更新这台 Mac（\(n) 条记录待生效）", detail: LibraryStats.newerOpsText) { EmptyView() }
                }
            }
            if svc.hasAccount, let acct = st?.accountId {
                account(svc, st, acct)
            } else {
                noAccount(svc)
            }
        }
        .onAppear { live.onTick = { [weak m] in m?.tick(env.window) }; live.start(every: 1) }
        .onDisappear { live.stop() }
    }

    // MARK: With an account

    @ViewBuilder private func account(_ svc: SyncService, _ st: SyncService.Status?, _ acct: String) -> some View {
        let syncing = (st?.syncing ?? 0) > 0
        let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 16) {
                ZStack {
                    if syncing { PulseRing(color: .green) }
                    IconTile(symbol: "laptopcomputer", color: .green, size: 52)
                }
                .frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 5) {
                    Text(st?.deviceName ?? "这台 Mac").font(.system(size: 20, weight: .bold, design: .rounded))
                    HStack(spacing: 6) {
                        Pill(text: "账户 \(acct.prefix(8).uppercased())", color: .secondary, symbol: "person.crop.circle")
                        if syncing { Pill(text: "正在同步", color: .blue, symbol: "arrow.triangle.2.circlepath") }
                        else { Pill(text: "空闲", color: .green, symbol: "checkmark") }
                    }
                }
                Spacer(minLength: 8)
                Button { svc.syncNow() } label: { Label("立即同步", systemImage: "arrow.triangle.2.circlepath") }.buttonStyle(.borderedProminent).controlSize(.large)
            }
            StatsStrip(stats: ActivityCenter.shared.stats)
            if let n = svc.note { Banner(text: n, symbol: "info.circle.fill", color: .blue) }
            Text("同一账户的设备在局域网中自动发现并互相同步帖子、媒体、标签及其来源。没有中心设备，离线后再上线都会追上。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            shape.fill(LinearGradient(colors: [Color.green.opacity(0.18), Color.teal.opacity(0.08), Color.blue.opacity(0.05)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(shape.fill(Color(nsColor: .controlBackgroundColor).opacity(0.55)))
                .overlay(shape.strokeBorder(Color.primary.opacity(0.08)))
                .shadow(color: Color.green.opacity(0.12), radius: 16, y: 6)
        }

        devices(svc, st, acct)
        addDevice(svc, st)

        Card(tint: .red, spacing: 10) {
            CardRow(symbol: "rectangle.portrait.and.arrow.right", color: .red, title: "退出同步账户", detail: "仅让这台设备停止同步，不删除任何数据。") {
                Button("退出…", role: .destructive) { svc.leaveAccount() }
            }
        }
    }

    @ViewBuilder private func devices(_ svc: SyncService, _ st: SyncService.Status?, _ acct: String) -> some View {
        let mine = svc.peers.values.filter { $0.account == acct }.sorted { $0.name < $1.name }
        let known = st?.peers ?? []
        let offline = known.filter { k in !mine.contains(where: { $0.device == k.device }) }
        VStack(alignment: .leading, spacing: 10) {
            SectionHeading("账户中的设备", note: mine.isEmpty && known.isEmpty ? nil : "在线 \(mine.count) 台 · 离线 \(offline.count) 台")
            if mine.isEmpty && known.isEmpty {
                Card { Text("暂无其他设备。在另一台设备上选择「加入已有账户」，再用下面的验证码配对。").foregroundStyle(.secondary) }
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 14, alignment: .top)], spacing: 14) {
                    ForEach(mine, id: \.device) { p in
                        let info = known.first { $0.device == p.device }
                        deviceCard(name: p.name, online: true,
                                   detail: info.map { $0.lastError == nil ? "同步于 \(ago($0.lastSync))" : "出错：\($0.lastError!)" } ?? "刚刚发现",
                                   warning: info?.skewText, failed: info?.lastError != nil)
                    }
                    ForEach(offline, id: \.device) { k in
                        deviceCard(name: k.name, online: false, detail: "上次同步 \(ago(k.lastSync))", warning: k.skewText, failed: false)
                    }
                }
            }
        }
    }

    private func deviceCard(name: String, online: Bool, detail: String, warning: String?, failed: Bool) -> some View {
        Card(spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                IconTile(symbol: deviceSymbol(name), color: online ? .green : .gray, size: 40)
                VStack(alignment: .leading, spacing: 4) {
                    Text(name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    HStack(spacing: 5) {
                        Circle().fill(online ? Color.green : Color.secondary.opacity(0.6)).frame(width: 7, height: 7)
                        Text(online ? "在线" : "离线").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            Text(detail).font(.caption).foregroundStyle(failed ? Color.red : Color.secondary).fixedSize(horizontal: false, vertical: true)
            if let warning { Banner(text: warning, symbol: "clock.badge.exclamationmark", color: .orange) }
        }
        .opacity(online ? 1 : 0.8)
    }

    /// The pairing: a code that stays valid for a few minutes.
    @ViewBuilder private func addDevice(_ svc: SyncService, _ st: SyncService.Status?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeading("添加新设备")
            if let code = st?.pairingCode {
                Card(tint: .blue, spacing: 16) {
                    PairingCodeView(code: code, secondsLeft: Int(st?.pairingSecondsLeft ?? 0))
                    HStack {
                        Text("在新设备的「同步」中选择这台设备并输入验证码。").font(.callout).foregroundStyle(.secondary)
                        Spacer()
                        Button("取消", role: .destructive) { svc.cancelPairing() }
                    }
                }
            } else {
                Card {
                    CardRow(symbol: "plus.viewfinder", color: .blue, title: "显示验证码", detail: "在新设备上输入它，新设备就加入这个账户。") {
                        Button("显示验证码…") { _ = svc.beginPairing(); svc.refreshStatus() }.buttonStyle(.borderedProminent)
                    }
                }
            }
        }
    }

    // MARK: Without an account

    @ViewBuilder private func noAccount(_ svc: SyncService) -> some View {
        let joinable = svc.peers.values.filter { $0.account != nil }.sorted { $0.name < $1.name }
        Card(tint: .green, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                IconTile(symbol: "person.crop.circle.badge.plus", color: .green, size: 44)
                VStack(alignment: .leading, spacing: 4) {
                    Text("第一台设备").font(.system(size: 16, weight: .semibold))
                    Text("在第一台设备上创建同步账户，然后用它给其他设备显示验证码。").font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button { svc.createAccount() } label: { Label("创建同步账户", systemImage: "plus") }.buttonStyle(.borderedProminent).controlSize(.large)
            }
        }
        VStack(alignment: .leading, spacing: 10) {
            SectionHeading("加入已有账户", note: "先在已加入账户的设备上点「显示验证码」。")
            Card(spacing: 12) {
                if m.joining { HStack(spacing: 8) { ProgressView().controlSize(.small); Text("正在配对…").foregroundStyle(.secondary) } }
                if joinable.isEmpty {
                    HStack(spacing: 10) { ProgressView().controlSize(.small); Text("正在局域网中查找设备…").foregroundStyle(.secondary) }
                }
                ForEach(Array(joinable.enumerated()), id: \.element.device) { i, p in
                    if i > 0 { RowDivider() }
                    CardRow(symbol: deviceSymbol(p.name), color: .indigo, title: p.name, detail: "已加入账户的设备") {
                        Button(p.host == nil ? "解析中…" : "加入…") { m.join(p, env.window) }.disabled(p.host == nil)
                    }
                }
            }
        }
    }

    // MARK: Helpers

    private func deviceSymbol(_ name: String) -> String {
        let n = name.lowercased()
        if n.contains("iphone") { return "iphone" }
        if n.contains("ipad") { return "ipad" }
        if n.contains("mac") || n.contains("book") { return "laptopcomputer" }
        return "desktopcomputer"
    }

    private func ago(_ t: UInt64) -> String {
        guard t > 0 else { return "从未" }
        let s = Int(Date().timeIntervalSince1970) - Int(t)
        return s < 60 ? "刚刚" : s < 3600 ? "\(s / 60) 分钟前" : "\(s / 3600) 小时前"
    }
}

/// A ring that breathes outward (something is happening).
struct PulseRing: View {
    let color: Color
    @State private var on = false
    var body: some View {
        Circle().strokeBorder(color.opacity(on ? 0 : 0.5), lineWidth: 3)
            .scaleEffect(on ? 1.35 : 0.9)
            .onAppear { withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { on = true } }
    }
}

/// Six digits in boxes, with a draining countdown (the service reports the seconds left every second or so).
struct PairingCodeView: View {
    let code: String
    let secondsLeft: Int
    @State private var base = 0
    @State private var baseAt = Date()

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let left = max(0, base - Int(ctx.date.timeIntervalSince(baseAt)))
            HStack(alignment: .center, spacing: 22) {
                HStack(spacing: 8) {
                    ForEach(Array(code.enumerated()), id: \.offset) { _, ch in
                        Text(String(ch)).font(.system(size: 34, weight: .bold, design: .rounded)).monospacedDigit()
                            .frame(width: 46, height: 62)
                            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.blue.opacity(0.35), lineWidth: 1.5))
                    }
                }
                .textSelection(.enabled)
                VStack(spacing: 4) {
                    ZStack {
                        ProgressRing(value: Double(left) / 300, lineWidth: 6, color: .blue)
                        Text(String(format: "%d:%02d", left / 60, left % 60)).font(.system(size: 13, weight: .semibold, design: .rounded)).monospacedDigit()
                    }
                    .frame(width: 58, height: 58)
                    Text("最多尝试 5 次").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .onAppear { base = secondsLeft; baseAt = Date() }
        .onChange(of: secondsLeft) { _, v in base = v; baseAt = Date() }
        .onChange(of: code) { _, _ in base = secondsLeft; baseAt = Date() }
    }
}
