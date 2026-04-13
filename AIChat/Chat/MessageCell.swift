import UIKit
import SnapKit

final class MessageCell: UICollectionViewCell {
    
    static let reuseID = "MessageCell"
    var onToggleContentExpansion: (() -> Void)?
    var onToggleReasoning: (() -> Void)?
    
    private let bubbleView = UIView()
    private let contentStackView = UIStackView()
    private let messageLabel = UILabel()
    private let toggleContentButton = UIButton(type: .system)
    private let toggleReasoningButton = UIButton(type: .system)
    private let reasoningContainerView = UIView()
    private let reasoningLabel = UILabel()
    private var leadingAlignmentConstraint: Constraint?
    private var trailingAlignmentConstraint: Constraint?
    private var centerAlignmentConstraint: Constraint?
    
    private var currentRole: Role?
    private var currentHasFoldedContent: Bool?
    private var currentContentExpanded: Bool?
    private var currentReasoningExpanded: Bool?
    private var currentHasReasoning: Bool?
    
    private var currentMessageText: String?
    private var currentContentButtonTitle: String?
    private var currentReasoningText: String?
    private var currentReasoningButtonTitle: String?
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        setupUI()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func prepareForReuse() {
        super.prepareForReuse()
        
        messageLabel.text = nil
        reasoningLabel.text = nil
        toggleContentButton.setTitle(nil, for: .normal)
        toggleReasoningButton.setTitle(nil, for: .normal)
        onToggleContentExpansion = nil
        onToggleReasoning = nil
        
        currentRole = nil
        currentHasFoldedContent = nil
        currentContentExpanded = nil
        currentReasoningExpanded = nil
        currentHasReasoning = nil
        currentMessageText = nil
        currentContentButtonTitle = nil
        currentReasoningText = nil
        currentReasoningButtonTitle = nil
        
        toggleContentButton.isHidden = true
        toggleReasoningButton.isHidden = true
        reasoningContainerView.isHidden = true
    }
    
    private func setupUI() {
        
        contentView.addSubview(bubbleView)
        bubbleView.addSubview(contentStackView)
        
        bubbleView.layer.cornerRadius = 16
        bubbleView.layer.masksToBounds = true
        
        contentStackView.axis = .vertical
        contentStackView.spacing = 8
        
        messageLabel.numberOfLines = 0
        messageLabel.font = .systemFont(ofSize: 16)
        
        toggleContentButton.titleLabel?.font = .systemFont(ofSize: 13, weight: .medium)
        toggleContentButton.contentHorizontalAlignment = .left
        toggleContentButton.addTarget(self, action: #selector(didTapToggleContent), for: .touchUpInside)
        
        toggleReasoningButton.titleLabel?.font = .systemFont(ofSize: 13, weight: .medium)
        toggleReasoningButton.contentHorizontalAlignment = .left
        toggleReasoningButton.addTarget(self, action: #selector(didTapToggleReasoning), for: .touchUpInside)
        
        reasoningContainerView.layer.cornerRadius = 10
        reasoningContainerView.layer.masksToBounds = true
        reasoningContainerView.backgroundColor = .tertiarySystemBackground
        
        reasoningLabel.numberOfLines = 0
        reasoningLabel.font = .systemFont(ofSize: 13)
        reasoningLabel.textColor = .secondaryLabel
        
        contentStackView.addArrangedSubview(toggleReasoningButton)
        contentStackView.addArrangedSubview(reasoningContainerView)
        contentStackView.addArrangedSubview(messageLabel)
        contentStackView.addArrangedSubview(toggleContentButton)

        reasoningContainerView.addSubview(reasoningLabel)
        
        bubbleView.setContentCompressionResistancePriority(.required, for: .horizontal)
        
        bubbleView.snp.makeConstraints { make in
            make.top.bottom.equalToSuperview().inset(6)
            make.width.lessThanOrEqualTo(contentView.snp.width).multipliedBy(0.82)
            make.leading.greaterThanOrEqualToSuperview().offset(16)
            make.trailing.lessThanOrEqualToSuperview().offset(-16)
            leadingAlignmentConstraint = make.leading.equalToSuperview().offset(16).constraint
            trailingAlignmentConstraint = make.trailing.equalToSuperview().offset(-16).constraint
            centerAlignmentConstraint = make.centerX.equalToSuperview().constraint
        }
        
        contentStackView.snp.makeConstraints { make in
            make.edges.equalToSuperview().inset(12)
        }
        
        reasoningLabel.snp.makeConstraints { make in
            make.edges.equalToSuperview().inset(10)
        }
    }
    
    func configure(with message: Message, assistantSegments: AssistantSegments?) {
        switch message.role {
        case .user:
            configureUser(message)
        case .assistant:
            configureAssistant(message, segments: assistantSegments)
        case .system:
            configureSystem(message)
        }
    }
    
    private func configureUser(_ message: Message) {
        updateAlignmentIfNeeded(for: .user)
        applyBubbleStyleIfNeeded(
            backgroundColor: .systemBlue,
            textColor: .white
        )
        
        let text = message.content
        if currentMessageText != text {
            messageLabel.text = text
            currentMessageText = text
        }
        
        hideReasoningIfNeeded()
    }
    
    private func configureAssistant(_ message: Message, segments: AssistantSegments?) {
        updateAlignmentIfNeeded(for: .assistant)
        applyBubbleStyleIfNeeded(
            backgroundColor: .secondarySystemBackground,
            textColor: .label
        )

        let finalSegments = segments ?? AssistantSegments(
            responseText: message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "..." : message.content,
            foldedResponseText: nil,
            reasoningText: nil
        )

        updateAssistantContent(
            responseText: finalSegments.displayedResponseText(isExpanded: message.isContentExpanded),
            reasoningText: finalSegments.reasoningText
        )

        updateAssistantStructure(
            hasFoldedContent: finalSegments.isResponseFoldable,
            isContentExpanded: message.isContentExpanded,
            hasReasoning: !(finalSegments.reasoningText?.isEmpty ?? true),
            isExpanded: message.isReasoningExpanded
        )
    }
    
    private func configureSystem(_ message: Message) {
        updateAlignmentIfNeeded(for: .system)
        applyBubbleStyleIfNeeded(
            backgroundColor: .systemGray5,
            textColor: .secondaryLabel
        )
        
        let text = message.content
        if currentMessageText != text {
            messageLabel.text = text
            currentMessageText = text
        }
        
        hideReasoningIfNeeded()
    }
    
    private func updateAlignmentIfNeeded(for role: Role) {
        guard currentRole != role else { return }
        
        leadingAlignmentConstraint?.deactivate()
        trailingAlignmentConstraint?.deactivate()
        centerAlignmentConstraint?.deactivate()
        
        switch role {
        case .user:
            trailingAlignmentConstraint?.activate()
        case .assistant:
            leadingAlignmentConstraint?.activate()
        case .system:
            centerAlignmentConstraint?.activate()
        }
        
        currentRole = role
    }
    
    @objc
    private func didTapToggleContent() {
        onToggleContentExpansion?()
    }

    @objc
    private func didTapToggleReasoning() {
        onToggleReasoning?()
    }
    
    private func hideReasoningIfNeeded() {
        if currentHasFoldedContent != false || toggleContentButton.isHidden == false {
            toggleContentButton.isHidden = true
        }
        if currentHasReasoning != false || toggleReasoningButton.isHidden == false {
            toggleReasoningButton.isHidden = true
        }
        if reasoningContainerView.isHidden == false {
            reasoningContainerView.isHidden = true
        }
        if currentReasoningText != nil {
            reasoningLabel.text = nil
            currentReasoningText = nil
        }
        if currentContentButtonTitle != nil {
            toggleContentButton.setTitle(nil, for: .normal)
            currentContentButtonTitle = nil
        }
        if currentReasoningButtonTitle != nil {
            toggleReasoningButton.setTitle(nil, for: .normal)
            currentReasoningButtonTitle = nil
        }
        
        currentHasFoldedContent = false
        currentContentExpanded = nil
        currentHasReasoning = false
        currentReasoningExpanded = nil
    }
    
    // MARK: - 内容更新（高频）
    private func updateAssistantContent(responseText: String, reasoningText: String?) {
        if currentMessageText != responseText {
            messageLabel.text = responseText
            currentMessageText = responseText
        }
        
        if currentReasoningText != reasoningText {
            reasoningLabel.text = reasoningText
            currentReasoningText = reasoningText
        }
    }
    
    
    // MARK: - 结构更新（低频）
    private func updateAssistantStructure(
        hasFoldedContent: Bool,
        isContentExpanded: Bool,
        hasReasoning: Bool,
        isExpanded: Bool
    ) {
        let hasFoldedContentChanged = currentHasFoldedContent != hasFoldedContent
        let contentExpandedChanged = currentContentExpanded != isContentExpanded
        let hasReasoningChanged = currentHasReasoning != hasReasoning
        let expandedChanged = currentReasoningExpanded != isExpanded
        
        if hasFoldedContent {
            let title = isContentExpanded ? "收起全文" : "展开全文"
            if currentContentButtonTitle != title {
                toggleContentButton.setTitle(title, for: .normal)
                currentContentButtonTitle = title
            }
        } else if currentContentButtonTitle != nil {
            toggleContentButton.setTitle(nil, for: .normal)
            currentContentButtonTitle = nil
        }

        if hasReasoningChanged {
            toggleReasoningButton.isHidden = !hasReasoning
        }
        
        let shouldHideReasoningContainer = !hasReasoning || !isExpanded
        if hasReasoningChanged || expandedChanged {
            reasoningContainerView.isHidden = shouldHideReasoningContainer
        }
        
        if hasReasoning {
            let title = isExpanded ? "隐藏思考过程" : "显示思考过程"
            if currentReasoningButtonTitle != title {
                toggleReasoningButton.setTitle(title, for: .normal)
                currentReasoningButtonTitle = title
            }
        } else {
            if currentReasoningButtonTitle != nil {
                toggleReasoningButton.setTitle(nil, for: .normal)
                currentReasoningButtonTitle = nil
            }
        }
        
        if hasFoldedContentChanged || contentExpandedChanged {
            toggleContentButton.isHidden = !hasFoldedContent
        }
        
        currentHasFoldedContent = hasFoldedContent
        currentContentExpanded = isContentExpanded
        currentHasReasoning = hasReasoning
        currentReasoningExpanded = isExpanded
    }
    
    private func applyBubbleStyleIfNeeded(backgroundColor: UIColor, textColor: UIColor) {
        if bubbleView.backgroundColor != backgroundColor {
            bubbleView.backgroundColor = backgroundColor
        }
        if messageLabel.textColor != textColor {
            messageLabel.textColor = textColor
        }
    }
    
}
