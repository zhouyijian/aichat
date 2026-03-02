//
//  ViewController.swift
//  AIChat
//
//  Created by 周一见 on 2026/2/28.
//

import UIKit
import SnapKit

final class ChatViewController: UIViewController {

    // MARK: - Dependencies
    let viewModel = ChatViewModel(repository: MockMessageRepository())

    // MARK: - UI
    var collectionView: UICollectionView!
    var dataSource: UICollectionViewDiffableDataSource<Section, UUID>!
    lazy var sizingCell = MessageCell(frame: .zero)

    let scrollToBottomButton: UIButton = {
        var config = UIButton.Configuration.filled()
        config.title = "回到底部"
        config.baseBackgroundColor = .secondarySystemBackground
        config.baseForegroundColor = .label
        config.cornerStyle = .capsule
        config.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12)

        let button = UIButton(configuration: config)
        button.configurationUpdateHandler = { btn in
            btn.configuration?.baseBackgroundColor = .secondarySystemBackground
        }
        button.isHidden = true
        return button
    }()

    // MARK: - Interaction State
    var userIsInteracting = false

    // MARK: - Lifecycle
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        title = "Chat"

        setupCollectionView()
        setupDataSource()
        setupScrollToBottomButton()
        applySnapshot()
        registerTraitObservers()
        #if DEBUG
        setupDebugMockActions()
        #endif
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)

        coordinator.animate(alongsideTransition: nil) { [weak self] _ in
            guard let self else { return }
            self.viewModel.invalidateAllHeights()
            self.collectionView.collectionViewLayout.invalidateLayout()
            self.collectionView.reloadData()
            self.updateScrollToBottomButtonVisibility()
        }
    }
}

// MARK: - Setup
extension ChatViewController {
    func registerTraitObservers() {
        registerForTraitChanges(
            [UITraitPreferredContentSizeCategory.self]
        ) { (self: Self, _) in
            self.handleContentSizeCategoryChange()
        }
    }

    #if DEBUG
    func setupDebugMockActions() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.appendMessage(Message(role: .assistant, content: "append test message"), scrollToBottom: true)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            let streamingMessage = Message(role: .assistant, content: "")
            self.appendMessage(streamingMessage, scrollToBottom: true)
            let targetID = streamingMessage.id
            var counter = 0
            Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] timer in
                guard let self else {
                    timer.invalidate()
                    return
                }
                counter += 1
                let chunk = " 流式片段\(counter)"
                let updated = self.viewModel.updateMessage(id: targetID) { msg in
                    msg.content += chunk
                }
                if updated {
                    self.updateMessageUI(id: targetID)
                }
                if counter >= 20 {
                    timer.invalidate()
                }
            }
        }
    }
    #endif

    func setupCollectionView() {
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .vertical
        layout.minimumLineSpacing = 10
        layout.minimumInteritemSpacing = 0
        layout.sectionInset = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        layout.estimatedItemSize = .zero

        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.backgroundColor = .clear
        collectionView.alwaysBounceVertical = true
        collectionView.delegate = self

        collectionView.register(MessageCell.self, forCellWithReuseIdentifier: MessageCell.reuseID)
        view.addSubview(collectionView)

        collectionView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
    }

    func setupScrollToBottomButton() {
        view.addSubview(scrollToBottomButton)
        scrollToBottomButton.snp.makeConstraints { make in
            make.trailing.equalToSuperview().inset(16)
            make.bottom.equalTo(view.safeAreaLayoutGuide).inset(16)
        }

        scrollToBottomButton.addTarget(self, action: #selector(didTapScrollToBottom), for: .touchUpInside)
    }

    func handleContentSizeCategoryChange() {
        viewModel.invalidateAllHeights()
        collectionView.collectionViewLayout.invalidateLayout()
        collectionView.reloadData()
        updateScrollToBottomButtonVisibility()
    }
}

#Preview("Mock Chat") {
    UINavigationController(rootViewController: ChatViewController())
}

