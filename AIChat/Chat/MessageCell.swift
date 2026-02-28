import UIKit
import SnapKit

final class MessageCell: UICollectionViewCell {
    
    static let reuseID = "MessageCell"
    
    private let bubbleView = UIView()
    private let messageLabel = UILabel()
    
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
        
        // 先写最基础布局（居中气泡）
        bubbleView.snp.makeConstraints { make in
            make.top.bottom.equalToSuperview().inset(6)
            make.leading.trailing.equalToSuperview().inset(16)
        }
        
        messageLabel.snp.makeConstraints { make in
            make.edges.equalToSuperview().inset(12)
        }
    }
    
    func configure(with message: Message) {
        messageLabel.text = message.content
        
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
    
    override func prepareForReuse() {
        super.prepareForReuse()
        messageLabel.text = nil
    }
}
