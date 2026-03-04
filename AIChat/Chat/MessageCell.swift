import UIKit
import SnapKit

final class MessageCell: UICollectionViewCell {
    
    static let reuseID = "MessageCell"
    
    private let bubbleView = UIView()
    private let messageLabel = UILabel()
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
        bubbleView.addSubview(messageLabel)
        
        bubbleView.layer.cornerRadius = 16
        bubbleView.layer.masksToBounds = true
        
        messageLabel.numberOfLines = 0
        messageLabel.font = .systemFont(ofSize: 16)
        bubbleView.setContentHuggingPriority(.required, for: .horizontal)
        bubbleView.setContentCompressionResistancePriority(.required, for: .horizontal)
        
        bubbleView.snp.makeConstraints { make in
            make.top.bottom.equalToSuperview().inset(6)
            make.width.lessThanOrEqualTo(contentView.snp.width).multipliedBy(0.75)
            make.leading.greaterThanOrEqualToSuperview().offset(16)
            make.trailing.lessThanOrEqualToSuperview().offset(-16)
            leadingAlignmentConstraint = make.leading.equalToSuperview().offset(16).constraint
            trailingAlignmentConstraint = make.trailing.equalToSuperview().offset(-16).constraint
            centerAlignmentConstraint = make.centerX.equalToSuperview().constraint
        }
        
        messageLabel.snp.makeConstraints { make in
            make.edges.equalToSuperview().inset(12)
        }
    }
    
    func configure(with message: Message) {
        updateAlignment(for: message.role)
        
        switch message.role {
        case .user:
            bubbleView.backgroundColor = .systemBlue
            messageLabel.textColor = .white
            messageLabel.attributedText = nil
            messageLabel.text = message.content
        case .assistant:
            bubbleView.backgroundColor = .secondarySystemBackground
            messageLabel.textColor = .label
            messageLabel.attributedText = makeAssistantText(content: message.content)
        case .system:
            bubbleView.backgroundColor = .systemGray5
            messageLabel.textColor = .secondaryLabel
            messageLabel.attributedText = nil
            messageLabel.text = message.content
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
        messageLabel.attributedText = nil
        messageLabel.text = nil
    }

    private func makeAssistantText(content: String) -> NSAttributedString {
        let fullRange = NSRange(location: 0, length: (content as NSString).length)
        let result = NSMutableAttributedString(string: content, attributes: [
            .font: UIFont.systemFont(ofSize: 16),
            .foregroundColor: UIColor.label
        ])

        if let range = reasoningRange(in: content) {
            result.addAttributes([
                .font: UIFont.systemFont(ofSize: 13),
                .foregroundColor: UIColor.secondaryLabel
            ], range: range)
        } else {
            result.addAttributes([
                .font: UIFont.systemFont(ofSize: 16),
                .foregroundColor: UIColor.label
            ], range: fullRange)
        }

        return result
    }

    private func reasoningRange(in text: String) -> NSRange? {
        if let startRange = text.range(of: "<think>") {
            if let endRange = text.range(of: "</think>"),
               startRange.lowerBound < endRange.lowerBound {
                return NSRange(startRange.lowerBound..<endRange.upperBound, in: text)
            }
            // 流式中间态：还没收到 </think> 时，先把 <think> 到当前末尾都按思考样式展示
            return NSRange(startRange.lowerBound..<text.endIndex, in: text)
        }

        let titles = ["思考过程：", "思考过程:", "Reasoning:", "Reasoning：", "Thought process:", "Thought process："]
        for title in titles {
            if text.hasPrefix(title) {
                if let splitRange = text.range(of: "\n\n") {
                    return NSRange(text.startIndex..<splitRange.lowerBound, in: text)
                }
                return NSRange(text.startIndex..<text.endIndex, in: text)
            }
        }

        return nil
    }
}
