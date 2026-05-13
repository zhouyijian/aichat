//
//  ViewController.swift
//  AIChat
//
//  Created by 周一见 on 2026/2/28.
//

import UIKit
import SnapKit

private enum ToolConfirmationCancellation: Error {
    case canceled
}

final class ChatViewController: UIViewController {

    struct StreamingLayoutState: Equatable {
        let itemIDs: [ChatItem.ID]
        let estimatedHeights: [Int]
    }

    // MARK: - Dependencies
    let viewModel = ChatViewModel(repository: LocalConversationRepository())
    private let systemPrompt = "你是一个简洁、专业的中文助手。数据表格、对比表、参数表必须使用标准 Markdown 表格。需要画流程、结构、时间线、坐标、层级等示意图时，可以使用 ASCII diagram，但必须放在代码块中。不要用 ASCII/框线图模拟数据表格。"
    private let toolPlannerClient = ToolPlannerClient()
    private let toolRegistry = ToolRegistry.makeDefault()
    private let memoryStore = LocalMemoryStore()
    private let memoryExtractor = MemoryExtractor()
    private let memoryContextBuilder = MemoryContextBuilder()
    private let maxTokenHitsBeforeManualContinuation = 3
    private lazy var streamTextAnimator = StreamingTextAnimator { [weak self] id, contentDelta, reasoningDelta in
        guard let self else { return }
        self.viewModel.appendStreamDelta(
            to: id,
            contentDelta: contentDelta,
            reasoningDelta: reasoningDelta
        )
        if self.viewModel.conversationID(containingMessageID: id) == self.viewModel.currentConversationID {
            self.throttler.markChanged(id: id)
        }
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
    private var activeAssistantIDByConversationID: [UUID: UUID] = [:]
    private var activeConversationIDByAssistantID: [UUID: UUID] = [:]
    private var toolTasksByConversationID: [UUID: Task<Void, Never>] = [:]
    private var streamClientsByConversationID: [UUID: MiniMaxAnthropicStreamingClient] = [:]
    private var continuationPrefixFilters: [UUID: StreamingContinuationPrefixFilter] = [:]
    private var didPerformInitialAppearanceScroll = false
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

    deinit {
        NotificationCenter.default.removeObserver(self)
        for conversationID in Array(activeAssistantIDByConversationID.keys) {
            cancelGenerationIfNeeded(for: conversationID, flushPending: false)
        }
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
        guard !didPerformInitialAppearanceScroll else { return }
        didPerformInitialAppearanceScroll = true
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
    
    private func startAssistantStream(
        request: ChatProviderRequest,
        conversationID: UUID,
        assistantID: UUID
    ) {
        let streamClient = MiniMaxAnthropicStreamingClient()
        streamClientsByConversationID[conversationID] = streamClient
        streamClient.startStream(
            request: request,
            onDelta: { [weak self] contentDelta, reasoningDelta in
                guard let self else { return }
                Task { @MainActor in
                    guard self.activeAssistantIDByConversationID[conversationID] == assistantID else { return }
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
                    guard self.activeAssistantIDByConversationID[conversationID] == assistantID else { return }
                    if finishReason == .maxTokens {
                        self.flushContinuationPrefixFilterIfNeeded(for: assistantID)
                        self.streamTextAnimator.flush(id: assistantID)
                        let maxTokenHitCount = self.viewModel.incrementMaxTokenHitCount(for: assistantID)
                        if !self.shouldShowManualContinuationButton(afterMaxTokenHitCount: maxTokenHitCount) {
                            self.updateMessageUIIfVisible(
                                id: assistantID,
                                shouldPinToBottom: self.shouldAutoPinToBottomDuringGeneration()
                            )
                            self.viewModel.save()
                            let request = self.makeContinuationRequest(conversationID: conversationID)
                            self.prepareContinuationPrefixFilter(for: assistantID)
                            self.startAssistantStream(
                                request: request,
                                conversationID: conversationID,
                                assistantID: assistantID
                            )
                        } else {
                            self.viewModel.setStatus(for: assistantID, status: .needsContinuation)
                            self.updateMessageUIIfVisible(
                                id: assistantID,
                                shouldPinToBottom: self.shouldAutoPinToBottomDuringGeneration()
                            )
                            self.viewModel.save()
                            self.finishGeneration(
                                conversationID: conversationID,
                                assistantID: assistantID,
                                flushPending: true,
                                cancelTask: false
                            )
                        }
                        return
                    }

                    self.flushContinuationPrefixFilterIfNeeded(for: assistantID)
                    await self.streamTextAnimator.drain(id: assistantID)
                    self.viewModel.setStatus(for: assistantID, status: .success)
                    self.updateMessageUIIfVisible(id: assistantID, shouldPinToBottom: false)
                    self.viewModel.save()
                    self.finishGeneration(
                        conversationID: conversationID,
                        assistantID: assistantID,
                        flushPending: true,
                        cancelTask: false
                    )
                }
            },
            onError: { [weak self] error in
                guard let self else { return }
                Task { @MainActor in
                    guard self.activeAssistantIDByConversationID[conversationID] == assistantID else { return }
                    self.continuationPrefixFilters.removeValue(forKey: assistantID)
                    self.streamTextAnimator.flush(id: assistantID)
                    let currentText = self.viewModel.message(id: assistantID)?.contentText ?? ""
                    let message = currentText.isEmpty ? "❌ \(error.localizedDescription)" : "\(currentText)\n\n❌ \(error.localizedDescription)"
                    self.viewModel.setContent(for: assistantID, text: message)
                    self.viewModel.setStatus(for: assistantID, status: .failed(error.localizedDescription))
                    self.updateMessageUIIfVisible(id: assistantID, shouldPinToBottom: false)
                    self.viewModel.save()
                    self.finishGeneration(
                        conversationID: conversationID,
                        assistantID: assistantID,
                        flushPending: true,
                        cancelTask: false
                    )
                }
            }
        )
    }

    private func sendPrompt(_ prompt: String) {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let conversationID = viewModel.currentConversationID
        guard !trimmed.isEmpty, !isConversationStreaming(conversationID) else { return }

        if isContinuePrompt(trimmed),
           let assistantID = viewModel.latestContinuableAssistantID() {
            continueGeneration(for: assistantID)
            return
        }

        let userMsg = Message(role: .user, content: trimmed)
        appendMessage(userMsg, scrollToBottom: true)

        let request = viewModel.chatProviderRequest(
            systemPrompt: systemPromptWithMemory(),
            conversationID: conversationID
        )
        persistMemory(userText: trimmed, toolResult: nil)

        let assistantMsg = Message(role: .assistant, content: "", status: .pending)
        appendMessage(assistantMsg, scrollToBottom: true)

        registerActiveGeneration(conversationID: conversationID, assistantID: assistantMsg.id)
        updateConversationTitle()
        updateSendButtonState()
        startToolPlanningOrStream(
            request: request,
            userText: trimmed,
            conversationID: conversationID,
            assistantID: assistantMsg.id
        )
    }

    private func startToolPlanningOrStream(
        request: ChatProviderRequest,
        userText: String,
        conversationID: UUID,
        assistantID: UUID
    ) {
        toolTasksByConversationID[conversationID]?.cancel()
        toolTasksByConversationID[conversationID] = Task { @MainActor [weak self] in
            await self?.planAndExecuteOrStream(
                request: request,
                userText: userText,
                conversationID: conversationID,
                assistantID: assistantID
            )
        }
    }

    @MainActor
    private func planAndExecuteOrStream(
        request: ChatProviderRequest,
        userText: String,
        conversationID: UUID,
        assistantID: UUID
    ) async {
        do {
            let routedCalls = ToolIntentRouter.toolCalls(for: userText)
            if !routedCalls.isEmpty {
                viewModel.setContent(for: assistantID, text: routedToolStatusText(for: routedCalls))
                updateMessageUIIfVisible(
                    id: assistantID,
                    shouldPinToBottom: shouldAutoPinToBottomDuringGeneration()
                )

                let result = try await executeToolCalls(routedCalls, userText: userText)
                guard !Task.isCancelled else { return }

                let shouldPinToBottom = shouldAutoPinToBottomDuringGeneration()
                viewModel.setToolResult(for: assistantID, result: result)
                updateMessageUIIfVisible(id: assistantID, shouldPinToBottom: shouldPinToBottom)
                persistMemory(userText: userText, toolResult: result)
                viewModel.save()
                finishGeneration(
                    conversationID: conversationID,
                    assistantID: assistantID,
                    flushPending: true,
                    cancelTask: false
                )
                return
            }

            let planning = try await toolPlannerClient.plan(
                request: request,
                tools: toolRegistry.definitions
            )
            guard !Task.isCancelled else { return }

            guard planning.shouldExecuteTool else {
                toolTasksByConversationID[conversationID] = nil
                startAssistantStream(
                    request: request,
                    conversationID: conversationID,
                    assistantID: assistantID
                )
                return
            }

            viewModel.setContent(for: assistantID, text: "正在执行工具...")
            updateMessageUIIfVisible(
                id: assistantID,
                shouldPinToBottom: shouldAutoPinToBottomDuringGeneration()
            )

            let result = try await executeToolCalls(planning.toolCalls, userText: userText)
            guard !Task.isCancelled else { return }

            let shouldPinToBottom = shouldAutoPinToBottomDuringGeneration()
            viewModel.setToolResult(for: assistantID, result: result)
            updateMessageUIIfVisible(id: assistantID, shouldPinToBottom: shouldPinToBottom)
            persistMemory(userText: userText, toolResult: result)
            viewModel.save()
            finishGeneration(
                conversationID: conversationID,
                assistantID: assistantID,
                flushPending: true,
                cancelTask: false
            )
        } catch ToolConfirmationCancellation.canceled {
            viewModel.setContent(for: assistantID, text: "已取消操作")
            viewModel.setStatus(for: assistantID, status: .success)
            updateMessageUIIfVisible(id: assistantID, shouldPinToBottom: false)
            viewModel.save()
            finishGeneration(
                conversationID: conversationID,
                assistantID: assistantID,
                flushPending: false,
                cancelTask: false
            )
        } catch is CancellationError {
            finishGeneration(
                conversationID: conversationID,
                assistantID: assistantID,
                flushPending: false,
                cancelTask: false
            )
        } catch {
            let message = "工具调用失败：\(error.localizedDescription)"
            viewModel.setContent(for: assistantID, text: message)
            viewModel.setStatus(for: assistantID, status: .failed(error.localizedDescription))
            updateMessageUIIfVisible(id: assistantID, shouldPinToBottom: false)
            viewModel.save()
            finishGeneration(
                conversationID: conversationID,
                assistantID: assistantID,
                flushPending: true,
                cancelTask: false
            )
        }
    }

    private func routedToolStatusText(for calls: [ToolCall]) -> String {
        switch calls.first?.name {
        case "generate_image":
            return "正在生成图片，请稍候..."
        case "create_reminder":
            return "正在添加提醒..."
        case "create_alarm":
            return "正在设置闹钟..."
        default:
            return "正在执行工具..."
        }
    }

    private func shouldAutoPinToBottomDuringGeneration() -> Bool {
        !userIsInteracting && isNearBottom(tolerance: 150)
    }

    private func executeToolCalls(_ calls: [ToolCall], userText: String) async throws -> ToolExecutionResult {
        let cappedCalls = Array(calls.prefix(3))
        try await confirmToolCallsIfNeeded(cappedCalls)

        var results: [ToolExecutionResult] = []
        for call in cappedCalls {
            results.append(try await toolRegistry.execute(enrichedToolCall(call, userText: userText)))
        }

        guard let first = results.first else {
            throw ToolExecutionError.executionFailed("模型没有返回可执行工具")
        }

        guard results.count > 1 else { return first }

        let blocks = results.flatMap(\.blocks)
        return ToolExecutionResult(
            toolName: "multiple_tools",
            ok: results.allSatisfy(\.ok),
            displayText: results.map(\.displayText).joined(separator: "\n"),
            blocks: blocks,
            structuredData: .object([
                "results": .array(results.map { result in
                    .object([
                        "tool": .string(result.toolName),
                        "ok": .bool(result.ok),
                        "display_text": .string(result.displayText),
                        "data": result.structuredData
                    ])
                })
            ])
        )
    }

    @MainActor
    private func confirmToolCallsIfNeeded(_ calls: [ToolCall]) async throws {
        let callsNeedingConfirmation = calls.filter(requiresConfirmation)
        guard !callsNeedingConfirmation.isEmpty else { return }

        let confirmed = await presentToolConfirmation(for: callsNeedingConfirmation)
        guard confirmed else {
            throw ToolConfirmationCancellation.canceled
        }
    }

    private func requiresConfirmation(_ call: ToolCall) -> Bool {
        call.name == "create_reminder" || call.name == "create_alarm"
    }

    @MainActor
    private func presentToolConfirmation(for calls: [ToolCall]) async -> Bool {
        await withCheckedContinuation { continuation in
            let title = calls.count == 1 ? confirmationTitle(for: calls[0]) : "确认执行工具"
            let message = calls.map(confirmationSummary).joined(separator: "\n\n")
            let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in
                continuation.resume(returning: false)
            })
            alert.addAction(UIAlertAction(title: "确认", style: .default) { _ in
                continuation.resume(returning: true)
            })
            present(alert, animated: true)
        }
    }

    private func confirmationTitle(for call: ToolCall) -> String {
        switch call.name {
        case "create_reminder":
            return "确认添加提醒"
        case "create_alarm":
            return "确认设置闹钟"
        default:
            return "确认执行工具"
        }
    }

    private func confirmationSummary(for call: ToolCall) -> String {
        switch call.name {
        case "create_reminder":
            let title = call.input["title"]?.stringValue ?? "提醒事项"
            let dueAt = call.input["due_at"]?.stringValue ?? "未指定时间"
            let notes = call.input["notes"]?.stringValue
            return [
                "提醒事项：\(title)",
                "时间：\(dueAt)",
                notes.map { "备注：\($0)" }
            ].compactMap(\.self).joined(separator: "\n")
        case "create_alarm":
            let label = call.input["label"]?.stringValue ?? "闹钟"
            let fireAt = call.input["fire_at"]?.stringValue ?? "未指定时间"
            let repeatRule = call.input["repeat_rule"]?.stringValue ?? "none"
            return [
                "闹钟：\(label)",
                "时间：\(fireAt)",
                "重复：\(displayRepeatRule(repeatRule))"
            ].joined(separator: "\n")
        default:
            return "工具：\(call.name)"
        }
    }

    private func displayRepeatRule(_ repeatRule: String) -> String {
        switch repeatRule {
        case "daily":
            return "每天"
        case "weekdays":
            return "工作日"
        case "weekends":
            return "周末"
        default:
            return "不重复"
        }
    }

    private func enrichedToolCall(_ call: ToolCall, userText: String) -> ToolCall {
        guard call.name == "generate_image",
              var input = call.input.objectValue else {
            return call
        }

        let caption = input["caption"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        if caption?.isEmpty != false || !containsChinese(caption ?? "") {
            input["caption"] = .string(userText.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        let prompt = input["prompt"]?.stringValue ?? userText
        let noEnglishTextInstruction = "画面中不要出现英文单词、英文字母、水印、Logo 或可读英文；除非用户明确要求英文文字，如需招牌或界面文字请使用中文或抽象符号。"
        if !prompt.contains(noEnglishTextInstruction) {
            input["prompt"] = .string("\(prompt)\n\(noEnglishTextInstruction)")
        }

        return ToolCall(id: call.id, name: call.name, input: .object(input))
    }

    private func containsChinese(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            (0x4E00...0x9FFF).contains(Int(scalar.value)) ||
            (0x3400...0x4DBF).contains(Int(scalar.value))
        }
    }

    private func persistMemory(userText: String, toolResult: ToolExecutionResult?) {
        let updated = memoryExtractor.updatedRecords(
            existing: memoryStore.load(),
            userText: userText,
            toolResult: toolResult
        )
        memoryStore.save(updated)
    }

    private func systemPromptWithMemory() -> String {
        systemPrompt + memoryContextBuilder.context(from: memoryStore.load())
    }

    private func updateSendButtonState() {
        let hasText = !inputTextView.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let isCurrentConversationStreaming = isConversationStreaming(viewModel.currentConversationID)
        sendButton.configuration?.title = isCurrentConversationStreaming ? "停止" : "发送"
        sendButton.isEnabled = isCurrentConversationStreaming || hasText
        sendButton.alpha = sendButton.isEnabled ? 1 : 0.45
    }

    private func isConversationStreaming(_ conversationID: UUID) -> Bool {
        activeAssistantIDByConversationID[conversationID] != nil
    }

    private func registerActiveGeneration(conversationID: UUID, assistantID: UUID) {
        activeAssistantIDByConversationID[conversationID] = assistantID
        activeConversationIDByAssistantID[assistantID] = conversationID
    }

    private func updateMessageUIIfVisible(id: UUID, shouldPinToBottom: Bool) {
        guard viewModel.conversationID(containingMessageID: id) == viewModel.currentConversationID else { return }
        let shouldPin = shouldPinToBottom && shouldAutoPinToBottomDuringGeneration()
        updateMessageUI(id: id, shouldPinToBottom: shouldPin)
    }

    private func finishGeneration(
        conversationID: UUID,
        assistantID: UUID,
        flushPending: Bool,
        cancelTask: Bool
    ) {
        if cancelTask {
            toolTasksByConversationID[conversationID]?.cancel()
        }
        toolTasksByConversationID[conversationID] = nil

        if flushPending {
            flushContinuationPrefixFilterIfNeeded(for: assistantID)
            streamTextAnimator.flush(id: assistantID)
        } else {
            continuationPrefixFilters.removeValue(forKey: assistantID)
            streamTextAnimator.discard(id: assistantID)
        }

        streamingLayoutStates.removeValue(forKey: assistantID)
        streamClientsByConversationID[conversationID]?.stop()
        streamClientsByConversationID[conversationID] = nil
        activeAssistantIDByConversationID[conversationID] = nil
        activeConversationIDByAssistantID[assistantID] = nil
        if conversationID == viewModel.currentConversationID {
            throttler.stop(
                flushPending: flushPending,
                shouldPinToBottom: shouldAutoPinToBottomDuringGeneration()
            )
            updateSendButtonState()
        }
        viewModel.save()
    }

    private func cancelGenerationIfNeeded(for conversationID: UUID, flushPending: Bool) {
        guard let assistantID = activeAssistantIDByConversationID[conversationID] else { return }
        finishGeneration(
            conversationID: conversationID,
            assistantID: assistantID,
            flushPending: flushPending,
            cancelTask: true
        )
    }

    private func stopCurrentStream(flushPending: Bool) {
        cancelGenerationIfNeeded(for: viewModel.currentConversationID, flushPending: flushPending)
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

    private func makeContinuationRequest(conversationID: UUID? = nil) -> ChatProviderRequest {
        let baseRequest = viewModel.chatProviderRequest(
            systemPrompt: systemPromptWithMemory(),
            conversationID: conversationID
        )
        let continuationPrompt = """
        请从你上一条 assistant 回复的最后一个字符之后继续输出。
        不要重复已经输出过的任何标题、段落、表格行、代码块或最后一句话。
        不要重写开头，不要解释原因，直接续写未完成内容。
        保持答案完整，但只完成原本回答范围内的内容；不要新开额外主题、附录、延伸讨论或无关章节。
        如果主体内容已经基本完整，请自然收束，补齐必要结论即可，不要为了继续而继续扩展。
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
        let conversationID = viewModel.currentConversationID
        guard let assistantID = activeAssistantIDByConversationID[conversationID] else { return }
        finishGeneration(
            conversationID: conversationID,
            assistantID: assistantID,
            flushPending: true,
            cancelTask: true
        )
        viewModel.setStatus(for: assistantID, status: .canceled)
        streamingLayoutStates.removeValue(forKey: assistantID)
        updateMessageUI(id: assistantID, shouldPinToBottom: false)
        viewModel.save()
    }

    func continueGeneration(for assistantID: UUID) {
        let conversationID = viewModel.currentConversationID
        guard !isConversationStreaming(conversationID),
              viewModel.message(id: assistantID)?.status == .needsContinuation
        else {
            return
        }

        let request = makeContinuationRequest(conversationID: conversationID)

        registerActiveGeneration(conversationID: conversationID, assistantID: assistantID)
        viewModel.setStatus(for: assistantID, status: .streaming)
        updateMessageUIIfVisible(
            id: assistantID,
            shouldPinToBottom: shouldAutoPinToBottomDuringGeneration()
        )
        updateSendButtonState()
        prepareContinuationPrefixFilter(for: assistantID)
        startAssistantStream(
            request: request,
            conversationID: conversationID,
            assistantID: assistantID
        )
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
        _ = viewModel.startNewConversation()
        reloadConversationMessages(scrollToBottom: true)
        updateConversationTitle()
        inputTextView.text = ""
        adjustInputHeightIfNeeded()
        updateSendButtonState()
    }

    private func switchConversation(to id: UUID) {
        guard viewModel.selectConversation(id: id) else { return }
        reloadConversationMessages(scrollToBottom: true)
        updateConversationTitle()
        updateSendButtonState()
    }

    @discardableResult
    private func deleteConversation(id: UUID) -> [ConversationSummary] {
        cancelGenerationIfNeeded(for: id, flushPending: false)
        guard viewModel.deleteConversation(id: id) else {
            return viewModel.conversationSummaries()
        }

        reloadConversationMessages(scrollToBottom: true)
        updateConversationTitle()
        updateSendButtonState()
        return viewModel.conversationSummaries()
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
        if isConversationStreaming(viewModel.currentConversationID) {
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
            },
            onDeleteConversation: { [weak self] conversationID in
                self?.deleteConversation(id: conversationID) ?? []
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
