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
        messageLabel.text = message.content
        updateAlignment(for: message.role)
        
        switch message.role {
        case .user:
            bubbleView.backgroundColor = .systemBlue
            messageLabel.textColor = .white
        case .assistant:
            bubbleView.backgroundColor = .secondarySystemBackground
            messageLabel.textColor = .label
        case .system:
            bubbleView.backgroundColor = .systemGray5
            messageLabel.textColor = .secondaryLabel
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
    }
}
