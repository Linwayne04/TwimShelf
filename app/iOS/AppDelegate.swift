import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        if !Core.open() { NSLog("TwimShelf: failed to open library at %@", Core.libraryDirectory.path); AppLog.error("lifecycle", "无法打开资料库") }
        CrashWatch.shared.start()
        #if DEBUG
        DebugSeed.runIfRequested()
        if ProcessInfo.processInfo.environment["TL_RESET_UI_STATE"] != nil {
            SearchFields.saved = SearchFields()
            for k in ["filter.bad", "ai.prompt", "triage.mode", "triage.filter", "search.style", "search.fuzzy", "search.history", "grid.columns", "grid.level"] { UserDefaults.standard.removeObject(forKey: k) }
        }
        HitchMonitor.shared.startIfRequested()
        #endif
        Session.applyStoredCookies()
        AudioPolicy.observe()
        // Under memory pressure: stop AI work and release the model (it restarts on the next library change).
        NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AutoTagger.shared.stop() }
            Task { await AIEngine.shared.unloadAll() }
        }
        ModelStore.shared.configure()
        DispatchQueue.main.async {
            #if DEBUG
            if ProcessInfo.processInfo.environment["TL_NO_TIMERS"] != nil { return }
            #endif
            ActivityCenter.shared.start()
            GridThumbnails.keepLibraryWarm { UIScreen.main.scale }   // grid thumbnails made ahead of time
            SyncService.shared.start()
            // Recycle bin: delete what stayed longer than the retention period.
            DispatchQueue.global(qos: .utility).async { if Core.expireTrash() > 0 { DispatchQueue.main.async { NotificationCenter.default.post(name: .libraryChanged, object: nil) } } }
            AutoTagger.shared.startIfEnabled()
            // photos / files shared from other apps: import as soon as a share completes
            ShareInbox.observe { ShareInbox.importPending() }
            ShareInbox.importPending()
        }
        return true
    }

    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let cfg = UISceneConfiguration(name: "Main", sessionRole: session.role)
        cfg.delegateClass = SceneDelegate.self
        return cfg
    }
}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UINavigationController(rootViewController: FeedViewController())
        window.makeKeyAndVisible()
        self.window = window
        if !options.urlContexts.isEmpty { self.scene(scene, openURLContexts: options.urlContexts) }
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        #if DEBUG
        if ProcessInfo.processInfo.environment["TL_NO_TIMERS"] != nil { return }
        #endif
        ShareInbox.importPending()
    }

    /// Handles .tlpack files opened from Files or AirDrop.
    func scene(_ scene: UIScene, openURLContexts contexts: Set<UIOpenURLContext>) {
        for ctx in contexts {
            let url = ctx.url
            let ext = url.pathExtension.lowercased()
            DispatchQueue.global(qos: .userInitiated).async {
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let message: String
                do {
                    guard ext == "tlpack" else { return }
                    let r = try Core.importPack(url)
                    message = "已导入 \(r.posts) 个帖子，\(r.media) 个媒体"
                } catch { message = "导入失败：\(error.localizedDescription)" }
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .libraryChanged, object: nil)
                    let a = UIAlertController(title: nil, message: message, preferredStyle: .alert)
                    a.addAction(UIAlertAction(title: "好", style: .default))
                    var top = self.window?.rootViewController
                    while let p = top?.presentedViewController { top = p }
                    top?.present(a, animated: true)
                }
            }
        }
    }
}

#if DEBUG
/// Development helper: TL_IMPORT_DIR imports a legacy folder tree; TL_DEMO_TAGS adds sample AI/user tags.
enum DebugSeed {
    static func runIfRequested() {
        let env = ProcessInfo.processInfo.environment
        if let dir = env["TL_IMPORT_DIR"] {
            do { let r = try Core.importLegacyDirectory(URL(fileURLWithPath: dir)); NSLog("import: %d posts, %d media, %d skipped", r.posts, r.media, r.skipped.count) }
            catch { NSLog("import failed: %@", "\(error)") }
        }
        if env["TL_RESET_UI_STATE"] != nil {
            // UI tests start from the full sample: bring back anything an earlier test binned.
            let binned = Core.trashList().map(\.mediaId)
            if !binned.isEmpty { _ = try? Core.restore(binned) }
            for r in Core.tagRenames() { try? Core.undoRename(r.old) }
            for f in Core.folders() { try? Core.deleteFolder(f.name) }
            _ = try? Core.triageClear()
        }
        // two local external models, for looking at the pages and sheets that list models
        if env["TL_SEED_EXTERNAL"] != nil {
            for n in ["本地 Ollama", "本地 LM Studio"] {
                var m = ExternalModel.new(); m.name = n; m.url = "http://127.0.0.1:11434"; ExternalModels.save(m)
            }
        }
        if env["TL_DEMO_TAGS"] != nil, let items = try? Core.feed(FeedRequest(seed: 7)) {
            let models = ["EZCon--Huihui-Qwen3-VL-2B-Instruct-abliterated-4bit-mlx", "alexgusevski--Huihui-Qwen3-VL-8B-Instruct-abliterated-q4-mlx"]
            let ai = ["墙", "白墙", "猫", "天空", "城市夜景", "人像", "风景", "蓝色"]
            for (i, it) in items.enumerated() {
                try? Core.aiApply(mediaId: it.mediaId, model: models[i % 2], labels: [ai[i % ai.count], ai[(i * 3 + 1) % ai.count]])
                if i % 3 == 0 { try? Core.addTag("收藏", to: it.mediaId) }
            }
        }
    }
}
#endif
