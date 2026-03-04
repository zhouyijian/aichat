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
    private lazy var throttler = StreamingThrottler(
        shouldPinToBottom: { [weak self] in
            guard let self else { return false }
            return !self.userIsInteracting && self.isNearBottom(tolerance: 150)
        },
        onTick: { [weak self] id, shouldPinToBottom in
            self?.updateMessageUI(id: id, shouldPinToBottom: shouldPinToBottom)
        }
    )

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
    private let openAI = OpenAIEventSourceClient(apiKey: "sk-api-ChgdHUf72NG1ZlFM_NvBuZeb7EYw3KsTf_L8enlR-gl4RngF2DgK04kF443WE-DnDpx50S5jkT6kFYgo-uDbjx3UO0wTqF_cfSe-2GM-AOBu40zWfEqwpk4")


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

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        openAI.stop()
        throttler.stop(flushPending: false)
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
    
    private func startOpenAIStream(prompt: String, assistantID: UUID) {
        openAI.startStream(
            prompt: prompt,
            onDelta: { [weak self] delta in
                guard let self else { return }
                Task { @MainActor in
                    self.viewModel.appendContent(to: assistantID, delta: delta)
                    self.throttler.markChanged(id: assistantID)
                }
            },
            onDone: { [weak self] in
                guard let self else { return }
                Task { @MainActor in
                    self.updateMessageUI(id: assistantID, shouldPinToBottom: false) // 最后一帧
                    self.openAI.stop()
                    self.throttler.stop()
                }
            },
            onError: { [weak self] error in
                guard let self else { return }
                Task { @MainActor in
                    print(error)
                    self.viewModel.setContent(for: assistantID, text: "❌ \(error.localizedDescription)\n\n（需要在 OpenAI 平台开通/充值 API 配额）")
                    self.updateMessageUI(id: assistantID, shouldPinToBottom: false)
                    self.openAI.stop()
                    self.throttler.stop()
                }
            }
        )
    }
    
    private func sendPrompt(_ prompt: String) {
        // 1) user 消息
        let userMsg = Message(role: .user, content: prompt)
        appendMessage(userMsg, scrollToBottom: true)

        // 2) assistant 占位消息（空内容）
        let assistantMsg = Message(role: .assistant, content: "")
        appendMessage(assistantMsg, scrollToBottom: true)

        // 3) 开始 SSE 流式
        startOpenAIStream(prompt: prompt, assistantID: assistantMsg.id)
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
            self?.sendPrompt("用一句话解释 SSE")
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

    func disableAutoPinForCurrentStream() {
        throttler.disablePinToBottomForCurrentStream()
    }
    
}

#Preview("Mock Chat") {
    UINavigationController(rootViewController: ChatViewController())
}
