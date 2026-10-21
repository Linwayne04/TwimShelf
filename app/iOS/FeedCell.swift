import UIKit
import AVFoundation

/// One media page: poster/photo plus an optional inline video layer.
final class MediaPageView: UIView {
    let imageView = UIImageView()
    let playBadge = UIImageView(image: UIImage(systemName: "play.fill"))
    let playerLayer = AVPlayerLayer()
    private let badBadge = PaddedLabel()
    private(set) var item: FeedItem?

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        backgroundColor = .black
        imageView.contentMode = .scaleAspectFit
        playerLayer.videoGravity = .resizeAspect
        playBadge.tintColor = .white
        playBadge.contentMode = .center
        playBadge.backgroundColor = UIColor.black.withAlphaComponent(0.45)
        playBadge.layer.cornerRadius = 22
        playBadge.preferredSymbolConfiguration = .init(pointSize: 18, weight: .bold)
        addSubview(imageView)
        layer.addSublayer(playerLayer)
        addSubview(playBadge)
        badBadge.text = "⚠︎ 文件已损坏"
        badBadge.font = .systemFont(ofSize: 12, weight: .bold)
        badBadge.textColor = .white
        badBadge.backgroundColor = UIColor.systemRed.withAlphaComponent(0.85)
        badBadge.layer.cornerRadius = 10
        badBadge.clipsToBounds = true
        badBadge.isHidden = true
        badBadge.accessibilityIdentifier = "badBadge"
        addSubview(badBadge)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        imageView.frame = bounds
        CATransaction.begin(); CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
        playBadge.frame = CGRect(x: bounds.midX - 22, y: bounds.midY - 22, width: 44, height: 44)
        let s = badBadge.intrinsicContentSize
        badBadge.frame = CGRect(x: 12, y: 12, width: s.width, height: s.height)
    }

    /// One decode size for every card (≈ card width in pixels), so prefetch and display share cache entries.
    static var pixelSize: CGFloat {
        let screen = UIScreen.main
        return min(screen.bounds.width, 440) * screen.scale
    }

    static func prefetch(_ item: FeedItem) { MediaLoader.shared.load(item, maxPixel: pixelSize) { _ in } }

    /// New data for the same media (tags, damage state): badges only.
    func update(_ item: FeedItem) {
        self.item = item
        badBadge.isHidden = item.bad == nil
        badBadge.text = item.badText
    }

    func configure(_ item: FeedItem) {
        self.item = item
        playBadge.isHidden = item.kind != .video
        badBadge.isHidden = item.bad == nil
        badBadge.text = item.badText
        setNeedsLayout()
        isAccessibilityElement = true
        accessibilityIdentifier = item.kind == .video ? "media-video" : "media-photo"
        accessibilityTraits = .button
        playerLayer.player = nil
        let px = Self.pixelSize
        if let img = MediaLoader.shared.cached(item, maxPixel: px) { imageView.image = img; return }
        imageView.image = nil
        let id = item.mediaId
        MediaLoader.shared.load(item, maxPixel: px) { [weak self] img in
            if img == nil { MediaLoader.shared.reportIfBroken(item) }
            guard self?.item?.mediaId == id else { return }
            self?.imageView.image = img
        }
    }
}

protocol FeedCellDelegate: AnyObject {
    func feedCell(_ cell: FeedCell, didTapPage index: Int)
    func feedCell(_ cell: FeedCell, didTapTag label: String)
    func feedCellPageDidChange(_ cell: FeedCell)
    func feedCellDidTapAddTag(_ cell: FeedCell)
    func feedCell(_ cell: FeedCell, menuForTag tag: TagView, of item: FeedItem) -> UIMenu
    func feedCellDidTapRecent(_ cell: FeedCell)
}

/// A card: media pager (one page, or a post's whole group) above the caption.
final class FeedCell: UICollectionViewCell, UIScrollViewDelegate {
    private let textMenu = PostTextMenu()
    static let reuseID = "FeedCell"
    weak var delegate: FeedCellDelegate?
    private(set) var items: [FeedItem] = []
    private(set) var page = 0

    private let pager = PagerScrollView()
    private var pages: [MediaPageView] = []
    private let counter = PaddedLabel()
    private let authorLabel = UILabel()
    private let bodyLabel = UILabel()
    private let linkButton = UIButton(type: .system)
    private let tagStack = UIStackView()
    private let tagScroll = UIScrollView()

    var currentItem: FeedItem? { items.indices.contains(page) ? items[page] : nil }
    var currentPageView: MediaPageView? { pages.indices.contains(page) ? pages[page] : nil }

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = .secondarySystemGroupedBackground
        contentView.layer.cornerRadius = 22
        contentView.layer.cornerCurve = .continuous
        contentView.clipsToBounds = true

        pager.isPagingEnabled = true
        pager.showsHorizontalScrollIndicator = false
        pager.delegate = self
        pager.onResize = { [weak self] in self?.layoutPages() }
        pager.backgroundColor = .black
        pager.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))

        counter.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        counter.textColor = .white
        counter.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        counter.layer.cornerRadius = 10
        counter.clipsToBounds = true

        authorLabel.font = .preferredFont(forTextStyle: .subheadline)
        authorLabel.adjustsFontForContentSizeCategory = true
        bodyLabel.font = .preferredFont(forTextStyle: .body)
        bodyLabel.adjustsFontForContentSizeCategory = true
        bodyLabel.numberOfLines = 3
        // Long-press the text: copy it (its own menu, so the card's menu does not open);
        // anywhere else on the card still opens the card's menu.
        bodyLabel.isUserInteractionEnabled = true
        bodyLabel.accessibilityIdentifier = "postText"
        bodyLabel.addInteraction(UIContextMenuInteraction(delegate: textMenu))
        textMenu.text = { [weak self] in self?.currentItem?.text }
        linkButton.titleLabel?.font = .preferredFont(forTextStyle: .footnote)
        linkButton.titleLabel?.lineBreakMode = .byTruncatingMiddle
        linkButton.contentHorizontalAlignment = .leading
        // Fixed 20 pt line so the caption matches FeedCell.height exactly (no hidden insets).
        linkButton.contentEdgeInsets = .zero
        linkButton.heightAnchor.constraint(equalToConstant: 20).isActive = true
        linkButton.addTarget(self, action: #selector(openLink), for: .touchUpInside)

        tagStack.axis = .horizontal
        tagStack.spacing = 6
        tagScroll.showsHorizontalScrollIndicator = false
        // the row spans the whole card and its inset moves the chips in: scrolled chips then end at
        // the card's own edge, not at an invisible line 16 pt inside it
        tagScroll.contentInset = UIEdgeInsets(top: 0, left: 16, bottom: 0, right: 16)
        tagScroll.addSubview(tagStack)
        tagStack.translatesAutoresizingMaskIntoConstraints = false

        let caption = UIStackView(arrangedSubviews: [authorLabel, bodyLabel, linkButton])
        // Long text yields first; the tag row (pinned below) is always visible.
        bodyLabel.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        tagScroll.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(tagScroll)
        caption.axis = .vertical
        caption.spacing = 6
        caption.setCustomSpacing(2, after: bodyLabel)

        [pager, counter, caption].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; contentView.addSubview($0) }
        let pagerHeight = pager.heightAnchor.constraint(equalTo: pager.widthAnchor, multiplier: 1.25)
        pagerHeight.priority = .required - 1
        NSLayoutConstraint.activate([
            pager.topAnchor.constraint(equalTo: contentView.topAnchor),
            pager.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            pager.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            pagerHeight,
            counter.topAnchor.constraint(equalTo: pager.topAnchor, constant: 12),
            counter.trailingAnchor.constraint(equalTo: pager.trailingAnchor, constant: -12),
            caption.topAnchor.constraint(equalTo: pager.bottomAnchor, constant: 12),
            caption.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            caption.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            tagScroll.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            tagScroll.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            tagScroll.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -14),
            caption.bottomAnchor.constraint(lessThanOrEqualTo: tagScroll.topAnchor, constant: -6),
            tagScroll.heightAnchor.constraint(equalToConstant: 26),
            tagStack.topAnchor.constraint(equalTo: tagScroll.contentLayoutGuide.topAnchor),
            tagStack.bottomAnchor.constraint(equalTo: tagScroll.contentLayoutGuide.bottomAnchor),
            tagStack.leadingAnchor.constraint(equalTo: tagScroll.contentLayoutGuide.leadingAnchor),
            tagStack.trailingAnchor.constraint(equalTo: tagScroll.contentLayoutGuide.trailingAnchor),
            tagStack.heightAnchor.constraint(equalTo: tagScroll.frameLayoutGuide.heightAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Called by the pager when its size or page count changes.
    private func layoutPages() {
        let w = pager.bounds.width, h = pager.bounds.height
        guard w > 0 else { return }
        for (i, v) in pages.enumerated() { v.frame = CGRect(x: CGFloat(i) * w, y: 0, width: w, height: h) }
        pager.contentSize = CGSize(width: w * CGFloat(pages.count), height: h)
        pager.contentOffset.x = CGFloat(page) * w
        for (v, it) in zip(pages, items) where v.imageView.image == nil { v.configure(it) }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        pages.forEach { $0.playerLayer.player = nil }
        // a reused cell always gets a full configure (refresh() is for cells still on screen)
        items = []
    }

    /// Same media as shown: update tags, text and badges in place (no image reload, the current
    /// page and an inline video keep going). Otherwise a full configure.
    /// The words being searched for: every occurrence in the author, text and tags is highlighted.
    var highlight: [String] = [] { didSet { if highlight != oldValue, currentItem != nil { updateCaption() } } }
    static let highlightAttrs: [NSAttributedString.Key: Any] = [.backgroundColor: UIColor.systemYellow.withAlphaComponent(0.45)]

    func refresh(_ items: [FeedItem]) {
        guard items.map(\.mediaId) == self.items.map(\.mediaId), !items.isEmpty else { return configure(items) }
        self.items = items
        for (v, it) in zip(pages, items) { v.update(it) }
        updateCaption()
    }

    func configure(_ items: [FeedItem]) {
        self.items = items
        page = 0
        while pages.count < items.count { let v = MediaPageView(); pages.append(v); pager.addSubview(v) }
        while pages.count > items.count { pages.removeLast().removeFromSuperview() }
        for (v, it) in zip(pages, items) { v.configure(it) }
        pager.isScrollEnabled = items.count > 1
        pager.contentOffset = .zero
        layoutPages()
        updateCaption()
    }

    private func updateCaption() {
        guard let it = currentItem else { return }
        counter.isHidden = items.count < 2
        counter.text = "\(page + 1)/\(items.count)"

        let author = NSMutableAttributedString()
        if it.isLoose {
            // Loose media has no post: a distinct marker instead of author, text and link.
            let icon = NSTextAttachment(image: UIImage(systemName: "square.dashed")!.withTintColor(.systemIndigo))
            author.append(NSAttributedString(attachment: icon))
            author.append(NSAttributedString(string: " 散装媒体", attributes: [.font: UIFont.preferredFont(forTextStyle: .headline), .foregroundColor: UIColor.systemIndigo]))
        }
        if let name = it.authorName {
            author.append(NSAttributedString(string: name, attributes: [.font: UIFont.preferredFont(forTextStyle: .headline), .foregroundColor: UIColor.label]))
        }
        if let sn = it.screenName {
            author.append(NSAttributedString(string: (author.length > 0 ? "  " : "") + "@\(sn)", attributes: [.foregroundColor: UIColor.secondaryLabel]))
        }
        SearchHighlight.apply(highlight, to: author, Self.highlightAttrs)
        authorLabel.attributedText = author
        authorLabel.isHidden = author.length == 0
        let body = NSMutableAttributedString(string: it.text ?? "", attributes: [.font: bodyLabel.font as Any, .foregroundColor: bodyLabel.textColor as Any])
        SearchHighlight.apply(highlight, to: body, Self.highlightAttrs)
        bodyLabel.attributedText = body
        bodyLabel.isHidden = (it.text ?? "").isEmpty
        linkButton.setTitle(it.url, for: .normal)
        linkButton.isHidden = it.url == nil

        tagStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        // a reused card keeps the old row's scroll position: the first chip would start cut off
        tagScroll.setContentOffset(CGPoint(x: -tagScroll.contentInset.left, y: 0), animated: false)
        if it.isRecent { tagStack.addArrangedSubview(TagChip.recent(target: self, action: #selector(recentTapped))) }
        for t in it.tags {
            let chip = TagChip.make(t, target: self, action: #selector(tagTapped(_:)), highlight: highlight)
            // Long-press a tag: only this tag, search, endorse, delete.
            chip.menu = delegate?.feedCell(self, menuForTag: t, of: it)
            chip.showsMenuAsPrimaryAction = false
            tagStack.addArrangedSubview(chip)
        }
        tagStack.addArrangedSubview(TagChip.addButton(target: self, action: #selector(addTagTapped)))
    }

    @objc private func tagTapped(_ b: UIButton) {
        if let label = b.accessibilityIdentifier { delegate?.feedCell(self, didTapTag: label) }
    }
    @objc private func recentTapped() { delegate?.feedCellDidTapRecent(self) }
    @objc private func addTagTapped() { UISelectionFeedbackGenerator().selectionChanged(); delegate?.feedCellDidTapAddTag(self) }
    @objc private func tapped() { delegate?.feedCell(self, didTapPage: page) }
    @objc private func openLink() {
        if let s = currentItem?.url, let u = URL(string: s) { UIApplication.shared.open(u) }
    }

    func scrollViewDidScroll(_ sv: UIScrollView) {
        guard sv.bounds.width > 0 else { return }
        let p = min(max(Int((sv.contentOffset.x / sv.bounds.width).rounded()), 0), max(items.count - 1, 0))
        if p != page { page = p; updateCaption(); delegate?.feedCellPageDidChange(self) }
    }
}

extension FeedCell {
    /// Every card has the same height for a given width: media 4:5 plus a caption block sized
    /// for author + 3 lines of text + link + tags. Exact heights mean the list never has to
    /// self-size cells or re-place everything after them while scrolling.
    static func height(width: CGFloat, traits: UITraitCollection) -> CGFloat {
        let f = { (s: UIFont.TextStyle) in UIFont.preferredFont(forTextStyle: s, compatibleWith: traits).lineHeight }
        let caption = 12 + f(.headline) + 6 + ceil(f(.body) * 3) + 2 + 20 + 6 + 26 + 14 + 2
        return ceil(width * 1.25 + caption)
    }
}

/// Tag capsule colored by origin: blue = mine, purple = AI, green = endorsed (both).
enum TagChip {
    static func color(_ t: TagView) -> UIColor {
        t.isUser && t.isAI ? .systemGreen : (t.isAI ? .systemPurple : .systemBlue)
    }
    static func make(_ t: TagView, target: Any?, action: Selector, highlight: [String] = []) -> UIButton {
        var cfg = UIButton.Configuration.filled()
        let marks = SearchHighlight.ranges(of: highlight, in: t.label)
        if marks.isEmpty { cfg.title = t.label } else {
            let a = NSMutableAttributedString(string: t.label)
            for r in marks { a.addAttributes(FeedCell.highlightAttrs, range: r) }
            cfg.attributedTitle = AttributedString(a)
        }
        cfg.image = t.isAI ? UIImage(systemName: t.isUser ? "checkmark.seal.fill" : "sparkles") : nil
        cfg.imagePadding = 4
        cfg.preferredSymbolConfigurationForImage = .init(pointSize: 10, weight: .semibold)
        cfg.cornerStyle = .capsule
        cfg.baseBackgroundColor = color(t).withAlphaComponent(0.15)
        cfg.baseForegroundColor = color(t)
        cfg.contentInsets = .init(top: 4, leading: 10, bottom: 4, trailing: 10)
        cfg.titleTextAttributesTransformer = .init { var a = $0; a.font = .systemFont(ofSize: 13, weight: .medium); return a }
        let b = UIButton(configuration: cfg)
        b.accessibilityIdentifier = t.label
        if !t.models.isEmpty { b.accessibilityHint = "由 " + t.models.map { ModelStore.shared.displayName($0) }.joined(separator: "、") + " 标记" }
        b.addTarget(target, action: action, for: .touchUpInside)
        return b
    }
}

extension TagChip {
    /// The "+" chip at the end of every tag row.
    /// "最近添加": not a tag (cannot be edited or removed); it expires 5 days after the download.
    static func recent(target: Any?, action: Selector) -> UIButton {
        var cfg = UIButton.Configuration.filled()
        cfg.title = "最近添加"
        cfg.image = UIImage(systemName: "clock.badge.checkmark")
        cfg.imagePadding = 4
        cfg.preferredSymbolConfigurationForImage = .init(pointSize: 10, weight: .bold)
        cfg.cornerStyle = .capsule
        cfg.baseBackgroundColor = .systemOrange
        cfg.baseForegroundColor = .white
        cfg.contentInsets = .init(top: 4, leading: 10, bottom: 4, trailing: 10)
        cfg.titleTextAttributesTransformer = .init { var a = $0; a.font = .systemFont(ofSize: 13, weight: .bold); return a }
        let b = UIButton(configuration: cfg)
        b.accessibilityIdentifier = "recentBadge"
        b.accessibilityHint = "批量下载的帖子，5 天后自动消失。轻点只看最近添加"
        b.addTarget(target, action: action, for: .touchUpInside)
        return b
    }

    static func addButton(target: Any?, action: Selector) -> UIButton {
        var cfg = UIButton.Configuration.gray()
        cfg.image = UIImage(systemName: "plus")
        cfg.preferredSymbolConfigurationForImage = .init(pointSize: 11, weight: .bold)
        cfg.cornerStyle = .capsule
        cfg.contentInsets = .init(top: 4, leading: 9, bottom: 4, trailing: 9)
        let b = UIButton(configuration: cfg)
        b.accessibilityLabel = "添加标签"
        b.accessibilityIdentifier = "addTag"
        b.addTarget(target, action: action, for: .touchUpInside)
        return b
    }
}

final class PaddedLabel: UILabel {
    var insets = UIEdgeInsets(top: 3, left: 8, bottom: 3, right: 8)
    override func drawText(in rect: CGRect) { super.drawText(in: rect.inset(by: insets)) }
    override var intrinsicContentSize: CGSize {
        let s = super.intrinsicContentSize
        return CGSize(width: s.width + insets.left + insets.right, height: s.height + insets.top + insets.bottom)
    }
}

/// Scroll view that reports size changes, so pages are laid out once its real size is known.
final class PagerScrollView: UIScrollView {
    var onResize: (() -> Void)?
    private var lastSize = CGSize.zero
    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.size != lastSize { lastSize = bounds.size; onResize?() }
    }
}


/// The post text's long-press menu: copy all of it (and read it in full when it is cut off).
final class PostTextMenu: NSObject, UIContextMenuInteractionDelegate {
    var text: () -> String? = { nil }
    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        guard let t = text(), !t.isEmpty else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
            UIMenu(children: [
                UIAction(title: "拷贝文本", image: UIImage(systemName: "doc.on.doc")) { _ in UIPasteboard.general.string = t },
                UIAction(title: "分享文本…", image: UIImage(systemName: "square.and.arrow.up")) { _ in
                    guard let host = interaction.view?.window?.rootViewController else { return }
                    var top = host; while let p = top.presentedViewController { top = p }
                    let vc = UIActivityViewController(activityItems: [t], applicationActivities: nil)
                    vc.popoverPresentationController?.sourceView = interaction.view
                    top.present(vc, animated: true)
                },
            ])
        }
    }
}
