import UIKit
import SnapKit

final class MessageCell: UICollectionViewCell {
    
    static let reuseID = "MessageCell"
    var onToggleReasoning: (() -> Void)?
    
    private let bubbleView = UIView()
    private let contentStackView = UIStackView()
    private let messageLabel = UILabel()
    private let toggleReasoningButton = UIButton(type: .system)
    private let reasoningContainerView = UIView()
    private let reasoningLabel = UILabel()
    private var leadingAlignmentConstraint: Constraint?
    private var trailingAlignmentConstraint: Constraint?
    private var centerAlignmentConstraint: Constraint?
    
    private var currentRole: Role?
    private var currentReasoningExpanded: Bool?
    private var currentHasReasoning: Bool?
    
    private var currentMessageText: String?
    private var currentReasoningText: String?
    private var currentReasoningButtonTitle: String?
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        setupUI()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
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
        
        toggleReasoningButton.titleLabel?.font = .systemFont(ofSize: 13, weight: .medium)
        toggleReasoningButton.contentHorizontalAlignment = .left
        toggleReasoningButton.addTarget(self, action: #selector(didTapToggleReasoning), for: .touchUpInside)
        
        reasoningContainerView.layer.cornerRadius = 10
        reasoningContainerView.layer.masksToBounds = true
        reasoningContainerView.backgroundColor = .tertiarySystemBackground
        
        reasoningLabel.numberOfLines = 0
        reasoningLabel.font = .systemFont(ofSize: 13)
        reasoningLabel.textColor = .secondaryLabel
        
        contentStackView.addArrangedSubview(messageLabel)
        contentStackView.addArrangedSubview(toggleReasoningButton)
        contentStackView.addArrangedSubview(reasoningContainerView)
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
            reasoningText: nil
        )

        updateAssistantContent(
            responseText: finalSegments.responseText,
            reasoningText: finalSegments.reasoningText
        )

        updateAssistantStructure(
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
    
    override func prepareForReuse() {
        super.prepareForReuse()
        
        messageLabel.text = nil
        reasoningLabel.text = nil
        toggleReasoningButton.setTitle(nil, for: .normal)
        onToggleReasoning = nil
        
        currentRole = nil
        currentReasoningExpanded = nil
        currentHasReasoning = nil
        currentMessageText = nil
        currentReasoningText = nil
        currentReasoningButtonTitle = nil
        
        toggleReasoningButton.isHidden = true
        reasoningContainerView.isHidden = true
    }
    
    @objc
    private func didTapToggleReasoning() {
        onToggleReasoning?()
    }
    
    private func hideReasoningIfNeeded() {
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
        if currentReasoningButtonTitle != nil {
            toggleReasoningButton.setTitle(nil, for: .normal)
            currentReasoningButtonTitle = nil
        }
        
        currentHasReasoning = false
        currentReasoningExpanded = nil
    }
    
    private func assistantSegments(for message: Message) -> AssistantSegments {
        let explicitReasoning = message.reasoningContent?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasExplicitReasoning = !(explicitReasoning?.isEmpty ?? true)
        
        if hasExplicitReasoning {
            let response = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
            return AssistantSegments(
                responseText: response.isEmpty ? "..." : response,
                reasoningText: explicitReasoning
            )
        }
        
        let content = message.content
        if let startRange = content.range(of: "<think>") {
            if let endRange = content.range(of: "</think>"), startRange.lowerBound < endRange.lowerBound {
                let reasoning = String(content[startRange.upperBound..<endRange.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let response = content.replacingCharacters(in: startRange.lowerBound..<endRange.upperBound, with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return AssistantSegments(
                    responseText: response.isEmpty ? "..." : response,
                    reasoningText: reasoning.isEmpty ? nil : reasoning
                )
            } else {
                let reasoning = String(content[startRange.upperBound...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let prefix = String(content[..<startRange.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return AssistantSegments(
                    responseText: prefix.isEmpty ? "..." : prefix,
                    reasoningText: reasoning.isEmpty ? nil : reasoning
                )
            }
        }
        
        let cleaned = content.trimmingCharacters(in: .whitespacesAndNewlines)
        return AssistantSegments(
            responseText: cleaned.isEmpty ? "..." : cleaned,
            reasoningText: nil
        )
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
    private func updateAssistantStructure(hasReasoning: Bool, isExpanded: Bool) {
        let hasReasoningChanged = currentHasReasoning != hasReasoning
        let expandedChanged = currentReasoningExpanded != isExpanded
        
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


