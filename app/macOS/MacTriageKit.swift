import AppKit

// The pieces 整理 is made of on the Mac, kept plain: the media as a picture on the window's own
// background, its text under it in the usual hierarchy, and ordinary system buttons.

// MARK: - Buttons

enum MacTriageButtons {
    /// A system button with a coloured symbol, a title and, quietly, its key.
    static func make(_ title: String, symbol: String, color: NSColor? = nil, key: String? = nil, large: Bool = false, id: String, action: @escaping () -> Void) -> ClosureButton {
        let b = ClosureButton(title: title, action: action)
        let cfg = NSImage.SymbolConfiguration(pointSize: large ? 15 : 13, weight: .medium)
        let base = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?.withSymbolConfiguration(cfg)
        b.image = color.flatMap { c in base?.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [c])) } ?? base
        b.imagePosition = .imageLeading
        b.imageHugsTitle = true
        b.controlSize = large ? .large : .regular
        if let key {
            let t = NSMutableAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: large ? 14 : 13)])
            t.append(NSAttributedString(string: "  \(key)", attributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular), .foregroundColor: NSColor.tertiaryLabelColor]))
            b.attributedTitle = t
        }
        b.toolTip = key.map { "\(title)（\($0)）" } ?? title
        b.setAccessibilityLabel(title)
        b.setAccessibilityIdentifier(id)
        return b
    }
}

// MARK: - The picture

/// The media of the post on screen: a picture with rounded corners and a soft shadow that hugs the
/// media (never a grey box around it), a play mark on a video, and the stamp that shows what a
/// decision does while it flies off.
final class MacTriagePhoto: NSView {
    private let clip = NSView()
    private let imageView = NSImageView()
    private let play = NSImageView()
    let stamp = NSTextField(labelWithString: "")

    /// width / height of the picture shown (a portrait guess until one is set).
    var aspect: CGFloat { guard let s = imageView.image?.size, s.width > 0, s.height > 0 else { return 0.75 }; return s.width / s.height }
    var hasImage: Bool { imageView.image != nil }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.16
        layer?.shadowRadius = 14
        layer?.shadowOffset = CGSize(width: 0, height: -4)
        clip.wantsLayer = true
        clip.layer?.cornerRadius = 12
        clip.layer?.cornerCurve = .continuous
        clip.layer?.masksToBounds = true
        clip.layer?.borderWidth = 0.5
        clip.layer?.borderColor = NSColor.separatorColor.cgColor
        clip.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        imageView.imageScaling = .scaleAxesIndependently
        imageView.setAccessibilityIdentifier("triageMedia")
        play.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: "视频")?.withSymbolConfiguration(.init(pointSize: 20, weight: .semibold))
        play.contentTintColor = .white
        play.wantsLayer = true
        play.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.45).cgColor
        play.layer?.cornerRadius = 25
        play.isHidden = true
        stamp.font = .systemFont(ofSize: 20, weight: .bold)
        stamp.textColor = .white
        stamp.wantsLayer = true
        stamp.layer?.cornerRadius = 8
        stamp.layer?.cornerCurve = .continuous
        stamp.alignment = .center
        stamp.alphaValue = 0
        for v in [imageView, play, stamp] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; clip.addSubview(v) }
        clip.translatesAutoresizingMaskIntoConstraints = false
        addSubview(clip)
        NSLayoutConstraint.activate([
            clip.topAnchor.constraint(equalTo: topAnchor), clip.bottomAnchor.constraint(equalTo: bottomAnchor),
            clip.leadingAnchor.constraint(equalTo: leadingAnchor), clip.trailingAnchor.constraint(equalTo: trailingAnchor),
            imageView.topAnchor.constraint(equalTo: clip.topAnchor), imageView.bottomAnchor.constraint(equalTo: clip.bottomAnchor),
            imageView.leadingAnchor.constraint(equalTo: clip.leadingAnchor), imageView.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            play.centerXAnchor.constraint(equalTo: clip.centerXAnchor), play.centerYAnchor.constraint(equalTo: clip.centerYAnchor),
            play.widthAnchor.constraint(equalToConstant: 50), play.heightAnchor.constraint(equalToConstant: 50),
            stamp.centerXAnchor.constraint(equalTo: clip.centerXAnchor), stamp.topAnchor.constraint(equalTo: clip.topAnchor, constant: 22),
            stamp.heightAnchor.constraint(equalToConstant: 36),
        ])
        setAccessibilityIdentifier("triageCard")
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: 12, cornerHeight: 12, transform: nil)
        CATransaction.commit()
    }

    func setImage(_ image: NSImage?) { imageView.image = image; needsLayout = true; superview?.needsLayout = true }

    func setPage(_ i: Int, of n: Int, kind: MediaKind) {
        play.isHidden = kind != .video
        imageView.setAccessibilityLabel((kind == .video ? "视频" : "照片") + (n > 1 ? "，第 \(i + 1)/\(n) 个" : ""))
    }

    func showStamp(_ text: String, color: NSColor) {
        stamp.stringValue = "  \(text)  "
        stamp.layer?.backgroundColor = color.cgColor
        stamp.alphaValue = 0.95
    }
    func hideStamp() { stamp.alphaValue = 0 }
}

// MARK: - The text of the post

/// Under the picture: the author, then the text (two lines at most) — or, for a loose media, just
/// that. Always the same height, so nothing around it moves from post to post.
final class MacTriageCaption: NSView {
    static let height: CGFloat = 62
    private let who = NSTextField(labelWithString: "")
    private let words = NSTextField(wrappingLabelWithString: "")
    private let stack = NSStackView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        who.font = .systemFont(ofSize: 13, weight: .semibold)
        who.textColor = .labelColor
        who.lineBreakMode = .byTruncatingTail
        words.font = .systemFont(ofSize: 13)
        words.textColor = .secondaryLabelColor
        words.maximumNumberOfLines = 2
        words.lineBreakMode = .byWordWrapping
        words.cell?.truncatesLastVisibleLine = true      // two lines, the second ending in … when there is more
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        stack.addArrangedSubview(who)
        stack.addArrangedSubview(words)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([stack.topAnchor.constraint(equalTo: topAnchor), stack.leadingAnchor.constraint(equalTo: leadingAnchor),
                                     stack.trailingAnchor.constraint(equalTo: trailingAnchor)])
    }
    required init?(coder: NSCoder) { fatalError() }

    /// The text wraps at the width it is given: set before the layout that needs it.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        let w = max(60, newSize.width)
        if words.preferredMaxLayoutWidth != w { words.preferredMaxLayoutWidth = w; words.invalidateIntrinsicContentSize() }
    }

    func configure(_ unit: Core.TriageUnit) {
        let first = unit.items[0]
        if first.isLoose {
            who.stringValue = "散装媒体"
            words.stringValue = "不属于任何帖子，每个文件单独整理"
        } else {
            who.stringValue = [first.authorName, first.screenName.map { "@\($0)" }].compactMap { $0 }.joined(separator: "  ")
            words.stringValue = first.text ?? ""
        }
        who.isHidden = who.stringValue.isEmpty
        words.isHidden = words.stringValue.isEmpty
    }
}

/// The picture, the small pictures of the post's other media, and the text: the picture takes the
/// room that is left, whatever its shape (the folders and the buttons below never depend on it).
final class MacTriageStage: NSView {
    let photo = MacTriagePhoto()
    let strip = NSStackView()
    let caption = MacTriageCaption()
    /// Height kept under the picture for the strip (0 for a post with one media).
    var stripHeight: CGFloat = 0 { didSet { needsLayout = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        strip.orientation = .horizontal
        strip.spacing = 8
        strip.alignment = .centerY
        addSubview(photo)
        addSubview(strip)
        addSubview(caption)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let below = MacTriageCaption.height + 12 + (stripHeight > 0 ? stripHeight + 12 : 0)
        let room = NSRect(x: 0, y: below, width: bounds.width, height: max(0, bounds.height - below))
        guard room.width > 0, room.height > 0 else { return }
        let a = photo.aspect
        var w = room.width, h = room.width / a
        if h > room.height { h = room.height; w = h * a }
        // the picture, the strip and the text are one block, centred in the stage: the text stays
        // right under the picture whatever its shape (the buttons below the stage never move)
        let block = h + 12 + (stripHeight > 0 ? stripHeight + 12 : 0) + MacTriageCaption.height
        let bottom = max(0, ((bounds.height - block) / 2).rounded())
        let captionY = bottom
        let stripY = captionY + MacTriageCaption.height + 12
        let photoY = stripY + (stripHeight > 0 ? stripHeight + 12 : 0)
        let frame = NSRect(x: (room.midX - w / 2).rounded(), y: photoY, width: w.rounded(), height: h.rounded())
        photo.frame = frame
        // the text starts where the picture does, and is as wide as it is (never narrower than a readable line)
        let cw = max(frame.width, min(bounds.width, 360))
        caption.frame = NSRect(x: (bounds.midX - cw / 2).rounded(), y: captionY, width: cw, height: MacTriageCaption.height)
        if stripHeight > 0 {
            let size = strip.fittingSize
            strip.frame = NSRect(x: (bounds.midX - size.width / 2).rounded(), y: stripY, width: size.width, height: stripHeight)
        }
    }
}

/// A small picture of one media of the post, ringed in the accent colour when it is the one shown.
final class MacTriageThumb: NSControl {
    var onClick: (() -> Void)?
    private let pic = CALayer()
    var selectedThumb = false { didSet { refresh() } }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderColor = NSColor.controlAccentColor.cgColor
        layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        pic.contentsGravity = .resizeAspectFill      // fills the square: cropped, not squashed
        layer?.addSublayer(pic)
        widthAnchor.constraint(equalToConstant: 40).isActive = true
        heightAnchor.constraint(equalToConstant: 40).isActive = true
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        pic.frame = bounds
        CATransaction.commit()
    }
    func setImage(_ i: NSImage?) { pic.contents = i?.cgImage(forProposedRect: nil, context: nil, hints: nil) }
    private func refresh() {
        layer?.borderWidth = selectedThumb ? 2.5 : 0
        alphaValue = selectedThumb ? 1 : 0.65
    }
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
