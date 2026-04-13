import UIKit

struct AssistantSegments {
    let responseText: String
    let foldedResponseText: String?
    let reasoningText: String?

    var isResponseFoldable: Bool {
        foldedResponseText != nil
    }

    func displayedResponseText(isExpanded: Bool) -> String {
        guard !isExpanded, let foldedResponseText else { return responseText }
        return foldedResponseText
    }
}

private struct AssistantSegmentsCacheEntry {
    let rawContent: String
    let rawReasoningContent: String?
    let segments: AssistantSegments
}

final class ChatViewModel {

    // MARK: - State
    private(set) var conversations: [Conversation]
    private(set) var currentConversationID: UUID
    private let repository: ConversationRepository
    private let heightCache: MessageHeightCache
    private var assistantSegmentsCache: [UUID: AssistantSegmentsCacheEntry] = [:]
    
    var messages: [Message] {
        currentConversation?.messages ?? []
    }
    
    var currentConversationTitle: String {
        currentConversation?.title ?? "新对话"
    }

    // MARK: - Lifecycle
    init(repository: ConversationRepository, heightCache: MessageHeightCache = MessageHeightCache()) {
        self.repository = repository
        self.conversations = repository.loadConversations().sorted(by: { $0.updatedAt > $1.updatedAt })
        if conversations.isEmpty {
            conversations = [Conversation()]
        }
        self.currentConversationID = conversations[0].id
        self.heightCache = heightCache
    }
}

// MARK: - Message Query
extension ChatViewModel {
    func message(at indexPath: IndexPath) -> Message {
        messages[indexPath.item]
    }

    func message(id: UUID) -> Message? {
        messages.first(where: { $0.id == id })
    }
}

// MARK: - Conversation Operations
extension ChatViewModel {
    func conversationSummaries() -> [ConversationSummary] {
        conversations
            .sorted(by: { $0.updatedAt > $1.updatedAt })
            .map { conversation in
                ConversationSummary(
                    id: conversation.id,
                    title: conversation.title,
                    preview: makePreview(for: conversation),
                    updatedAt: conversation.updatedAt,
                    isSelected: conversation.id == currentConversationID
                )
            }
    }
    
    @discardableResult
    func startNewConversation() -> Conversation {
        let conversation = Conversation()
        conversations.insert(conversation, at: 0)
        currentConversationID = conversation.id
        invalidateAllHeights()
        pruneAssistantSegmentsCache()
        save()
        return conversation
    }
    
    @discardableResult
    func selectConversation(id: UUID) -> Bool {
        guard conversations.contains(where: { $0.id == id }) else { return false }
        currentConversationID = id
        invalidateAllHeights()
        pruneAssistantSegmentsCache()
        return true
    }
    
    func chatHistoryForRequest(systemPrompt: String) -> [[String: String]] {
        var result: [[String: String]] = [
            ["role": "system", "content": systemPrompt]
        ]
        
        for message in messages {
            guard let role = apiRole(from: message.role),
                  let content = normalizedHistoryContent(from: message),
                  !content.isEmpty else { continue }
            result.append(["role": role, "content": content])
        }
        return result
    }
    
    func save() {
        repository.saveConversations(conversations)
    }
    
    func assistantSegments(for message: Message) -> AssistantSegments {
        if let cached = assistantSegmentsCache[message.id],
           cached.rawContent == message.content,
           cached.rawReasoningContent == message.reasoningContent {
            return cached.segments
        }

        let segments = buildAssistantSegments(from: message)
        assistantSegmentsCache[message.id] = AssistantSegmentsCacheEntry(
            rawContent: message.content,
            rawReasoningContent: message.reasoningContent,
            segments: segments
        )
        return segments
    }
}

// MARK: - Message Mutation
extension ChatViewModel {
    func appendMessage(_ message: Message, persist: Bool = true) {
        mutateCurrentConversation(persist: persist, touchUpdatedAt: persist) { conversation in
            conversation.messages.append(message)
            if message.role == .user, conversation.title == "新对话" {
                conversation.title = makeTitle(from: message.content)
            }
        }
        refreshAssistantSegmentsIfNeeded(for: message)
    }

    /// Applies in-place mutation to an existing message by id.
    /// - Returns: true if target message exists and is updated.
    @discardableResult
    func updateMessage(
        id: UUID,
        persist: Bool = false,
        affectsAssistantSegments: Bool = false,
        mutate: (inout Message) -> Void
    ) -> Bool {
        var updatedMessage: Message?

        mutateCurrentConversation(persist: persist, touchUpdatedAt: persist) { conversation in
            guard let idx = conversation.messages.firstIndex(where: { $0.id == id }) else { return }
            mutate(&conversation.messages[idx])
            updatedMessage = conversation.messages[idx]
        }

        guard let updatedMessage else { return false }

        if affectsAssistantSegments {
            refreshAssistantSegmentsIfNeeded(for: updatedMessage)
        }

        return true
    }
    
    func appendContent(to id: UUID, delta: String, persist: Bool = false) {
        _ = updateMessage(id: id, persist: persist, affectsAssistantSegments: true) { message in
            message.content += delta
            message.advanceLayoutVersion()
        }
    }

    func appendReasoning(to id: UUID, delta: String, persist: Bool = false) {
        _ = updateMessage(id: id, persist: persist, affectsAssistantSegments: true) { message in
            let current = message.reasoningContent ?? ""
            message.reasoningContent = current + delta
            message.advanceLayoutVersion()
        }
    }
    
    func setContent(for id: UUID, text: String, persist: Bool = true) {
        _ = updateMessage(id: id, persist: persist, affectsAssistantSegments: true) { message in
            message.content = text
            message.advanceLayoutVersion()
        }
    }
    
    @discardableResult
    func toggleReasoning(for id: UUID) -> Bool {
        updateMessage(id: id, persist: false) { message in
            message.isReasoningExpanded.toggle()
            message.advanceLayoutVersion()
        }
    }

    @discardableResult
    func toggleContentExpansion(for id: UUID) -> Bool {
        updateMessage(id: id, persist: false) { message in
            message.isContentExpanded.toggle()
            message.advanceLayoutVersion()
        }
    }

    func setStatus(for id: UUID, status: Message.Status, persist: Bool = true) {
        _ = updateMessage(id: id, persist: persist) { message in
            message.status = status
        }
    }
}

// MARK: - Height Cache Operations
extension ChatViewModel {
    func cachedHeight(for message: Message, width: CGFloat, displayScale: CGFloat) -> CGFloat? {
        heightCache.cachedHeight(
            for: message.id,
            width: width,
            displayScale: displayScale,
            layoutVersion: message.layoutVersion
        )
    }

    func cacheHeight(_ height: CGFloat, for message: Message, width: CGFloat, displayScale: CGFloat) {
        heightCache.cacheHeight(
            height,
            for: message.id,
            width: width,
            displayScale: displayScale,
            layoutVersion: message.layoutVersion
        )
    }

    func invalidateHeight(for message: Message, width: CGFloat, displayScale: CGFloat) {
        heightCache.invalidateHeight(
            for: message.id,
            width: width,
            displayScale: displayScale,
            layoutVersion: message.layoutVersion
        )
    }

    func invalidateAllHeights() {
        heightCache.invalidateAll()
    }

    func pruneHeightCache() {
        let validIDs = Set(messages.map(\.id))
        heightCache.prune(validMessageIDs: validIDs)
    }
    
    func pruneAssistantSegmentsCache() {
        let validIDs = Set(messages.map(\.id))
        assistantSegmentsCache = assistantSegmentsCache.filter { validIDs.contains($0.key) }
    }
}

// MARK: - Helpers
private extension ChatViewModel {
    static let responseCollapseCharacterLimit = 1_200
    static let responseCollapseLineLimit = 12

    var currentConversation: Conversation? {
        conversations.first(where: { $0.id == currentConversationID })
    }
    
    func makeTitle(from content: String) -> String {
        let trimmed = content
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        guard !trimmed.isEmpty else { return "新对话" }
        return String(trimmed.prefix(20))
    }
    
    func makePreview(for conversation: Conversation) -> String {
        for message in conversation.messages.reversed() {
            guard let normalized = normalizedHistoryContent(from: message), !normalized.isEmpty else { continue }
            return normalized.replacingOccurrences(of: "\n", with: " ")
        }
        return "还没有消息"
    }
    
    func apiRole(from role: Role) -> String? {
        switch role {
        case .user:
            return "user"
        case .assistant:
            return "assistant"
        case .system:
            return nil
        }
    }
    
    func normalizedHistoryContent(from message: Message) -> String? {
        if !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return message.content
                .removingThinkTagContent()
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        
        if let reasoning = message.reasoningContent?.trimmingCharacters(in: .whitespacesAndNewlines),
           !reasoning.isEmpty {
            return reasoning
        }
        return nil
    }
    
    func mutateCurrentConversation(
        persist: Bool,
        touchUpdatedAt: Bool = true,
        mutate: (inout Conversation) -> Void
    ) {
        guard let idx = conversations.firstIndex(where: { $0.id == currentConversationID }) else { return }
        mutate(&conversations[idx])
        if touchUpdatedAt {
            conversations[idx].updatedAt = Date()
            conversations.sort(by: { $0.updatedAt > $1.updatedAt })
        }
        if persist {
            save()
        }
    }
}

private extension String {
    func removingThinkTagContent() -> String {
        replacingOccurrences(
            of: "<think>[\\s\\S]*?</think>",
            with: "",
            options: .regularExpression
        )
    }
}

private extension ChatViewModel {
    func refreshAssistantSegmentsIfNeeded(for message: Message) {
        guard message.role == .assistant else {
            assistantSegmentsCache.removeValue(forKey: message.id)
            return
        }

        let segments = buildAssistantSegments(from: message)
        assistantSegmentsCache[message.id] = AssistantSegmentsCacheEntry(
            rawContent: message.content,
            rawReasoningContent: message.reasoningContent,
            segments: segments
        )
    }
    
    func buildAssistantSegments(from message: Message) -> AssistantSegments {
        let explicitReasoning = message.reasoningContent?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasExplicitReasoning = !(explicitReasoning?.isEmpty ?? true)

        if hasExplicitReasoning {
            let response = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
            return AssistantSegments(
                responseText: response.isEmpty ? "..." : response,
                foldedResponseText: makeFoldedResponseTextIfNeeded(from: response),
                reasoningText: explicitReasoning
            )
        }

        let content = message.content
        if let startRange = content.range(of: "<think>") {
            if let endRange = content.range(of: "</think>"),
               startRange.lowerBound < endRange.lowerBound {
                let reasoning = String(content[startRange.upperBound..<endRange.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let response = content.replacingCharacters(
                    in: startRange.lowerBound..<endRange.upperBound,
                    with: ""
                )
                .trimmingCharacters(in: .whitespacesAndNewlines)

                return AssistantSegments(
                    responseText: response.isEmpty ? "..." : response,
                    foldedResponseText: makeFoldedResponseTextIfNeeded(from: response),
                    reasoningText: reasoning.isEmpty ? nil : reasoning
                )
            } else {
                let reasoning = String(content[startRange.upperBound...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let prefix = String(content[..<startRange.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                return AssistantSegments(
                    responseText: prefix.isEmpty ? "..." : prefix,
                    foldedResponseText: makeFoldedResponseTextIfNeeded(from: prefix),
                    reasoningText: reasoning.isEmpty ? nil : reasoning
                )
            }
        }

        let cleaned = content.trimmingCharacters(in: .whitespacesAndNewlines)
        return AssistantSegments(
            responseText: cleaned.isEmpty ? "..." : cleaned,
            foldedResponseText: makeFoldedResponseTextIfNeeded(from: cleaned),
            reasoningText: nil
        )
    }

    func makeFoldedResponseTextIfNeeded(from responseText: String) -> String? {
        let normalized = responseText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }

        let lineCount = normalized.reduce(into: 1) { count, character in
            if character == "\n" {
                count += 1
            }
        }

        let shouldFold =
            normalized.count > Self.responseCollapseCharacterLimit ||
            lineCount > Self.responseCollapseLineLimit

        guard shouldFold else { return nil }

        let characterLimitedIndex = normalized.index(
            normalized.startIndex,
            offsetBy: Self.responseCollapseCharacterLimit,
            limitedBy: normalized.endIndex
        ) ?? normalized.endIndex

        let lineLimitedIndex = indexAfterLineLimit(
            in: normalized,
            lineLimit: Self.responseCollapseLineLimit
        ) ?? normalized.endIndex

        let previewEnd = min(characterLimitedIndex, lineLimitedIndex)
        let preview = String(normalized[..<previewEnd]).trimmingCharacters(in: .whitespacesAndNewlines)

        guard !preview.isEmpty, preview.count < normalized.count else { return nil }
        return "\(preview)\n\n..."
    }

    func indexAfterLineLimit(in text: String, lineLimit: Int) -> String.Index? {
        guard lineLimit > 0 else { return text.startIndex }

        var lineBreakCount = 0
        for index in text.indices {
            if text[index] == "\n" {
                lineBreakCount += 1
                if lineBreakCount == lineLimit {
                    return text.index(after: index)
                }
            }
        }
        return nil
    }
}
