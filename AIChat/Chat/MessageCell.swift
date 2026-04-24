import UIKit
import SnapKit

class ChatBubbleCell: UICollectionViewCell, UIContextMenuInteractionDelegate {

    enum Presentation: Equatable {
        case userBubble
        case assistantFlow
        case assistantBubble
        case systemBubble
    }

    let bubbleView = UIView()
    var onCopyBlock: (() -> Void)?
    var onCopyMessage: (() -> Void)?

    private var leadingMinimumConstraint: Constraint?
    private var trailingMaximumConstraint: Constraint?
    private var leadingAlignmentConstraint: Constraint?
    private var trailingAlignmentConstraint: Constraint?
    private var centerAlignmentConstraint: Constraint?
    private var compactMaxWidthConstraint: Constraint?
    private var assistantWidthConstraint: Constraint?
    private var assistantFlowTrailingConstraint: Constraint?
    private var topConstraint: Constraint?
    private var bottomConstraint: Constraint?
    private var currentPresentation: Presentation?
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
        currentPresentation = nil
        currentFirstInMessage = nil
        currentLastInMessage = nil
    }

    func configureChrome(for item: ChatItem) {
        let presentation = presentation(for: item)
        updateAlignmentIfNeeded(for: presentation)
        updateInsetsIfNeeded(isFirst: item.isFirstInMessage, isLast: item.isLastInMessage)
        updateCornersIfNeeded(for: presentation, isFirst: item.isFirstInMessage, isLast: item.isLastInMessage)
        applyStyle(for: presentation)
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
            compactMaxWidthConstraint = make.width.lessThanOrEqualTo(contentView.snp.width).multipliedBy(0.82).constraint
            assistantWidthConstraint = make.width.equalTo(contentView.snp.width).multipliedBy(0.82).constraint
            assistantWidthConstraint?.deactivate()
            leadingMinimumConstraint = make.leading.greaterThanOrEqualToSuperview().offset(16).constraint
            trailingMaximumConstraint = make.trailing.lessThanOrEqualToSuperview().offset(-16).constraint
            leadingAlignmentConstraint = make.leading.equalToSuperview().offset(16).constraint
            trailingAlignmentConstraint = make.trailing.equalToSuperview().offset(-16).constraint
            assistantFlowTrailingConstraint = make.trailing.equalToSuperview().offset(-16).constraint
            assistantFlowTrailingConstraint?.deactivate()
            centerAlignmentConstraint = make.centerX.equalToSuperview().constraint
        }
    }

    private func updateAlignmentIfNeeded(for presentation: Presentation) {
        let horizontalInset = horizontalInset(for: presentation)
        leadingMinimumConstraint?.update(offset: horizontalInset)
        trailingMaximumConstraint?.update(offset: -horizontalInset)
        leadingAlignmentConstraint?.update(offset: horizontalInset)
        trailingAlignmentConstraint?.update(offset: -horizontalInset)
        assistantFlowTrailingConstraint?.update(offset: -horizontalInset)

        guard currentPresentation != presentation else { return }

        leadingAlignmentConstraint?.deactivate()
        trailingAlignmentConstraint?.deactivate()
        assistantFlowTrailingConstraint?.deactivate()
        centerAlignmentConstraint?.deactivate()
        compactMaxWidthConstraint?.deactivate()
        assistantWidthConstraint?.deactivate()

        switch presentation {
        case .userBubble:
            compactMaxWidthConstraint?.activate()
            trailingAlignmentConstraint?.activate()
        case .assistantFlow:
            leadingAlignmentConstraint?.activate()
            assistantFlowTrailingConstraint?.activate()
        case .assistantBubble:
            leadingAlignmentConstraint?.activate()
            assistantFlowTrailingConstraint?.activate()
        case .systemBubble:
            compactMaxWidthConstraint?.activate()
            centerAlignmentConstraint?.activate()
        }

        currentPresentation = presentation
    }

    private func updateInsetsIfNeeded(isFirst: Bool, isLast: Bool) {
        guard currentFirstInMessage != isFirst || currentLastInMessage != isLast else { return }

        topConstraint?.update(offset: isFirst ? 6 : 0)
        bottomConstraint?.update(offset: isLast ? -6 : 0)
        currentFirstInMessage = isFirst
        currentLastInMessage = isLast
    }

    private func updateCornersIfNeeded(for presentation: Presentation, isFirst: Bool, isLast: Bool) {
        guard presentation != .assistantFlow else {
            bubbleView.layer.maskedCorners = []
            return
        }

        let corners: CACornerMask

        switch presentation {
        case .assistantBubble where !(isFirst && isLast):
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

    private func applyStyle(for presentation: Presentation) {
        switch presentation {
        case .userBubble:
            bubbleView.layer.cornerRadius = 16
            bubbleView.backgroundColor = .systemBlue
        case .assistantFlow:
            bubbleView.layer.cornerRadius = 0
            bubbleView.backgroundColor = .clear
        case .assistantBubble:
            bubbleView.layer.cornerRadius = 16
            bubbleView.backgroundColor = .secondarySystemBackground
        case .systemBubble:
            bubbleView.layer.cornerRadius = 16
            bubbleView.backgroundColor = .systemGray5
        }
    }

    private func horizontalInset(for presentation: Presentation) -> CGFloat {
        switch presentation {
        case .userBubble, .systemBubble:
            return 16
        case .assistantFlow, .assistantBubble:
            return 8
        }
    }

    private func presentation(for item: ChatItem) -> Presentation {
        switch item.role {
        case .user:
            return .userBubble
        case .assistant:
            switch item.kind {
            case .markdown, .heading, .quote, .list, .status, .control:
                return .assistantFlow
            case .table, .code, .image, .reasoning:
                return .assistantBubble
            }
        case .system:
            return .systemBubble
        }
    }
}

final class ChatTextBlockCell: ChatBubbleCell {

    static let reuseID = "ChatTextBlockCell"

    private let label = UILabel()
    private let quoteStripe = UIView()
    private var labelLeadingConstraint: Constraint?
    private var labelLeadingWithStripeConstraint: Constraint?
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
        quoteStripe.isHidden = true
        currentText = nil
        currentKind = nil
        currentRendersMarkdown = nil
    }

    func configure(with item: ChatItem) {
        configureChrome(for: item)

        if currentKind != item.kind {
            switch item.kind {
            case .heading(let level):
                label.font = headingFont(level: level)
                label.textColor = item.role == .user ? .white : .label
                quoteStripe.isHidden = true
                labelLeadingWithStripeConstraint?.deactivate()
                labelLeadingConstraint?.activate()
            case .quote:
                label.font = .systemFont(ofSize: 15)
                label.textColor = item.role == .user ? .white : .secondaryLabel
                quoteStripe.isHidden = false
                labelLeadingConstraint?.deactivate()
                labelLeadingWithStripeConstraint?.activate()
            case .list:
                label.font = .systemFont(ofSize: 16)
                label.textColor = item.role == .user ? .white : .label
                quoteStripe.isHidden = true
                labelLeadingWithStripeConstraint?.deactivate()
                labelLeadingConstraint?.activate()
            case .reasoning:
                label.font = .systemFont(ofSize: 13)
                label.textColor = .secondaryLabel
                quoteStripe.isHidden = true
                labelLeadingWithStripeConstraint?.deactivate()
                labelLeadingConstraint?.activate()
            case .status:
                label.font = .systemFont(ofSize: 13)
                label.textColor = .secondaryLabel
                quoteStripe.isHidden = true
                labelLeadingWithStripeConstraint?.deactivate()
                labelLeadingConstraint?.activate()
            default:
                label.font = .systemFont(ofSize: 16)
                label.textColor = item.role == .user ? .white : .label
                quoteStripe.isHidden = true
                labelLeadingWithStripeConstraint?.deactivate()
                labelLeadingConstraint?.activate()
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
        quoteStripe.backgroundColor = .systemGray3
        quoteStripe.layer.cornerRadius = 1.5

        bubbleView.addSubview(quoteStripe)
        bubbleView.addSubview(label)

        quoteStripe.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(12)
            make.top.bottom.equalToSuperview().inset(12)
            make.width.equalTo(3)
        }
        label.snp.makeConstraints { make in
            make.top.bottom.trailing.equalToSuperview().inset(12)
            labelLeadingConstraint = make.leading.equalToSuperview().offset(12).constraint
            labelLeadingWithStripeConstraint = make.leading.equalTo(quoteStripe.snp.trailing).offset(10).constraint
        }
        quoteStripe.isHidden = true
        labelLeadingWithStripeConstraint?.deactivate()
    }

    private func headingFont(level: Int) -> UIFont {
        switch level {
        case 1:
            return .systemFont(ofSize: 26, weight: .semibold)
        case 2:
            return .systemFont(ofSize: 22, weight: .semibold)
        case 3:
            return .systemFont(ofSize: 19, weight: .semibold)
        case 4:
            return .systemFont(ofSize: 17, weight: .semibold)
        default:
            return .systemFont(ofSize: 16, weight: .semibold)
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

final class ChatTableBlockCell: ChatBubbleCell {

    static let reuseID = "ChatTableBlockCell"
    private static let layoutCache = NSCache<NSString, TableLayoutCacheEntry>()

    private let scrollView = UIScrollView()
    private let contentStackView = UIStackView()
    private var contentWidthConstraint: Constraint?
    private var currentText: String?
    private var currentRole: Role?
    private var currentAlignments: [TableColumnAlignment] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupTableViews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        currentText = nil
        currentRole = nil
        currentAlignments = []
        contentStackView.arrangedSubviews.forEach { row in
            contentStackView.removeArrangedSubview(row)
            row.removeFromSuperview()
        }
    }

    func configure(with item: ChatItem) {
        configureChrome(for: item)
        guard case .table(_, let alignments) = item.kind else { return }

        if currentText != item.text || currentRole != item.role || currentAlignments != alignments {
            rebuildRows(from: item.text, role: item.role, alignments: alignments)
            currentText = item.text
            currentRole = item.role
            currentAlignments = alignments
        }
    }

    private func setupTableViews() {
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.alwaysBounceHorizontal = false

        contentStackView.axis = .vertical
        contentStackView.spacing = 1
        contentStackView.distribution = .fill

        bubbleView.addSubview(scrollView)
        scrollView.addSubview(contentStackView)

        scrollView.snp.makeConstraints { make in
            make.edges.equalToSuperview().inset(6)
            make.height.greaterThanOrEqualTo(44)
        }
        contentStackView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
            contentWidthConstraint = make.width.equalTo(0).constraint
        }
    }

    private func rebuildRows(from text: String, role: Role, alignments: [TableColumnAlignment]) {
        contentStackView.arrangedSubviews.forEach { row in
            contentStackView.removeArrangedSubview(row)
            row.removeFromSuperview()
        }

        let layout = tableLayout(for: text)
        let rows = layout.rows
        guard !rows.isEmpty else { return }

        contentWidthConstraint?.update(offset: layout.totalWidth)
        scrollView.alwaysBounceHorizontal = layout.totalWidth > bounds.width - 20
        let textColor: UIColor = role == .user ? .white : .label

        for (rowIndex, cells) in rows.enumerated() {
            let rowView = UIStackView()
            rowView.axis = .horizontal
            rowView.spacing = 1
            rowView.distribution = .fill
            rowView.backgroundColor = .separator
            rowView.snp.makeConstraints { make in
                make.height.equalTo(rowIndex == 0 ? 40 : 44)
            }

            for (columnIndex, cell) in cells.enumerated() {
                let label = UILabel()
                label.numberOfLines = 0
                label.text = cell.isEmpty ? " " : cell
                label.textColor = textColor
                label.font = rowIndex == 0
                    ? .systemFont(ofSize: 14, weight: .semibold)
                    : .systemFont(ofSize: 14)
                label.textAlignment = textAlignment(for: alignments[safe: columnIndex] ?? .leading)

                let container = UIView()
                container.backgroundColor = rowIndex == 0
                    ? .tertiarySystemBackground
                    : .systemBackground.withAlphaComponent(role == .user ? 0.18 : 0.55)
                container.setContentCompressionResistancePriority(.required, for: .horizontal)
                container.setContentHuggingPriority(.required, for: .horizontal)
                container.snp.makeConstraints { make in
                    make.width.equalTo(layout.columnWidths[columnIndex])
                }
                container.addSubview(label)
                label.snp.makeConstraints { make in
                    make.edges.equalToSuperview().inset(UIEdgeInsets(top: 10, left: 8, bottom: 10, right: 8))
                }

                rowView.addArrangedSubview(container)
            }

            contentStackView.addArrangedSubview(rowView)
        }
    }

    private func textAlignment(for alignment: TableColumnAlignment) -> NSTextAlignment {
        switch alignment {
        case .leading:
            return .left
        case .center:
            return .center
        case .trailing:
            return .right
        }
    }

    private func tableLayout(for text: String) -> TableLayoutCacheEntry {
        let key = text as NSString
        if let cached = Self.layoutCache.object(forKey: key) {
            return cached
        }

        let rows = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { row in
                row.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            }
        let columnCount = rows.map(\.count).max() ?? 0
        guard columnCount > 0 else {
            let empty = TableLayoutCacheEntry(rows: [], columnWidths: [], totalWidth: 0)
            Self.layoutCache.setObject(empty, forKey: key)
            return empty
        }

        let headerFont = UIFont.systemFont(ofSize: 14, weight: .semibold)
        let bodyFont = UIFont.systemFont(ofSize: 14)
        let horizontalPadding: CGFloat = 20
        let minWidth: CGFloat = 64
        let maxWidth: CGFloat = 220

        var widths = Array(repeating: minWidth, count: columnCount)
        for (rowIndex, row) in rows.enumerated() {
            for columnIndex in 0..<columnCount {
                let text = columnIndex < row.count ? row[columnIndex] : ""
                let font = rowIndex == 0 ? headerFont : bodyFont
                let measuredWidth = ceil((text.isEmpty ? " " : text as NSString).boundingRect(
                    with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: 24),
                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                    attributes: [.font: font],
                    context: nil
                ).width)
                widths[columnIndex] = max(widths[columnIndex], min(maxWidth, measuredWidth + horizontalPadding))
            }
        }

        let totalWidth = widths.reduce(0, +) + CGFloat(max(0, columnCount - 1))
        let layout = TableLayoutCacheEntry(rows: rows, columnWidths: widths, totalWidth: totalWidth)
        Self.layoutCache.setObject(layout, forKey: key)
        return layout
    }

    private final class TableLayoutCacheEntry: NSObject {
        let rows: [[String]]
        let columnWidths: [CGFloat]
        let totalWidth: CGFloat

        init(rows: [[String]], columnWidths: [CGFloat], totalWidth: CGFloat) {
            self.rows = rows
            self.columnWidths = columnWidths
            self.totalWidth = totalWidth
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
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
