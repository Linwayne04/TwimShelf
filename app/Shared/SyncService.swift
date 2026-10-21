import Foundation
import Network
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// App side of LAN sync: Bonjour advertising/discovery and scheduling. The Rust core owns the
/// listener, the protocol, crypto and data merging.
final class SyncService: NSObject, NetServiceDelegate {
    static let shared = SyncService()
    static let changed = Notification.Name("SyncServiceChanged")
    #if DEBUG && os(macOS)
    /// The Mac debug build is a separate app with its own library: it never shows up as (or
    /// pairs with) the user's devices.
    static let serviceType = "_twlib-debug._tcp"
    #else
    static let serviceType = "_twlib._tcp"
    #endif
    /// A one-line warning the main screen should show once (local network denied, clock skew).
    static let warning = Notification.Name("SyncServiceWarning")

    /// The system refused local-network access (iOS / macOS privacy setting): sync cannot work.
    private(set) var localNetworkDenied = false
    private var warnedSkew = Set<String>()
    private var warnedDenied = false

    struct Peer: Hashable {
        let serviceName: String
        let name: String
        let account: String?
        let device: String
        var host: String?
        var port: UInt16?
    }

    struct Status: Decodable, Equatable {
        struct PeerInfo: Decodable, Equatable { let device: String; let name: String; let lastSync: UInt64; let lastError: String?; let addr: String
            /// Peer clock minus ours (ms) at the last session, and whether that is enough to matter.
            var clockSkewMs: Int64? = nil; var clockWarning: Bool? = false
            var skewText: String? {
                guard clockWarning == true, let ms = clockSkewMs else { return nil }
                let m = Double(abs(ms)) / 60_000
                let amount = m >= 120 ? String(format: "%.0f 小时", m / 60) : String(format: "%.0f 分钟", m)
                return "时钟比本机\(ms > 0 ? "快" : "慢") \(amount)"
            }
        }
        struct Join: Decodable, Equatable { let running: Bool; let accountKey: String?; let error: String? }
        struct Transfer: Decodable, Equatable { let received: UInt64; let total: UInt64; let totalBytes: UInt64; let bytes: UInt64; let currentSize: UInt64; let currentDone: UInt64; let lastPath: String? }
        let accountId: String?
        let deviceId: String
        let deviceName: String
        let port: UInt16?
        let pairingCode: String?
        let pairingSecondsLeft: UInt64?
        let peers: [PeerInfo]
        let syncing: Int
        let changes: UInt64
        let join: Join
        let receiving: Transfer?
        /// "host:port" → reason, for addresses whose last attempt failed.
        var failed: [String: String]? = nil
    }

    private(set) var peers: [String: Peer] = [:]     // by device id
    private(set) var status: Status?
    private var browser: NWBrowser?
    private var service: NetService?
    private var resolvers: [String: NWConnection] = [:]
    private var timer: Timer?
    private var pollTimer: Timer?
    private var lastChanges: UInt64 = 0
    private var pendingLocalSync: DispatchWorkItem?
    private let queue = DispatchQueue(label: "sync.bonjour")
    /// The result of the last "立即同步", shown under the button (nil = nothing to say).
    private(set) var note: String?
    private var noteStarted: Date?
    /// Devices to sync with as soon as their address is known (a manual sync looks every device up again).
    private var syncWhenResolved = Set<String>()
    /// Failures already acted on, so one failure triggers one new lookup.
    private var handledFailures = Set<String>()
    private var lifecycleObservers: [NSObjectProtocol] = []

    var accountKey: String? { Keychain.get("sync.key") }
    var hasAccount: Bool { accountKey != nil }

    var summary: String {
        if localNetworkDenied { return "本地网络被拒绝" }
        guard hasAccount else { return "未开启" }
        let online = peers.values.filter { $0.account == status?.accountId }.count
        return online == 0 ? "已开启" : "\(online) 台设备在线"
    }

    var stateText: String {
        guard hasAccount else { return "未加入同步" }
        if localNetworkDenied { return "本地网络被拒绝" }
        guard let s = status else { return "正在读取同步状态" }
        if s.syncing > 0 { return "正在同步" }
        if !(s.failed ?? [:]).isEmpty || s.peers.contains(where: { $0.lastError != nil }) { return "同步失败，请查看详情" }
        let last = s.peers.map(\.lastSync).max() ?? 0
        if last > 0 { return "上次同步成功于 " + Date(timeIntervalSince1970: Double(last)).formatted(date: .omitted, time: .shortened) }
        return "等待连接其他设备"
    }

    static var deviceName: String {
        #if canImport(UIKit)
        return UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : (ProcessInfo.processInfo.isiOSAppOnMac ? "Mac (iPad App)" : UIDevice.current.name)
        #else
        return Host.current().localizedName ?? "Mac"
        #endif
    }

    // MARK: Lifecycle

    /// Starts listening, advertising and browsing. Safe to call repeatedly.
    func start() {
        let r = Core.syncStart(accountKey: accountKey ?? "", deviceName: Self.deviceName)
        guard case .success(let port) = r else { return }
        refreshStatus()
        advertise(port: port)
        browse()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in self?.syncAll() }
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in self?.refreshStatus() }
        NotificationCenter.default.removeObserver(self, name: .libraryChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(localChange), name: .libraryChanged, object: nil)
        #if canImport(UIKit)
        // iOS withdraws a suspended app's Bonjour advertisement and may leave the browser with
        // stale results: advertise and browse again (and look every device up again) on return.
        if lifecycleObservers.isEmpty {
            lifecycleObservers.append(NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                self?.rediscover()
            })
        }
        #else
        // after sleep the network may have changed and other devices restarted
        if lifecycleObservers.isEmpty {
            lifecycleObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                self?.rediscover()
            })
        }
        #endif
        syncAll()
    }

    /// Advertises and browses again and forgets resolved addresses (they change when the other
    /// app restarts); the browser then reports every device again and each is looked up anew.
    func rediscover() {
        guard hasAccount || status != nil, let port = status?.port else { start(); return }
        resolvers.values.forEach { $0.cancel() }; resolvers.removeAll()
        for k in peers.keys { peers[k]?.host = nil; peers[k]?.port = nil }
        advertise(port: port)
        browse()
        post()
    }

    func stopNetworking() {
        timer?.invalidate(); pollTimer?.invalidate()
        browser?.cancel(); browser = nil
        service?.stop(); service = nil
        resolvers.values.forEach { $0.cancel() }; resolvers.removeAll()
        peers.removeAll(); endpoints.removeAll(); syncWhenResolved.removeAll()
    }

    /// Called by "清除所有数据": forget the account locally; nothing is sent to other devices.
    func resetForWipe() {
        DispatchQueue.main.async {
            self.stopNetworking()
            if !Keychain.set("sync.key", nil) { self.setNote("无法从钥匙串移除同步账号，请重试退出账号") }
            self.status = nil
            self.post()
        }
    }

    // MARK: Account

    func createAccount() {
        guard case .success(let key) = Core.syncNewAccount() else { return }
        guard Keychain.set("sync.key", key) else { setNote("无法保存同步账号到钥匙串"); return }
        stopNetworking()
        start()
    }

    func leaveAccount() {
        guard Keychain.set("sync.key", nil) else { setNote("无法从钥匙串移除同步账号"); return }
        stopNetworking()
        start()
    }

    func beginPairing() -> String? { try? Core.syncPairBegin() }

    /// Online peers of this account with a resolved address.
    var reachablePeers: [Peer] {
        guard let acct = status?.accountId else { return [] }
        return peers.values.filter { $0.account == acct && $0.host != nil }.sorted { $0.name < $1.name }
    }

    /// Models on other devices that this device does not have yet (asked on demand, never pushed).
    struct RemoteModel: Hashable { let peer: Peer; let info: Core.ModelInfo }
    func remoteModels(completion: @escaping ([RemoteModel]) -> Void) {
        let peers = reachablePeers
        let have = Set(ModelStore.shared.installed.map(\.id))
        DispatchQueue.global(qos: .userInitiated).async {
            var out: [RemoteModel] = []
            for p in peers {
                guard let h = p.host, let port = p.port, let list = try? Core.syncPeerModels(host: h, port: port) else { continue }
                out += list.filter { !have.contains($0.id) && !out.map(\.info.id).contains($0.id) }.map { RemoteModel(peer: p, info: $0) }
            }
            DispatchQueue.main.async { completion(out) }
        }
    }

    func pull(_ m: RemoteModel) throws {
        guard let h = m.peer.host, let port = m.peer.port else { throw CoreError(message: "该设备已离线") }
        try Core.syncPullModel(host: h, port: port, id: m.info.id, label: "\(ModelStore.shared.displayName(m.info.id))（来自 \(m.peer.name)）", total: m.info.bytes)
    }
    func cancelPairing() { Core.syncPairCancel() }

    func join(peer: Peer, code: String) throws {
        guard let host = peer.host, let port = peer.port else { throw CoreError(message: "该设备地址尚未解析，请稍候重试") }
        try Core.syncJoin(host: host, port: port, code: code)
        refreshStatus()   // pick up join.running = true right away so callers don't see stale state
    }

    /// Called while a join is running; stores the key once pairing succeeded.
    func adoptJoinResultIfAny() -> Bool {
        guard let key = status?.join.accountKey, accountKey != key else { return false }
        guard Keychain.set("sync.key", key) else {
            stopNetworking()
            start()
            setNote("无法保存同步账号到钥匙串")
            return false
        }
        stopNetworking()
        start()
        return true
    }

    // MARK: Syncing

    /// Automatic sync. Normally one side of each pair starts (the smaller device id): a session
    /// moves data both ways. But discovery can be one-sided (one device sees the other but not
    /// back), so the other side also starts when the pair has not synced for a minute. Two
    /// sessions at once are harmless: the core refuses the second for the same device.
    func syncAll() {
        guard hasAccount, let mine = status?.accountId, let me = status?.deviceId else { return }
        let now = UInt64(Date().timeIntervalSince1970)
        for p in peers.values where p.account == mine {
            let last = status?.peers.first { $0.device == p.device }?.lastSync ?? 0
            guard me < p.device || now &- last > 60 else { continue }
            if let h = p.host, let port = p.port { Core.syncWith(host: h, port: port) }
        }
    }

    /// "立即同步": looks every device of the account up again (a restarted app has a new port)
    /// and syncs with each as soon as it is found, whichever side would normally start. Says
    /// what happened in `note`.
    func syncNow() {
        guard hasAccount, let mine = status?.accountId else { setNote("尚未加入同步账户"); return }
        let targets = peers.values.filter { $0.account == mine }
        if localNetworkDenied { setNote("无法访问本地网络：请在系统设置的「隐私与安全性 › 本地网络」里允许 TwimShelf"); return }
        guard !targets.isEmpty else {
            setNote("没有找到同账户的在线设备。请确认另一台设备打开了 TwimShelf，并且在同一个网络里。")
            rediscover()
            return
        }
        noteStarted = Date()
        setNote("正在连接 " + targets.map(\.name).joined(separator: "、") + "…")
        for p in targets {
            syncWhenResolved.insert(p.device)
            peers[p.device]?.host = nil; peers[p.device]?.port = nil
            if let ep = endpoints[p.device] { resolve(ep, device: p.device) }
        }
    }

    private func setNote(_ t: String?) { note = t; post() }

    /// Bonjour endpoints by device (to look a device up again without waiting for the browser).
    private var endpoints: [String: NWEndpoint] = [:]

    /// After a manual sync: report success or the reason once the sessions have ended.
    private func updateNote(_ s: Status) {
        guard let started = noteStarted, s.syncing == 0, syncWhenResolved.isEmpty else { return }
        let since = UInt64(started.timeIntervalSince1970)
        let mine = peers.values.filter { $0.account == s.accountId }
        let ok = mine.filter { p in (s.peers.first { $0.device == p.device }?.lastSync ?? 0) >= since }
        let errors = mine.compactMap { p -> String? in
            guard let h = p.host, let port = p.port, let e = s.failed?["\(h):\(port)"] else { return nil }
            return "\(p.name)：\(e)"
        }
        if !ok.isEmpty && errors.isEmpty { noteStarted = nil; setNote("已同步：" + ok.map(\.name).joined(separator: "、")) }
        else if !errors.isEmpty { noteStarted = nil; setNote("同步失败 · " + errors.joined(separator: "；")) }
        else if Date().timeIntervalSince(started) > 15 { noteStarted = nil; setNote("没有连上其他设备。请确认两台设备都打开了 TwimShelf 且在同一个网络里。") }
    }

    @objc private func localChange() {
        pendingLocalSync?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.syncAll() }
        pendingLocalSync = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: w)
    }

    func refreshStatus() {
        guard let s = Core.syncStatus() else { return }
        let grew = s.changes > lastChanges
        lastChanges = s.changes
        guard s != status else { updateNote(s); return }   // only notify on real changes
        status = s
        post()
        // a failed address may be stale (the other app restarted on a new port): look it up again
        for (addr, err) in s.failed ?? [:] where !handledFailures.contains(addr + err) {
            handledFailures.insert(addr + err)
            AppLog.warn("sync", "同步失败：\(err)")
            for p in peers.values where p.host.map({ "\($0):\(p.port ?? 0)" }) == addr {
                peers[p.device]?.host = nil; peers[p.device]?.port = nil
                if let ep = endpoints[p.device] { resolve(ep, device: p.device) }
            }
        }
        updateNote(s)
        for p in s.peers where p.clockWarning == true && !warnedSkew.contains(p.device) {
            warnedSkew.insert(p.device)
            let text = "「\(p.name)」的\(p.skewText ?? "时钟与本机不一致")，请校准时间（回收站的自动删除和冲突合并依赖时间）"
            DispatchQueue.main.async { NotificationCenter.default.post(name: Self.warning, object: nil, userInfo: ["text": text]) }
        }
        #if canImport(UIKit)
        // iOS pauses networking when the screen locks; keep it awake while a sync is running.
        UIApplication.shared.isIdleTimerDisabled = s.syncing > 0
        #endif
        if grew {
            // Remote data arrived: refresh UI without echoing a sync storm back.
            NotificationCenter.default.removeObserver(self, name: .libraryChanged, object: nil)
            NotificationCenter.default.post(name: .libraryChanged, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(localChange), name: .libraryChanged, object: nil)
        }
    }

    private func post() { DispatchQueue.main.async { NotificationCenter.default.post(name: Self.changed, object: nil) } }

    // MARK: Bonjour

    private func advertise(port: UInt16) {
        service?.stop()
        let dev = status?.deviceId ?? UUID().uuidString
        let svc = NetService(domain: "local.", type: Self.serviceType + ".", name: "\(Self.deviceName)·\(dev.prefix(4))", port: Int32(port))
        var txt: [String: Data] = ["dev": Data(dev.utf8), "name": Data(Self.deviceName.utf8)]
        if let a = status?.accountId { txt["acct"] = Data(a.utf8) }
        svc.setTXTRecord(NetService.data(fromTXTRecord: txt))
        svc.delegate = self
        svc.publish()
        service = svc
    }

    func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        AppLog.warn("sync", "无法在局域网上公布本机（\(errorDict)），稍后重试")
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, self.service === sender, let port = self.status?.port else { return }
            self.advertise(port: port)
        }
    }

    private func browse() {
        browser?.cancel()
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: Self.serviceType, domain: nil), using: .tcp)
        b.browseResultsChangedHandler = { [weak self] results, _ in self?.handle(results) }
        b.stateUpdateHandler = { [weak self] state in
            // Denied local-network permission shows up as a DNS "policy denied" (-65570) error.
            var denied = false
            if case .waiting(let e) = state, case .dns(let code) = e, code == -65570 { denied = true }
            if case .failed(let e) = state, case .dns(let code) = e, code == -65570 { denied = true }
            if case .failed(let e) = state { AppLog.warn("sync", "查找局域网设备失败：\(e)") }
            DispatchQueue.main.async {
                guard let self else { return }
                if case .ready = state { denied = false }
                guard denied != self.localNetworkDenied else { return }
                self.localNetworkDenied = denied
                self.post()
                if denied && !self.warnedDenied {
                    self.warnedDenied = true
                    NotificationCenter.default.post(name: Self.warning, object: nil, userInfo: ["text": "无法访问本地网络，局域网同步已暂停", "settings": true])
                }
            }
        }
        b.start(queue: queue)
        browser = b
    }

    /// Browser results arrive on `queue`; all state (peers, endpoints, resolvers) lives on main.
    private func handle(_ results: Set<NWBrowser.Result>) {
        DispatchQueue.main.async { self.apply(results) }
    }

    private func apply(_ results: Set<NWBrowser.Result>) {
        let me = status?.deviceId
        var seen = Set<String>()
        for r in results {
            guard case let .service(name, _, _, _) = r.endpoint, case let .bonjour(txt) = r.metadata,
                  let dev = txt["dev"], dev != me else { continue }
            seen.insert(dev)
            let old = peers[dev]
            // a re-published service (the other app restarted) may have a new port: look it up again
            let same = old?.serviceName == name && endpoints[dev] == r.endpoint
            let peer = Peer(serviceName: name, name: txt["name"] ?? name, account: txt["acct"], device: dev,
                            host: same ? old?.host : nil, port: same ? old?.port : nil)
            peers[dev] = peer
            endpoints[dev] = r.endpoint
            if peer.host == nil { resolve(r.endpoint, device: dev) }
        }
        for k in peers.keys where !seen.contains(k) { peers.removeValue(forKey: k); endpoints.removeValue(forKey: k) }
        post()
    }

    /// Resolves a Bonjour endpoint to an IPv4 host:port by opening (and closing) a TCP connection.
    private func resolve(_ endpoint: NWEndpoint, device: String) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard resolvers[device] == nil else { return }
        let params = NWParameters.tcp
        if let ip = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options { ip.version = .v4 }
        let c = NWConnection(to: endpoint, using: params)
        resolvers[device] = c
        c.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                if case let .hostPort(host, port) = c.currentPath?.remoteEndpoint {
                    var h = "\(host)"
                    if let pct = h.firstIndex(of: "%") { h = String(h[..<pct]) }
                    DispatchQueue.main.async {
                        guard var p = self.peers[device] else { return }
                        p.host = h; p.port = port.rawValue; self.peers[device] = p; self.post()
                        if self.syncWhenResolved.remove(device) != nil { Core.syncWith(host: h, port: port.rawValue) } else { self.syncAll() }
                    }
                }
                c.cancel()
                DispatchQueue.main.async { if self.resolvers[device] === c { self.resolvers.removeValue(forKey: device) } }
            case .failed(let e):
                AppLog.warn("sync", "无法连接到局域网设备：\(e)")
                DispatchQueue.main.async {
                    if self.resolvers[device] === c { self.resolvers.removeValue(forKey: device) }
                    if self.syncWhenResolved.remove(device) != nil, let s = self.status { self.updateNote(s) }
                }
            case .cancelled:
                DispatchQueue.main.async { if self.resolvers[device] === c { self.resolvers.removeValue(forKey: device) } }
            default: break
            }
        }
        c.start(queue: queue)
    }
}

extension Core {
    static func syncNewAccount() -> Result<String, Error> { Result { try decodeOk(tl_sync_new_account(), as: String.self) } }
    static func syncStart(accountKey: String, deviceName: String) -> Result<UInt16, Error> { Result { try decodeOk(tl_sync_start(accountKey, deviceName), as: UInt16.self) } }
    static func syncStatus() -> SyncService.Status? { try? decodeOk(tl_sync_status(), as: SyncService.Status.self) }
    static func syncPairBegin() throws -> String { try decodeOk(tl_sync_pair_begin(), as: String.self) }
    static func syncPairCancel() { tl_sync_pair_cancel() }
    static func syncJoin(host: String, port: UInt16, code: String) throws { _ = try decodeOk(tl_sync_join(host, port, code), as: Optional<Int>.self) }
    static func syncPeerModels(host: String, port: UInt16) throws -> [Core.ModelInfo] { try decodeOk(tl_sync_peer_models(host, port), as: [Core.ModelInfo].self) }
    static func syncPullModel(host: String, port: UInt16, id: String, label: String, total: UInt64) throws {
        _ = try decodeOk(tl_sync_pull_model(host, port, id, label, total), as: Optional<Int>.self)
    }
    static func syncWith(host: String, port: UInt16) { _ = try? decodeOk(tl_sync_with(host, port), as: Optional<Int>.self) }
}
