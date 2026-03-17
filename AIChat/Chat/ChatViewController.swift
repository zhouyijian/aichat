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
    let viewModel = ChatViewModel(repository: LocalConversationRepository())
    private let systemPrompt = "你是一个简洁、专业的中文助手。"
    private let openAI = OpenAIEventSourceClient(apiKey: "sk-api-ChgdHUf72NG1ZlFM_NvBuZeb7EYw3KsTf_L8enlR-gl4RngF2DgK04kF443WE-DnDpx50S5jkT6kFYgo-uDbjx3UO0wTqF_cfSe-2GM-AOBu40zWfEqwpk4")

    // MARK: - UI
    var collectionView: UICollectionView!
    var dataSource: UICollectionViewDiffableDataSource<Section, UUID>!
    lazy var sizingCell = MessageCell(frame: .zero)
    private let inputContainerView = UIView()
    private let inputBackgroundView = UIView()
    private let inputTextView = UITextView()
    private let sendButton = UIButton(type: .system)
    private var inputTextHeightConstraint: Constraint?
    private var currentStreamingAssistantID: UUID?

    lazy var throttler = StreamingThrottler(
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
    private var isStreaming = false

    // MARK: - Lifecycle
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        setupNavigationItems()
        setupInputComposer()
        setupCollectionView()
        setupDataSource()
        setupScrollToBottomButton()
        view.layoutIfNeeded()
        adjustInputHeightIfNeeded()
        applySnapshot(animatingDifferences: false)
        registerTraitObservers()
        updateConversationTitle()
        updateSendButtonState()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        adjustInputHeightIfNeeded()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        stopCurrentStream(flushPending: false)
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

    private func startOpenAIStream(history: [[String: String]], assistantID: UUID) {
        openAI.startStream(
            messages: history,
            onDelta: { [weak self] contentDelta, reasoningDelta in
                guard let self else { return }
                Task { @MainActor in
                    if let reasoningDelta {
                        self.viewModel.appendReasoning(to: assistantID, delta: reasoningDelta)
                    }
                    if let contentDelta {
                        self.viewModel.appendContent(to: assistantID, delta: contentDelta)
                    }
                    self.viewModel.setStatus(for: assistantID, status: .streaming)
                    self.throttler.markChanged(id: assistantID)
                }
            },
            onDone: { [weak self] in
                guard let self else { return }
                Task { @MainActor in
                    self.viewModel.setStatus(for: assistantID, status: .success)
                    self.updateMessageUI(id: assistantID, shouldPinToBottom: false)
                    self.viewModel.save()
                    self.stopCurrentStream(flushPending: true)
                }
            },
            onError: { [weak self] error in
                guard let self else { return }
                Task { @MainActor in
                    let currentText = self.viewModel.message(id: assistantID)?.content ?? ""
                    let message = currentText.isEmpty ? "❌ \(error.localizedDescription)" : "\(currentText)\n\n❌ \(error.localizedDescription)"
                    self.viewModel.setContent(for: assistantID, text: message)
                    self.viewModel.setStatus(for: assistantID, status: .failed(error.localizedDescription))
                    self.updateMessageUI(id: assistantID, shouldPinToBottom: false)
                    self.viewModel.save()
                    self.stopCurrentStream(flushPending: true)
                }
            }
        )
    }

    private func sendPrompt(_ prompt: String) {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isStreaming else { return }

        let userMsg = Message(role: .user, content: trimmed)
        appendMessage(userMsg, scrollToBottom: true)

        let history = viewModel.chatHistoryForRequest(systemPrompt: systemPrompt)

        let assistantMsg = Message(role: .assistant, content: "", status: .pending)
        appendMessage(assistantMsg, scrollToBottom: true)

        currentStreamingAssistantID = assistantMsg.id
        isStreaming = true
        updateConversationTitle()
        updateSendButtonState()
        startOpenAIStream(history: history, assistantID: assistantMsg.id)
    }

    private func updateSendButtonState() {
        let hasText = !inputTextView.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        sendButton.configuration?.title = isStreaming ? "停止" : "发送"
        sendButton.isEnabled = isStreaming || hasText
        sendButton.alpha = sendButton.isEnabled ? 1 : 0.45
    }

    private func stopCurrentStream(flushPending: Bool) {
        openAI.stop()
        throttler.stop(flushPending: flushPending)
        viewModel.save()
        isStreaming = false
        currentStreamingAssistantID = nil
        updateSendButtonState()
    }

    private func cancelCurrentStream() {
        guard isStreaming, let assistantID = currentStreamingAssistantID else { return }
        viewModel.setStatus(for: assistantID, status: .canceled)
        updateMessageUI(id: assistantID, shouldPinToBottom: false)
        stopCurrentStream(flushPending: true)
    }

    private func updateConversationTitle() {
        title = viewModel.currentConversationTitle
    }

    private func adjustInputHeightIfNeeded() {
        let width = inputTextView.bounds.width
        guard width > 0 else { return }

        let fitting = inputTextView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        let minHeight: CGFloat = 22
        let maxHeight: CGFloat = 120
        let clamped = min(max(minHeight, fitting), maxHeight)

        inputTextView.isScrollEnabled = fitting > maxHeight
        inputTextHeightConstraint?.update(offset: clamped)
    }

    private func startNewConversation() {
        stopCurrentStream(flushPending: false)
        _ = viewModel.startNewConversation()
        reloadConversationMessages()
        updateConversationTitle()
        inputTextView.text = ""
        adjustInputHeightIfNeeded()
        updateSendButtonState()
    }

    private func switchConversation(to id: UUID) {
        stopCurrentStream(flushPending: false)
        guard viewModel.selectConversation(id: id) else { return }
        reloadConversationMessages()
        updateConversationTitle()
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

    private func setupNavigationItems() {
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: "对话",
            style: .plain,
            target: self,
            action: #selector(didTapConversationList)
        )

        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "square.and.pencil"),
            style: .plain,
            target: self,
            action: #selector(didTapCreateConversation)
        )
    }

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
        collectionView.keyboardDismissMode = .interactive
        collectionView.delegate = self

        collectionView.register(MessageCell.self, forCellWithReuseIdentifier: MessageCell.reuseID)
        view.addSubview(collectionView)

        collectionView.snp.makeConstraints { make in
            make.top.leading.trailing.equalToSuperview()
            make.bottom.equalTo(inputContainerView.snp.top)
        }
    }

    func setupInputComposer() {
        inputContainerView.backgroundColor = .systemBackground
        view.addSubview(inputContainerView)
        inputContainerView.snp.makeConstraints { make in
            make.leading.trailing.equalToSuperview()
            make.bottom.equalTo(view.keyboardLayoutGuide.snp.top)
        }

        inputBackgroundView.backgroundColor = .secondarySystemBackground
        inputBackgroundView.layer.cornerRadius = 20
        inputBackgroundView.layer.masksToBounds = true

        inputTextView.font = .systemFont(ofSize: 16)
        inputTextView.textColor = .label
        inputTextView.backgroundColor = .clear
        inputTextView.isScrollEnabled = false
        inputTextView.textContainerInset = UIEdgeInsets(top: 8, left: 2, bottom: 8, right: 2)
        inputTextView.delegate = self

        var config = UIButton.Configuration.filled()
        config.title = "发送"
        config.cornerStyle = .capsule
        config.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 14, bottom: 8, trailing: 14)
        sendButton.configuration = config
        sendButton.setContentHuggingPriority(.required, for: .horizontal)
        sendButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        sendButton.addTarget(self, action: #selector(didTapSend), for: .touchUpInside)

        inputContainerView.addSubview(inputBackgroundView)
        inputContainerView.addSubview(sendButton)
        inputBackgroundView.addSubview(inputTextView)

        inputContainerView.snp.makeConstraints { make in
            make.top.equalTo(inputBackgroundView.snp.top).offset(-10)
        }

        sendButton.snp.makeConstraints { make in
            make.trailing.equalToSuperview().inset(12)
            make.bottom.equalTo(inputContainerView.safeAreaLayoutGuide).inset(10)
            make.width.greaterThanOrEqualTo(64)
        }

        inputBackgroundView.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(12)
            make.trailing.equalTo(sendButton.snp.leading).offset(-8)
            make.bottom.equalTo(sendButton.snp.bottom)
            make.top.equalToSuperview().offset(10)
        }

        inputTextView.snp.makeConstraints { make in
            make.edges.equalToSuperview().inset(UIEdgeInsets(top: 4, left: 10, bottom: 4, right: 10))
            inputTextHeightConstraint = make.height.equalTo(22).constraint
        }
    }

    func setupScrollToBottomButton() {
        view.addSubview(scrollToBottomButton)
        scrollToBottomButton.snp.makeConstraints { make in
            make.trailing.equalToSuperview().inset(16)
            make.bottom.equalTo(inputContainerView.snp.top).offset(-12)
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

    @objc
    private func didTapSend() {
        if isStreaming {
            cancelCurrentStream()
            return
        }

        sendPrompt(inputTextView.text)
        inputTextView.text = ""
        adjustInputHeightIfNeeded()
        updateSendButtonState()
    }

    @objc
    private func didTapCreateConversation() {
        startNewConversation()
    }

    @objc
    private func didTapConversationList() {
        let list = ConversationListViewController(
            summaries: viewModel.conversationSummaries(),
            onSelectConversation: { [weak self] conversationID in
                self?.switchConversation(to: conversationID)
            },
            onCreateConversation: { [weak self] in
                self?.startNewConversation()
            }
        )

        let nav = UINavigationController(rootViewController: list)
        nav.modalPresentationStyle = .pageSheet
        if let sheet = nav.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
        present(nav, animated: true)
    }
}

extension ChatViewController: UITextViewDelegate {
    func textViewDidChange(_ textView: UITextView) {
        adjustInputHeightIfNeeded()
        updateSendButtonState()
    }
}

#Preview("Mock Chat") {
    UINavigationController(rootViewController: ChatViewController())
}
