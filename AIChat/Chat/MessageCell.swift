import UIKit
import SnapKit

class ChatBubbleCell: UICollectionViewCell, UIContextMenuInteractionDelegate {

    let bubbleView = UIView()
    var onCopyBlock: (() -> Void)?
    var onCopyMessage: (() -> Void)?

    private var leadingAlignmentConstraint: Constraint?
    private var trailingAlignmentConstraint: Constraint?
    private var centerAlignmentConstraint: Constraint?
    private var assistantWidthConstraint: Constraint?
    private var topConstraint: Constraint?
    private var bottomConstraint: Constraint?
    private var currentRole: Role?
    private var currentFirstInMessage: Bool?
    private var currentLastInMessage: Bool?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupBubble()
        contentView.addInteraction(UIContextMenuInteraction(delegate: self))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        onCopyBlock = nil
        onCopyMessage = nil
        currentRole = nil
        currentFirstInMessage = nil
        currentLastInMessage = nil
    }

    func configureChrome(for item: ChatItem) {
        updateAlignmentIfNeeded(for: item.role)
        updateInsetsIfNeeded(isFirst: item.isFirstInMessage, isLast: item.isLastInMessage)
        updateCornersIfNeeded(role: item.role, isFirst: item.isFirstInMessage, isLast: item.isLastInMessage)
        applyStyle(for: item.role)
    }

    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard onCopyBlock != nil || onCopyMessage != nil else { return nil }

        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            guard let self else { return UIMenu(children: []) }

            var actions: [UIAction] = []
            if self.onCopyBlock != nil {
                actions.append(UIAction(title: "复制此段", image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in
                    self?.onCopyBlock?()
                })
            }
            if self.onCopyMessage != nil {
                actions.append(UIAction(title: "复制整条消息", image: UIImage(systemName: "doc.text")) { [weak self] _ in
                    self?.onCopyMessage?()
                })
            }
            return UIMenu(children: actions)
        }
    }

    private func setupBubble() {
        contentView.addSubview(bubbleView)
        bubbleView.layer.cornerRadius = 16
        bubbleView.layer.masksToBounds = true
        bubbleView.setContentCompressionResistancePriority(.required, for: .horizontal)

        bubbleView.snp.makeConstraints { make in
            topConstraint = make.top.equalToSuperview().offset(6).constraint
            bottomConstraint = make.bottom.equalToSuperview().offset(-6).constraint
            make.width.lessThanOrEqualTo(contentView.snp.width).multipliedBy(0.82)
            assistantWidthConstraint = make.width.equalTo(contentView.snp.width).multipliedBy(0.82).constraint
            assistantWidthConstraint?.deactivate()
            make.leading.greaterThanOrEqualToSuperview().offset(16)
            make.trailing.lessThanOrEqualToSuperview().offset(-16)
            leadingAlignmentConstraint = make.leading.equalToSuperview().offset(16).constraint
            trailingAlignmentConstraint = make.trailing.equalToSuperview().offset(-16).constraint
            centerAlignmentConstraint = make.centerX.equalToSuperview().constraint
        }
    }

    private func updateAlignmentIfNeeded(for role: Role) {
        guard currentRole != role else { return }

        leadingAlignmentConstraint?.deactivate()
        trailingAlignmentConstraint?.deactivate()
        centerAlignmentConstraint?.deactivate()
        assistantWidthConstraint?.deactivate()

        switch role {
        case .user:
            trailingAlignmentConstraint?.activate()
        case .assistant:
            leadingAlignmentConstraint?.activate()
            assistantWidthConstraint?.activate()
        case .system:
            centerAlignmentConstraint?.activate()
        }

        currentRole = role
    }

    private func updateInsetsIfNeeded(isFirst: Bool, isLast: Bool) {
        guard currentFirstInMessage != isFirst || currentLastInMessage != isLast else { return }

        topConstraint?.update(offset: isFirst ? 6 : 0)
        bottomConstraint?.update(offset: isLast ? -6 : 0)
        currentFirstInMessage = isFirst
        currentLastInMessage = isLast
    }

    private func updateCornersIfNeeded(role: Role, isFirst: Bool, isLast: Bool) {
        let corners: CACornerMask

        switch role {
        case .assistant where !(isFirst && isLast):
            switch (isFirst, isLast) {
            case (true, false):
                corners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
            case (false, true):
                corners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
            default:
                corners = []
            }
        default:
            corners = [
                .layerMinXMinYCorner,
                .layerMaxXMinYCorner,
                .layerMinXMaxYCorner,
                .layerMaxXMaxYCorner
            ]
        }

        bubbleView.layer.maskedCorners = corners
    }

    private func applyStyle(for role: Role) {
        switch role {
        case .user:
            bubbleView.backgroundColor = .systemBlue
        case .assistant:
            bubbleView.backgroundColor = .secondarySystemBackground
        case .system:
            bubbleView.backgroundColor = .systemGray5
        }
    }
}

final class ChatTextBlockCell: ChatBubbleCell {

    static let reuseID = "ChatTextBlockCell"

    private let label = UILabel()
    private var currentText: String?
    private var currentKind: ChatItem.Kind?
    private var currentRendersMarkdown: Bool?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupLabel()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        label.text = nil
        label.attributedText = nil
        currentText = nil
        currentKind = nil
        currentRendersMarkdown = nil
    }

    func configure(with item: ChatItem) {
        configureChrome(for: item)

        if currentKind != item.kind {
            switch item.kind {
            case .reasoning:
                label.font = .systemFont(ofSize: 13)
                label.textColor = .secondaryLabel
            case .status:
                label.font = .systemFont(ofSize: 13)
                label.textColor = .secondaryLabel
            default:
                label.font = .systemFont(ofSize: 16)
                label.textColor = item.role == .user ? .white : .label
            }
            currentKind = item.kind
        }

        if currentText != item.text || currentRendersMarkdown != item.rendersMarkdown {
            if item.rendersMarkdown,
               let attributed = MarkdownRenderer.attributedString(
                from: item.text,
                baseFont: label.font,
                textColor: label.textColor
               ) {
                label.attributedText = attributed
            } else {
                label.attributedText = nil
                label.text = item.text
            }
            currentText = item.text
            currentRendersMarkdown = item.rendersMarkdown
        }
    }

    private func setupLabel() {
        label.numberOfLines = 0
        bubbleView.addSubview(label)
        label.snp.makeConstraints { make in
            make.edges.equalToSuperview().inset(12)
        }
    }
}

final class ChatCodeBlockCell: ChatBubbleCell {

    static let reuseID = "ChatCodeBlockCell"

    private let containerView = UIView()
    private let languageLabel = UILabel()
    private let codeLabel = UILabel()
    private var languageHeightConstraint: Constraint?
    private var currentText: String?
    private var currentLanguage: String?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupCodeViews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        currentText = nil
        currentLanguage = nil
        codeLabel.text = nil
        languageLabel.text = nil
    }

    func configure(with item: ChatItem) {
        configureChrome(for: item)

        let language: String?
        if case .code(let value) = item.kind {
            language = value
        } else {
            language = nil
        }

        if currentLanguage != language {
            languageLabel.text = language?.uppercased()
            languageLabel.isHidden = language == nil
            languageHeightConstraint?.update(offset: language == nil ? 0 : 18)
            currentLanguage = language
        }

        if currentText != item.text {
            codeLabel.text = item.text
            currentText = item.text
        }
    }

    private func setupCodeViews() {
        containerView.backgroundColor = .tertiarySystemBackground
        containerView.layer.cornerRadius = 10
        containerView.layer.masksToBounds = true

        languageLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        languageLabel.textColor = .secondaryLabel

        codeLabel.numberOfLines = 0
        codeLabel.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        codeLabel.textColor = .label

        bubbleView.addSubview(containerView)
        containerView.addSubview(languageLabel)
        containerView.addSubview(codeLabel)

        containerView.snp.makeConstraints { make in
            make.edges.equalToSuperview().inset(10)
        }
        languageLabel.snp.makeConstraints { make in
            make.top.leading.trailing.equalToSuperview().inset(10)
            languageHeightConstraint = make.height.equalTo(0).constraint
        }
        codeLabel.snp.makeConstraints { make in
            make.top.equalTo(languageLabel.snp.bottom).offset(4)
            make.leading.trailing.bottom.equalToSuperview().inset(10)
        }
    }
}

final class ChatImageBlockCell: ChatBubbleCell {

    static let reuseID = "ChatImageBlockCell"
    private static let imageCache = NSCache<NSURL, UIImage>()

    private let imageView = UIImageView()
    private let captionLabel = UILabel()
    private let placeholderLabel = UILabel()
    private var task: URLSessionDataTask?
    private var currentURL: URL?
    private var currentAlt: String?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupImageViews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        task?.cancel()
        task = nil
        currentURL = nil
        currentAlt = nil
        imageView.image = nil
        captionLabel.text = nil
        placeholderLabel.isHidden = false
        placeholderLabel.text = "图片加载中"
    }

    func configure(with item: ChatItem) {
        configureChrome(for: item)

        guard case .image(let urlString, let alt) = item.kind,
              let url = URL(string: urlString) else {
            showFailure(alt: nil)
            return
        }

        if currentAlt != alt {
            captionLabel.text = alt
            captionLabel.isHidden = alt?.isEmpty ?? true
            currentAlt = alt
        }

        guard currentURL != url else { return }
        currentURL = url
        imageView.image = nil
        placeholderLabel.isHidden = false
        placeholderLabel.text = "图片加载中"

        if let cachedImage = Self.imageCache.object(forKey: url as NSURL) {
            imageView.image = cachedImage
            placeholderLabel.isHidden = true
            return
        }

        task?.cancel()
        task = URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let self, let data, let image = UIImage(data: data) else {
                DispatchQueue.main.async { [weak self] in
                    guard self?.currentURL == url else { return }
                    self?.showFailure(alt: alt)
                }
                return
            }

            Self.imageCache.setObject(image, forKey: url as NSURL)
            DispatchQueue.main.async { [weak self] in
                guard self?.currentURL == url else { return }
                self?.imageView.image = image
                self?.placeholderLabel.isHidden = true
            }
        }
        task?.resume()
    }

    private func setupImageViews() {
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.backgroundColor = .tertiarySystemBackground
        imageView.layer.cornerRadius = 10
        imageView.layer.masksToBounds = true

        captionLabel.font = .systemFont(ofSize: 12)
        captionLabel.textColor = .secondaryLabel
        captionLabel.numberOfLines = 2

        placeholderLabel.font = .systemFont(ofSize: 13)
        placeholderLabel.textColor = .secondaryLabel
        placeholderLabel.textAlignment = .center

        bubbleView.addSubview(imageView)
        bubbleView.addSubview(captionLabel)
        imageView.addSubview(placeholderLabel)

        imageView.snp.makeConstraints { make in
            make.top.leading.trailing.equalToSuperview().inset(10)
            make.height.equalTo(180)
        }
        captionLabel.snp.makeConstraints { make in
            make.top.equalTo(imageView.snp.bottom).offset(6)
            make.leading.trailing.bottom.equalToSuperview().inset(10)
        }
        placeholderLabel.snp.makeConstraints { make in
            make.center.equalToSuperview()
            make.leading.trailing.equalToSuperview().inset(12)
        }
    }

    private func showFailure(alt: String?) {
        imageView.image = nil
        placeholderLabel.text = "图片加载失败"
        placeholderLabel.isHidden = false
        captionLabel.text = alt
        captionLabel.isHidden = alt?.isEmpty ?? true
    }
}

final class ChatControlCell: ChatBubbleCell {

    static let reuseID = "ChatControlCell"

    private let button = UIButton(type: .system)
    private var currentTitle: String?
    var onTapAction: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupButton()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        onTapAction = nil
        currentTitle = nil
        button.setTitle(nil, for: .normal)
    }

    func configure(with item: ChatItem) {
        configureChrome(for: item)
        if currentTitle != item.text {
            button.setTitle(item.text, for: .normal)
            currentTitle = item.text
        }
    }

    private func setupButton() {
        button.titleLabel?.font = .systemFont(ofSize: 13, weight: .medium)
        button.contentHorizontalAlignment = .left
        button.addTarget(self, action: #selector(didTapButton), for: .touchUpInside)

        bubbleView.addSubview(button)
        button.snp.makeConstraints { make in
            make.edges.equalToSuperview().inset(UIEdgeInsets(top: 8, left: 12, bottom: 8, right: 12))
            make.height.greaterThanOrEqualTo(22)
        }
    }

    @objc
    private func didTapButton() {
        onTapAction?()
    }
}
