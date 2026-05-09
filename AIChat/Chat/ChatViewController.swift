//
//  ViewController.swift
//  AIChat
//
//  Created by 周一见 on 2026/2/28.
//

import UIKit
import SnapKit

final class ChatViewController: UIViewController {

    struct StreamingLayoutState: Equatable {
        let itemIDs: [ChatItem.ID]
        let estimatedHeights: [Int]
    }

    // MARK: - Dependencies
    let viewModel = ChatViewModel(repository: LocalConversationRepository())
    private let systemPrompt = "你是一个简洁、专业的中文助手。数据表格、对比表、参数表必须使用标准 Markdown 表格。需要画流程、结构、时间线、坐标、层级等示意图时，可以使用 ASCII diagram，但必须放在代码块中。不要用 ASCII/框线图模拟数据表格。"
    private let streamClient = MiniMaxAnthropicStreamingClient()
    private let maxTokenHitsBeforeManualContinuation = 3
    private lazy var streamTextAnimator = StreamingTextAnimator { [weak self] id, contentDelta, reasoningDelta in
        guard let self else { return }
        self.viewModel.appendStreamDelta(
            to: id,
            contentDelta: contentDelta,
            reasoningDelta: reasoningDelta
        )
        self.throttler.markChanged(id: id)
    }

    // MARK: - UI
    var collectionView: UICollectionView!
    var dataSource: UICollectionViewDiffableDataSource<Section, ChatItem.ID>!
    var displayedItemsByID: [ChatItem.ID: ChatItem] = [:]
    var snapshotApplyGeneration = 0
    private let inputContainerView = UIView()
    private let inputBackgroundView = UIView()
    private let inputTextView = UITextView()
    private let sendButton = UIButton(type: .system)
    private var inputTextHeightConstraint: Constraint?
    private var currentStreamingAssistantID: UUID?
    private var continuationPrefixFilters: [UUID: StreamingContinuationPrefixFilter] = [:]
    var streamingLayoutStates: [UUID: StreamingLayoutState] = [:]

    lazy var throttler = StreamingThrottler(
        shouldPinToBottom: { [weak self] in
            guard let self else { return false }
            return !self.userIsInteracting && self.isNearBottom(tolerance: 150)
        },
        onTick: { [weak self] id, shouldPinToBottom in
            self?.updateStreamingMessageUI(id: id, shouldPinToBottom: shouldPinToBottom)
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

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Lifecycle
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        setupNavigationItems()
        setupInputComposer()
        setupCollectionView()
        setupDismissKeyboardGesture()
        setupDataSource()
        setupScrollToBottomButton()
        view.layoutIfNeeded()
        adjustInputHeightIfNeeded()
        applySnapshot(animatingDifferences: false)
        registerTraitObservers()
        registerKeyboardObservers()
        updateConversationTitle()
        updateSendButtonState()
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        scrollToBottomByItem(animated: false)
    }

    private var lastAppliedInputContainerHeight: CGFloat = 0
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        adjustInputHeightIfNeeded()
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        viewModel.invalidateAllHeights()
        collectionView?.collectionViewLayout.invalidateLayout()
        updateScrollToBottomButtonVisibility()
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
    
    private func registerKeyboardObservers() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleKeyboardWillChangeFrame(_:)),
            name: UIResponder.keyboardWillChangeFrameNotification,
            object: nil
        )
    }
    
    @objc private func handleKeyboardWillChangeFrame(_ notification: Notification) {
        guard
            let userInfo = notification.userInfo,
            let duration = userInfo[UIResponder.keyboardAnimationDurationUserInfoKey] as? TimeInterval,
            let curveRawValue = userInfo[UIResponder.keyboardAnimationCurveUserInfoKey] as? UInt
        else {
            return
        }

        let options = UIView.AnimationOptions(rawValue: curveRawValue << 16)

        // 只在接近底部时自动跟随，避免打断用户看历史消息
        let shouldStickToBottom = isNearBottom(tolerance: 500)

        UIView.animate(withDuration: duration, delay: 0, options: options) { [weak self] in
            guard let self else { return }
            self.view.layoutIfNeeded()
            
            if shouldStickToBottom {
                self.scrollToBottomByItem(animated: false)
            }
        }
    }
    
    private func startAssistantStream(request: ChatProviderRequest, assistantID: UUID) {
        streamClient.startStream(
            request: request,
            onDelta: { [weak self] contentDelta, reasoningDelta in
                guard let self else { return }
                Task { @MainActor in
                    let filteredContentDelta = self.filteredContinuationContentDelta(
                        contentDelta,
                        assistantID: assistantID
                    )
                    guard filteredContentDelta?.isEmpty == false || reasoningDelta?.isEmpty == false else {
                        return
                    }
                    self.streamTextAnimator.enqueue(
                        id: assistantID,
                        contentDelta: filteredContentDelta,
                        reasoningDelta: reasoningDelta
                    )
                }
            },
            onDone: { [weak self] finishReason in
                guard let self else { return }
                Task { @MainActor in
                    if finishReason == .maxTokens {
                        self.flushContinuationPrefixFilterIfNeeded(for: assistantID)
                        self.streamTextAnimator.flush(id: assistantID)
                        let maxTokenHitCount = self.viewModel.incrementMaxTokenHitCount(for: assistantID)
                        if !self.shouldShowManualContinuationButton(afterMaxTokenHitCount: maxTokenHitCount) {
                            self.updateMessageUI(id: assistantID, shouldPinToBottom: true)
                            self.viewModel.save()
                            let request = self.makeContinuationRequest()
                            self.prepareContinuationPrefixFilter(for: assistantID)
                            self.startAssistantStream(request: request, assistantID: assistantID)
                        } else {
                            self.viewModel.setStatus(for: assistantID, status: .needsContinuation)
                            self.updateMessageUI(id: assistantID, shouldPinToBottom: true)
                            self.viewModel.save()
                            self.stopCurrentStream(flushPending: true)
                        }
                        return
                    }

                    self.flushContinuationPrefixFilterIfNeeded(for: assistantID)
                    await self.streamTextAnimator.drain(id: assistantID)
                    self.viewModel.setStatus(for: assistantID, status: .success)
                    self.updateMessageUI(id: assistantID, shouldPinToBottom: false)
                    self.viewModel.save()
                    self.stopCurrentStream(flushPending: true)
                }
            },
            onError: { [weak self] error in
                guard let self else { return }
                Task { @MainActor in
                    self.continuationPrefixFilters.removeValue(forKey: assistantID)
                    self.streamTextAnimator.flush(id: assistantID)
                    let currentText = self.viewModel.message(id: assistantID)?.contentText ?? ""
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

        if isContinuePrompt(trimmed),
           let assistantID = viewModel.latestContinuableAssistantID() {
            continueGeneration(for: assistantID)
            return
        }

        let userMsg = Message(role: .user, content: trimmed)
        appendMessage(userMsg, scrollToBottom: true)

        let request = viewModel.chatProviderRequest(systemPrompt: systemPrompt)

        let assistantMsg = Message(role: .assistant, content: "", status: .pending)
        appendMessage(assistantMsg, scrollToBottom: true)

        currentStreamingAssistantID = assistantMsg.id
        isStreaming = true
        updateConversationTitle()
        updateSendButtonState()
        startAssistantStream(request: request, assistantID: assistantMsg.id)
    }

    private func updateSendButtonState() {
        let hasText = !inputTextView.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        sendButton.configuration?.title = isStreaming ? "停止" : "发送"
        sendButton.isEnabled = isStreaming || hasText
        sendButton.alpha = sendButton.isEnabled ? 1 : 0.45
    }

    private func stopCurrentStream(flushPending: Bool) {
        if let currentStreamingAssistantID {
            if flushPending {
                flushContinuationPrefixFilterIfNeeded(for: currentStreamingAssistantID)
                streamTextAnimator.flush(id: currentStreamingAssistantID)
            } else {
                continuationPrefixFilters.removeValue(forKey: currentStreamingAssistantID)
                streamTextAnimator.discard(id: currentStreamingAssistantID)
            }
            streamingLayoutStates.removeValue(forKey: currentStreamingAssistantID)
        }
        streamClient.stop()
        throttler.stop(flushPending: flushPending)
        viewModel.save()
        isStreaming = false
        currentStreamingAssistantID = nil
        updateSendButtonState()
    }

    private func shouldShowManualContinuationButton(afterMaxTokenHitCount count: Int) -> Bool {
        count > 0 && count.isMultiple(of: maxTokenHitsBeforeManualContinuation)
    }

    private func prepareContinuationPrefixFilter(for assistantID: UUID) {
        guard let existingText = viewModel.message(id: assistantID)?.contentText,
              !existingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            continuationPrefixFilters.removeValue(forKey: assistantID)
            return
        }

        continuationPrefixFilters[assistantID] = StreamingContinuationPrefixFilter(existingText: existingText)
    }

    private func filteredContinuationContentDelta(_ contentDelta: String?, assistantID: UUID) -> String? {
        guard let contentDelta else { return nil }
        guard let filter = continuationPrefixFilters[assistantID] else { return contentDelta }

        let filteredDelta = filter.consume(contentDelta)
        if filter.isResolved {
            continuationPrefixFilters.removeValue(forKey: assistantID)
        }
        return filteredDelta
    }

    private func flushContinuationPrefixFilterIfNeeded(for assistantID: UUID) {
        guard let filter = continuationPrefixFilters.removeValue(forKey: assistantID),
              let contentDelta = filter.flush(),
              !contentDelta.isEmpty
        else {
            return
        }

        streamTextAnimator.enqueue(
            id: assistantID,
            contentDelta: contentDelta,
            reasoningDelta: nil
        )
    }

    private func makeContinuationRequest() -> ChatProviderRequest {
        let baseRequest = viewModel.chatProviderRequest(systemPrompt: systemPrompt)
        let continuationPrompt = """
        请从你上一条 assistant 回复的最后一个字符之后继续输出。
        不要重复已经输出过的任何标题、段落、表格行、代码块或最后一句话。
        不要重写开头，不要解释原因，直接续写未完成内容。
        如果正在输出数据表格、对比表或参数表，请使用标准 Markdown 表格语法。
        如果正在输出流程、结构、时间线、坐标或层级示意图，可以使用 ASCII diagram，但必须放在代码块中。
        不要用 ASCII/框线图模拟数据表格。
        """
        return ChatProviderRequest(
            systemPrompt: baseRequest.systemPrompt,
            messages: baseRequest.messages + [
                ChatProviderMessage(role: .user, content: continuationPrompt)
            ]
        )
    }

    private func cancelCurrentStream() {
        guard isStreaming, let assistantID = currentStreamingAssistantID else { return }
        stopCurrentStream(flushPending: true)
        viewModel.setStatus(for: assistantID, status: .canceled)
        streamingLayoutStates.removeValue(forKey: assistantID)
        updateMessageUI(id: assistantID, shouldPinToBottom: false)
        viewModel.save()
    }

    func continueGeneration(for assistantID: UUID) {
        guard !isStreaming,
              viewModel.message(id: assistantID)?.status == .needsContinuation
        else {
            return
        }

        let request = makeContinuationRequest()

        currentStreamingAssistantID = assistantID
        isStreaming = true
        viewModel.setStatus(for: assistantID, status: .streaming)
        updateMessageUI(id: assistantID, shouldPinToBottom: true)
        updateSendButtonState()
        prepareContinuationPrefixFilter(for: assistantID)
        startAssistantStream(request: request, assistantID: assistantID)
    }

    private func isContinuePrompt(_ text: String) -> Bool {
        let normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return ["继续", "继续生成", "续写", "continue"].contains(normalized)
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
        reloadConversationMessages(scrollToBottom: true)
        updateConversationTitle()
        inputTextView.text = ""
        adjustInputHeightIfNeeded()
        updateSendButtonState()
    }

    private func switchConversation(to id: UUID) {
        stopCurrentStream(flushPending: false)
        guard viewModel.selectConversation(id: id) else { return }
        reloadConversationMessages(scrollToBottom: true)
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
        layout.minimumLineSpacing = 0
        layout.minimumInteritemSpacing = 0
        layout.sectionInset = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        layout.estimatedItemSize = .zero

        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.backgroundColor = .clear
        collectionView.alwaysBounceVertical = true
        collectionView.delegate = self

        collectionView.register(ChatTextBlockCell.self, forCellWithReuseIdentifier: ChatTextBlockCell.reuseID)
        collectionView.register(ChatTableBlockCell.self, forCellWithReuseIdentifier: ChatTableBlockCell.reuseID)
        collectionView.register(ChatCodeBlockCell.self, forCellWithReuseIdentifier: ChatCodeBlockCell.reuseID)
        collectionView.register(ChatImageBlockCell.self, forCellWithReuseIdentifier: ChatImageBlockCell.reuseID)
        collectionView.register(ChatControlCell.self, forCellWithReuseIdentifier: ChatControlCell.reuseID)
        view.addSubview(collectionView)

        collectionView.snp.makeConstraints { make in
            make.top.equalTo(view.safeAreaLayoutGuide.snp.top)
            make.leading.trailing.equalTo(view.safeAreaLayoutGuide)
            make.bottom.equalTo(inputContainerView.snp.top)
        }
    }
    
    private func setupDismissKeyboardGesture() {
        let tap = UITapGestureRecognizer(target: self, action: #selector(dismissKeyboardTap(_:)))
        tap.cancelsTouchesInView = false
        tap.delaysTouchesBegan = false
        tap.delaysTouchesEnded = false
        tap.delegate = self
        collectionView.addGestureRecognizer(tap)
    }

    @objc private func dismissKeyboardTap(_ gesture: UITapGestureRecognizer) {
        view.endEditing(true)
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
            make.trailing.equalTo(view.safeAreaLayoutGuide).inset(12)
            make.bottom.equalTo(inputContainerView.safeAreaLayoutGuide).inset(10)
            make.width.greaterThanOrEqualTo(64)
        }

        inputBackgroundView.snp.makeConstraints { make in
            make.leading.equalTo(view.safeAreaLayoutGuide).offset(12)
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
            make.trailing.equalTo(view.safeAreaLayoutGuide).inset(16)
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

    func refreshAutoPinForCurrentStreamIfNeeded() {
        throttler.refreshPinToBottomForCurrentStream()
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

extension ChatViewController: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard let touchedView = touch.view else { return true }

        // 输入区域不收
        if touchedView.isDescendant(of: inputContainerView) {
            return false
        }

        // 点到 UIControl（按钮等）不收
        if touchedView is UIControl {
            return false
        }

        return true
    }
}

extension ChatViewController {
    func reloadConversationMessages(scrollToBottom: Bool) {
        applySnapshot(animatingDifferences: false)
        viewModel.pruneHeightCache()
        collectionView.reloadData()
        collectionView.layoutIfNeeded()

        if scrollToBottom {
            DispatchQueue.main.async { [weak self] in
                self?.scrollToBottomByItem(animated: false)
            }
        }

        updateScrollToBottomButtonVisibility()
    }
}

#Preview("Mock Chat") {
    UINavigationController(rootViewController: ChatViewController())
}
