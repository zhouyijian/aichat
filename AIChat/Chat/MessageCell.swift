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
    
    func configure(with message: Message) {
        updateAlignment(for: message.role)
        
        switch message.role {
        case .user:
            bubbleView.backgroundColor = .systemBlue
            messageLabel.textColor = .white
            messageLabel.text = message.content
            hideReasoning()
        case .assistant:
            bubbleView.backgroundColor = .secondarySystemBackground
            messageLabel.textColor = .label
            let segments = assistantSegments(for: message)
            messageLabel.text = segments.responseText
            applyReasoning(segments.reasoningText, isExpanded: message.isReasoningExpanded)
        case .system:
            bubbleView.backgroundColor = .systemGray5
            messageLabel.textColor = .secondaryLabel
            messageLabel.text = message.content
            hideReasoning()
        }
    }

    private func updateAlignment(for role: Role) {
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
    }
    
    override func prepareForReuse() {
        super.prepareForReuse()
        messageLabel.text = nil
        reasoningLabel.text = nil
        onToggleReasoning = nil
    }
    
    @objc
    private func didTapToggleReasoning() {
        onToggleReasoning?()
    }

    private func hideReasoning() {
        toggleReasoningButton.isHidden = true
        reasoningContainerView.isHidden = true
    }
    
    private func applyReasoning(_ text: String?, isExpanded: Bool) {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            hideReasoning()
            return
        }
        
        toggleReasoningButton.isHidden = false
        toggleReasoningButton.setTitle(isExpanded ? "隐藏思考过程" : "显示思考过程", for: .normal)
        reasoningContainerView.isHidden = !isExpanded
        reasoningLabel.text = text
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
                let reasoning = String(content[startRange.upperBound..<endRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                let response = content.replacingCharacters(in: startRange.lowerBound..<endRange.upperBound, with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return AssistantSegments(
                    responseText: response.isEmpty ? "..." : response,
                    reasoningText: reasoning.isEmpty ? nil : reasoning
                )
            } else {
                let reasoning = String(content[startRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                let prefix = String(content[..<startRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
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
}

private extension MessageCell {
    struct AssistantSegments {
        let responseText: String
        let reasoningText: String?
    }
}
