import AppKit
import AVFoundation
import AVKit

/// Custom MP4 player shown inside the main window (no extra window, no AVPlayerView). Mouse and
/// trackpad equivalents of the touch gestures: double-click = play/pause · horizontal drag = seek ·
/// press-and-hold = 2.5× · Space / ←→ / ↑↓ / Esc / F keys. The controls (play · progress · time ·
/// share · close · picture in picture) sit right on the video, without a bar behind them.
final class MacPlayerView: NSView, AVPictureInPictureControllerDelegate {
    /// Called when the user closes the player (close button or Esc).
    var onClose: (() -> Void)?
    /// Picture in picture started (the host hides the player but keeps it) / ended.
    var onPiPStart: (() -> Void)?
    var onPiPRestore: (() -> Void)?
    var onPiPEnd: (() -> Void)?
    private let player: AVPlayer
    private let playerLayer = AVPlayerLayer()
    private let hud = NSTextField(labelWithString: "")
    private let bar = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let time = NSTextField(labelWithString: "0:00 / 0:00")
    private let playButton = NSButton()
    private let closeButton = NSButton()
    private let pipButton = NSButton()
    private let shareButton = NSButton()
    private let fileURL: URL
    private var pip: AVPictureInPictureController?
    private let controls = NSView()
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var hideTimer: Timer?
    private var holdTimer: Timer?
    private var boosting = false
    private var dragMode = 0 // 0 none, 1 seek
    private var dragStart = NSPoint.zero
    private var startValue: Double = 0
    private var scrubbing = false
    /// Read once: whether a sideways drag seeks (off with 视频禁用手势; see `LibraryPrefs.playerGesturesOff`).
    let dragSeeks = !LibraryPrefs.playerGesturesOff
    /// Shown as a page of the media viewer: no picture in picture, and the viewer handles the keys.
    var embedded = false { didSet { pipButton.isHidden = embedded || pip == nil } }

    private var duration: Double { let d = player.currentItem?.duration.seconds ?? 0; return d.isFinite ? d : 0 }

    /// Share menu for the video file (other apps, AirDrop, Messages…).
    @objc private func shareTapped() { NSSharingServicePicker(items: [fileURL]).show(relativeTo: shareButton.bounds, of: shareButton, preferredEdge: .minY) }

    init(url: URL, startAt: CMTime) {
        fileURL = url
        let item = AVPlayerItem(asset: AVURLAsset(url: url))
        item.preferredForwardBufferDuration = 2
        player = AVPlayer(playerItem: item)
        player.automaticallyWaitsToMinimizeStalling = false
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        playerLayer.player = player
        playerLayer.videoGravity = .resizeAspect
        layer?.addSublayer(playerLayer)

        hud.font = .monospacedDigitSystemFont(ofSize: 16, weight: .semibold)
        hud.textColor = .white
        hud.alignment = .center
        hud.wantsLayer = true
        hud.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.6).cgColor
        hud.layer?.cornerRadius = 12
        hud.alphaValue = 0

        // no bar behind the controls: a soft shadow keeps them readable on bright video
        controls.wantsLayer = true
        controls.shadow = {
            let sh = NSShadow()
            sh.shadowColor = .black.withAlphaComponent(0.6)
            sh.shadowBlurRadius = 6
            sh.shadowOffset = .zero
            return sh
        }()
        playButton.isBordered = false
        playButton.contentTintColor = .white
        playButton.target = self
        playButton.action = #selector(togglePlay)
        bar.target = self
        bar.action = #selector(scrub)
        bar.isContinuous = true
        time.textColor = .white
        time.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        for (b, sym, label, id, sel) in [(closeButton, "xmark", "关闭", "playerClose", #selector(closeTapped)),
                                         (pipButton, "pip.enter", "画中画", "playerPiP", #selector(togglePiP)), (shareButton, "square.and.arrow.up", "分享", "playerShare", #selector(shareTapped))] {
            b.isBordered = false
            b.image = NSImage(systemSymbolName: sym, accessibilityDescription: label)
            b.symbolConfiguration = .init(pointSize: 14, weight: .semibold)
            b.contentTintColor = .white
            b.toolTip = label
            b.setAccessibilityIdentifier(id)
            b.target = self; b.action = sel
            b.widthAnchor.constraint(equalToConstant: 26).isActive = true
        }
        let row = NSStackView(views: [playButton, bar, time, shareButton, closeButton, pipButton])
        row.spacing = 12
        row.setCustomSpacing(16, after: time)
        row.translatesAutoresizingMaskIntoConstraints = false
        controls.addSubview(row)
        [hud, controls].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; addSubview($0) }
        NSLayoutConstraint.activate([
            hud.centerXAnchor.constraint(equalTo: centerXAnchor), hud.topAnchor.constraint(equalTo: topAnchor, constant: 60),
            hud.widthAnchor.constraint(greaterThanOrEqualToConstant: 160),
            controls.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24), controls.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            controls.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -20), controls.heightAnchor.constraint(equalToConstant: 44),
            row.leadingAnchor.constraint(equalTo: controls.leadingAnchor, constant: 14), row.trailingAnchor.constraint(equalTo: controls.trailingAnchor, constant: -14),
            row.centerYAnchor.constraint(equalTo: controls.centerYAnchor),
        ])

        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] _ in self?.sync() }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            self?.player.seek(to: .zero); self?.player.play()
        }
        if startAt > .zero { player.seek(to: startAt, toleranceBefore: .zero, toleranceAfter: .zero) }
        applyAudioPolicy()
        audioObserver = NotificationCenter.default.addObserver(forName: AudioPolicy.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyAudioPolicy() }
        }
        player.playImmediately(atRate: 1)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
        scheduleHide()
        if AVPictureInPictureController.isPictureInPictureSupported(), let p = AVPictureInPictureController(playerLayer: playerLayer) {
            p.delegate = self
            pip = p
        } else { pipButton.isHidden = true }
    }

    // MARK: Close, picture in picture

    @objc private func closeTapped() { onClose?() }

    @objc private func togglePiP() {
        guard let pip else { return }
        if pip.isPictureInPictureActive { pip.stopPictureInPicture() } else { pip.startPictureInPicture() }
    }

    func pictureInPictureControllerWillStartPictureInPicture(_ c: AVPictureInPictureController) { onPiPStart?() }
    func pictureInPictureController(_ c: AVPictureInPictureController, restoreUserInterfaceForPictureInPictureStopWithCompletionHandler done: @escaping (Bool) -> Void) {
        onPiPRestore?(); done(true)
    }
    func pictureInPictureControllerDidStopPictureInPicture(_ c: AVPictureInPictureController) { onPiPEnd?() }
    var isInPiP: Bool { pip?.isPictureInPictureActive ?? false }
    required init?(coder: NSCoder) { fatalError() }

    private var audioObserver: NSObjectProtocol?

    /// Reminder pill near the top of the video that fades out after a few seconds.
    /// The user chose to hear this video through the speakers (reset when headphones go away).
    private var allowSpeaker = false
    private var hadHeadphones = AudioPolicy.headphonesConnected
    private weak var soundPrompt: NSView?

    private func applyAudioPolicy() {
        let now = AudioPolicy.headphonesConnected
        if hadHeadphones && !now { allowSpeaker = false }
        hadHeadphones = now
        let mute = AudioPolicy.shouldMute(allowSpeaker: allowSpeaker)
        player.isMuted = mute
        if !mute { soundPrompt?.removeFromSuperview(); return }
        guard soundPrompt == nil else { return }
        let url = fileURL
        Task { [weak self] in
            guard await AudioPolicy.hasAudio(url) else { return }
            await MainActor.run { self?.showSoundPrompt() }
        }
    }

    /// "没有连接耳机，已静音 · 开启声音".
    private func showSoundPrompt() {
        guard soundPrompt == nil, player.isMuted else { return }
        let l = NSTextField(labelWithString: AudioPolicy.promptText)
        l.font = .systemFont(ofSize: 13, weight: .semibold)
        l.textColor = .white
        let on = ClosureButton(title: "开启声音") { [weak self] in
            self?.allowSpeaker = true
            self?.player.isMuted = false
            self?.soundPrompt?.removeFromSuperview()
        }
        on.setAccessibilityIdentifier("soundOn")
        let box = NSStackView(views: [l, on])
        box.spacing = 10
        box.edgeInsets = NSEdgeInsets(top: 6, left: 14, bottom: 6, right: 10)
        box.wantsLayer = true
        box.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.7).cgColor
        box.layer?.cornerRadius = 14
        box.setAccessibilityIdentifier("audioBanner")
        box.translatesAutoresizingMaskIntoConstraints = false
        addSubview(box)
        NSLayoutConstraint.activate([box.centerXAnchor.constraint(equalTo: centerXAnchor), box.topAnchor.constraint(equalTo: topAnchor, constant: 110)])
        soundPrompt = box
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak box] in
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.4; $0.timingFunction = .springy; box?.animator().alphaValue = 0 }) { box?.removeFromSuperview() }
        }
    }

    private func showBanner(_ text: String) {
        let l = NSTextField(labelWithString: "  \(text)  ")
        l.font = .systemFont(ofSize: 13, weight: .semibold)
        l.textColor = .white
        l.wantsLayer = true
        l.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.65).cgColor
        l.layer?.cornerRadius = 12
        l.translatesAutoresizingMaskIntoConstraints = false
        addSubview(l)
        NSLayoutConstraint.activate([l.centerXAnchor.constraint(equalTo: centerXAnchor), l.topAnchor.constraint(equalTo: topAnchor, constant: 110), l.heightAnchor.constraint(equalToConstant: 28)])
        l.alphaValue = 0
        NSAnimationContext.runAnimationGroup { $0.duration = 0.3; $0.timingFunction = .springy; l.animator().alphaValue = 1 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.4; $0.timingFunction = .springy; l.animator().alphaValue = 0 }) { l.removeFromSuperview() }
        }
    }

    func teardown() {
        if let a = audioObserver { NotificationCenter.default.removeObserver(a); audioObserver = nil }
        player.pause()
        if let t = timeObserver { player.removeTimeObserver(t); timeObserver = nil }
        if let e = endObserver { NotificationCenter.default.removeObserver(e) }
    }

    override var acceptsFirstResponder: Bool { true }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }

    private func sync() {
        let t = player.currentTime().seconds
        if !scrubbing, duration > 0 { bar.doubleValue = t / duration }
        time.stringValue = "\(Self.fmt(t)) / \(Self.fmt(duration))"
        playButton.image = NSImage(systemSymbolName: player.timeControlStatus == .paused ? "play.fill" : "pause.fill", accessibilityDescription: nil)
    }

    static func fmt(_ s: Double) -> String {
        guard s.isFinite, s >= 0 else { return "0:00" }
        let i = Int(s); return i >= 3600 ? String(format: "%d:%02d:%02d", i / 3600, i / 60 % 60, i % 60) : String(format: "%d:%02d", i / 60, i % 60)
    }

    private func flash(_ text: String, sticky: Bool = false) {
        hud.stringValue = "  \(text)  "
        NSAnimationContext.runAnimationGroup { $0.duration = 0.1; $0.timingFunction = .springy; hud.animator().alphaValue = 1 }
        if !sticky { DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in if self?.hud.stringValue == "  \(text)  " { self?.hideHUD() } } }
    }
    private func hideHUD() { NSAnimationContext.runAnimationGroup { $0.duration = 0.2; $0.timingFunction = .springy; hud.animator().alphaValue = 0 } }

    private func scheduleHide() {
        hideTimer?.invalidate()
        controls.animator().alphaValue = 1
        NSCursor.unhide()
        hideTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: false) { [weak self] _ in
            guard let self, self.player.timeControlStatus != .paused else { return }
            NSAnimationContext.runAnimationGroup { $0.duration = 0.3; $0.timingFunction = .springy; self.controls.animator().alphaValue = 0 }
            NSCursor.setHiddenUntilMouseMoves(true)
        }
    }

    @objc func togglePlay() {
        if player.timeControlStatus == .paused { player.playImmediately(atRate: 1); flash("▶︎") } else { player.pause(); flash("❚❚") }
        sync(); scheduleHide()
    }

    @objc private func scrub() {
        scrubbing = true
        player.seek(to: CMTime(seconds: bar.doubleValue * duration, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        if NSApp.currentEvent?.type == .leftMouseUp { scrubbing = false }
    }

    func seek(by seconds: Double) {
        let t = min(max(player.currentTime().seconds + seconds, 0), duration)
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        flash("\(Self.fmt(t)) / \(Self.fmt(duration))")
    }

    // MARK: Mouse gestures

    override func mouseMoved(with event: NSEvent) { scheduleHide() }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { togglePlay(); return }
        dragStart = convert(event.locationInWindow, from: nil)
        dragMode = 0
        holdTimer?.invalidate()
        holdTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { [weak self] _ in
            guard let self, self.dragMode == 0 else { return }
            self.boosting = true
            self.player.rate = 2.5
            self.flash("2.5× ▶▶", sticky: true)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let dx = p.x - dragStart.x, dy = p.y - dragStart.y
        if dragMode == 0, !boosting, hypot(dx, dy) > 8 {
            holdTimer?.invalidate()
            // only sideways drags seek (unless that is turned off); vertical drags do nothing
            if abs(dx) > abs(dy), dragSeeks { dragMode = 1; startValue = player.currentTime().seconds; scrubbing = true }
            else { dragMode = -1 }
        }
        if dragMode == 1 {
            let span = min(max(duration, 1), 120)
            let t = min(max(startValue + Double(dx / bounds.width) * span, 0), duration)
            player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            if duration > 0 { bar.doubleValue = t / duration }
            flash("\(Self.fmt(t)) / \(Self.fmt(duration))", sticky: true)
        }
    }

    override func mouseUp(with event: NSEvent) {
        holdTimer?.invalidate()
        if boosting { boosting = false; player.rate = 1 }
        scrubbing = false
        if dragMode != 0 || hud.alphaValue > 0 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.hideHUD() } }
        dragMode = 0
    }

    // MARK: Keyboard

    /// Space, ↑ ↓ (volume) and F, for the viewer that shows this player as a page.
    func handleViewerKey(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 49: togglePlay()
        case 126: player.volume = min(player.volume + 0.1, 1); flash("🔊 \(Int(player.volume * 100))%")
        case 125: player.volume = max(player.volume - 0.1, 0); flash("🔊 \(Int(player.volume * 100))%")
        case 3: window?.toggleFullScreen(nil)
        default: return false
        }
        return true
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 49: togglePlay()                 // space
        case 123: seek(by: -5)                // ←
        case 124: seek(by: 5)                 // →
        case 126: player.volume = min(player.volume + 0.1, 1); flash("🔊 \(Int(player.volume * 100))%")
        case 125: player.volume = max(player.volume - 0.1, 0); flash("🔊 \(Int(player.volume * 100))%")
        case 53: onClose?()                   // esc
        case 3: window?.toggleFullScreen(nil) // f
        default: super.keyDown(with: event)
        }
    }
}

/// In-window photo viewer: fit to the window, scroll or pinch to zoom, double-click toggles zoom,
/// click the close button or press Esc to return to the feed.
/// Media viewer for a post inside the main window: ← → (or the arrow buttons, or a sideways
/// two-finger swipe) go through every photo and video of the post; double-click or pinch zooms;
/// Esc or ✕ closes; the share button and ⌘C hand the current file to other apps. Share and close
/// sit in the bottom-right corner; every button is a dark translucent circle.
final class MacPhotoView: NSView {
    var onClose: (() -> Void)?
    private let items: [FeedItem]
    /// A video of the list is shown by the player itself, as a page (it plays when turned to).
    private var player: MacPlayerView?
    /// Where the first video starts (it was already playing in the feed).
    private var videoStart: CMTime
    private(set) var index: Int
    private let scroll = PagingScrollView()
    private let image = NSImageView()
    private let close = ViewerRoundButton(diameter: 34)
    private let share = ViewerRoundButton(diameter: 34)
    private let prev = ViewerRoundButton(diameter: 40)
    private let next = ViewerRoundButton(diameter: 40)
    private let counter = NSTextField(labelWithString: "")
    private var swipeAccum: CGFloat = 0
    private var swiped = false

    convenience init(url: URL) {
        self.init(items: [FeedItem(mediaId: url.lastPathComponent, postId: "", ordinal: 0, kind: .photo, path: url.path, text: nil, authorName: nil, screenName: nil, url: nil, tags: [])], index: 0)
    }

    init(items: [FeedItem], index: Int, videoStart: CMTime = .zero) {
        self.items = items
        self.index = max(0, min(index, items.count - 1))
        self.videoStart = videoStart
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        setAccessibilityIdentifier("photoViewer")
        scroll.allowsMagnification = true
        scroll.minMagnification = 1
        scroll.maxMagnification = 6
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        image.imageScaling = .scaleProportionallyUpOrDown
        image.autoresizingMask = [.width, .height]
        scroll.documentView = image
        // the zoomable image takes the scroll events first: sideways swipes come back here
        scroll.onSwipe = { [weak self] e in self?.swipe(e) ?? false }
        func style(_ b: NSButton, _ sym: String, _ label: String, _ id: String, _ sel: Selector, size: CGFloat = 14) {
            b.image = NSImage(systemSymbolName: sym, accessibilityDescription: label)
            b.symbolConfiguration = .init(pointSize: size, weight: .semibold)
            b.toolTip = label
            b.target = self
            b.action = sel
            b.setAccessibilityIdentifier(id)
        }
        style(close, "xmark", "关闭（Esc）", "photoClose", #selector(closeTapped))
        style(share, "square.and.arrow.up", "分享（⌘C 拷贝）", "photoShare", #selector(shareTapped))
        style(prev, "chevron.left", "上一张（←）", "photoPrev", #selector(goPrev), size: 16)
        style(next, "chevron.right", "下一张（→）", "photoNext", #selector(goNext), size: 16)
        counter.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        counter.textColor = .white
        counter.setAccessibilityIdentifier("photoCounter")
        [scroll, close, share, prev, next, counter].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; addSubview($0) }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor), scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor), scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            close.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -20), close.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            share.centerYAnchor.constraint(equalTo: close.centerYAnchor), share.trailingAnchor.constraint(equalTo: close.leadingAnchor, constant: -10),
            // below the (transparent) title bar strip
            counter.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 16), counter.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            prev.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20), prev.centerYAnchor.constraint(equalTo: centerYAnchor),
            next.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20), next.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        show()
    }
    required init?(coder: NSCoder) { fatalError() }

    var current: FeedItem { items[index] }

    private func show() {
        let it = current
        scroll.magnification = 1
        image.image = nil
        let multi = items.count > 1
        prev.isHidden = !multi || index == 0
        next.isHidden = !multi || index == items.count - 1
        // the position within the current post
        let post = items[index].postId
        var lo = index, hi = index
        while lo > 0, items[lo - 1].postId == post, !post.isEmpty { lo -= 1 }
        while hi < items.count - 1, items[hi + 1].postId == post, !post.isEmpty { hi += 1 }
        counter.stringValue = multi && hi > lo ? "\(index - lo + 1) / \(hi - lo + 1)" : ""
        counter.setAccessibilityValue(counter.stringValue)
        player?.teardown()
        player?.removeFromSuperview()
        player = nil
        // a video: the player is the page (its own share and close; the arrows stay above it)
        if it.kind == .video {
            let p = MacPlayerView(url: it.fileURL, startAt: videoStart)
            videoStart = .zero      // only the video that was opened goes on from where the feed was
            p.embedded = true
            p.onClose = { [weak self] in self?.onClose?() }
            p.translatesAutoresizingMaskIntoConstraints = false
            addSubview(p, positioned: .above, relativeTo: scroll)
            NSLayoutConstraint.activate([p.topAnchor.constraint(equalTo: topAnchor), p.bottomAnchor.constraint(equalTo: bottomAnchor),
                                         p.leadingAnchor.constraint(equalTo: leadingAnchor), p.trailingAnchor.constraint(equalTo: trailingAnchor)])
            player = p
        }
        scroll.isHidden = it.kind == .video
        close.isHidden = it.kind == .video
        share.isHidden = it.kind == .video
        guard it.kind == .photo else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let img = NSImage(contentsOf: it.fileURL)
            DispatchQueue.main.async { if self.current.mediaId == it.mediaId { self.image.image = img } }
        }
    }

    /// Stops the video on screen (the viewer is closing).
    func teardown() { player?.teardown() }

    @objc func goPrev() { guard index > 0 else { return }; index -= 1; show(); window?.makeFirstResponder(self) }
    @objc func goNext() { guard index < items.count - 1 else { return }; index += 1; show(); window?.makeFirstResponder(self) }

    override func layout() {
        super.layout()
        if scroll.magnification <= 1.001 { image.frame = scroll.contentView.bounds }
    }

    override var acceptsFirstResponder: Bool { true }
    @objc private func closeTapped() { onClose?() }
    @objc private func shareTapped() { NSSharingServicePicker(items: [current.fileURL]).show(relativeTo: share.bounds, of: share, preferredEdge: .minY) }
    /// ⌘C: the file (and, for a photo, the image) on the clipboard.
    @objc func copy(_ sender: Any?) {
        let pb = NSPasteboard.general
        pb.clearContents()
        var objs: [NSPasteboardWriting] = [current.fileURL as NSURL]
        if current.kind == .photo, let img = image.image { objs.append(img) }
        pb.writeObjects(objs)
    }
    override func keyDown(with event: NSEvent) {
        // on a video whose sideways drag seeks, ← → seek too (the arrow buttons turn the page)
        if let p = player {
            if p.dragSeeks, event.keyCode == 123 { p.seek(by: -5); return }
            if p.dragSeeks, event.keyCode == 124 { p.seek(by: 5); return }
            if p.handleViewerKey(event) { return }
        }
        switch event.keyCode {
        case 53: onClose?()
        case 123: goPrev()
        case 124: goNext()
        default:
            if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "c" { copy(nil) } else { super.keyDown(with: event) }
        }
    }
    /// A sideways two-finger swipe pages: the photo follows the fingers, and on release it goes
    /// on to the next (or previous) one, or back. Only when not zoomed in. Returns whether the
    /// event was used.
    /// The two-finger swipe over a video (the player passes scroll events on).
    override func scrollWheel(with e: NSEvent) { if player == nil || !swipe(e) { super.scrollWheel(with: e) } }

    private func swipe(_ e: NSEvent) -> Bool {
        guard items.count > 1, scroll.magnification <= 1.001, e.hasPreciseScrollingDeltas else { return false }
        let page: NSView = player ?? scroll
        if !e.momentumPhase.isEmpty { return false }
        if e.phase == .began { swipeAccum = 0; swiped = false }
        guard swiped || abs(e.scrollingDeltaX) > abs(e.scrollingDeltaY) * 1.5 else { return false }
        swiped = true
        page.wantsLayer = true
        swipeAccum += e.scrollingDeltaX
        // resistance at the first and last photo
        let atEnd = (swipeAccum > 0 && index == 0) || (swipeAccum < 0 && index == items.count - 1)
        page.layer?.setAffineTransform(CGAffineTransform(translationX: atEnd ? swipeAccum * 0.3 : swipeAccum, y: 0))
        if e.phase == .ended || e.phase == .cancelled {
            let w = max(bounds.width, 1)
            let go = !atEnd && abs(swipeAccum) > w * 0.18
            let forward = swipeAccum < 0
            swipeAccum = 0
            swiped = false
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.2; ctx.timingFunction = .springy
                ctx.allowsImplicitAnimation = true
                page.layer?.setAffineTransform(go ? CGAffineTransform(translationX: forward ? -w : w, y: 0) : .identity)
            }, completionHandler: { [weak self] in
                guard let self, go else { return }
                page.layer?.setAffineTransform(.identity)
                if forward { self.goNext() } else { self.goPrev() }
                // the new page comes in from the other side
                let incoming: NSView = self.player ?? self.scroll
                incoming.wantsLayer = true
                incoming.layer?.setAffineTransform(CGAffineTransform(translationX: forward ? w : -w, y: 0))
                NSAnimationContext.runAnimationGroup { c in
                    c.duration = 0.22; c.timingFunction = .springy
                    c.allowsImplicitAnimation = true
                    incoming.layer?.setAffineTransform(.identity)
                }
            })
        }
        return true
    }

    override func mouseDown(with event: NSEvent) {
        guard event.clickCount == 2, current.kind == .photo else { return }
        let p = scroll.contentView.convert(event.locationInWindow, from: nil)
        if scroll.magnification > 1.01 { scroll.animator().magnification = 1 } else { scroll.animator().setMagnification(2.5, centeredAt: p) }
    }
}

/// The viewer's zoomable image: sideways two-finger swipes go to the viewer (to page) unless it
/// is zoomed in; everything else scrolls and zooms as usual.
final class PagingScrollView: NSScrollView {
    var onSwipe: ((NSEvent) -> Bool)?
    override func scrollWheel(with e: NSEvent) {
        if onSwipe?(e) == true { return }
        super.scrollWheel(with: e)
    }
}

/// A viewer control: a white symbol on a dark translucent circle (no white disc), slightly
/// brighter while hovered and pressed.
final class ViewerRoundButton: NSButton {
    private let diameter: CGFloat
    private var hovering = false { didSet { restyle() } }

    init(diameter: CGFloat) {
        self.diameter = diameter
        super.init(frame: .zero)
        isBordered = false
        imagePosition = .imageOnly
        contentTintColor = .white
        wantsLayer = true
        layer?.cornerRadius = diameter / 2
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
        restyle()
        widthAnchor.constraint(equalToConstant: diameter).isActive = true
        heightAnchor.constraint(equalToConstant: diameter).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: diameter, height: diameter) }
    // a symbol image gives the button alignment insets, which would stretch the circle
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }
    override var isHighlighted: Bool { didSet { restyle() } }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    private func restyle() {
        let a: CGFloat = isHighlighted ? 0.7 : hovering ? 0.55 : 0.4
        layer?.backgroundColor = NSColor.black.withAlphaComponent(a).cgColor
    }
}
