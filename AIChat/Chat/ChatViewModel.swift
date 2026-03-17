import UIKit

final class ChatViewModel {

    // MARK: - State
    private(set) var conversations: [Conversation]
    private(set) var currentConversationID: UUID
    private let repository: ConversationRepository
    private let heightCache: MessageHeightCache
    
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
        save()
        return conversation
    }
    
    @discardableResult
    func selectConversation(id: UUID) -> Bool {
        guard conversations.contains(where: { $0.id == id }) else { return false }
        currentConversationID = id
        invalidateAllHeights()
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
    }

    /// Applies in-place mutation to an existing message by id.
    /// - Returns: true if target message exists and is updated.
    @discardableResult
    func updateMessage(id: UUID, persist: Bool = false, mutate: (inout Message) -> Void) -> Bool {
        var updated = false
        mutateCurrentConversation(persist: persist, touchUpdatedAt: persist) { conversation in
            guard let idx = conversation.messages.firstIndex(where: { $0.id == id }) else { return }
            mutate(&conversation.messages[idx])
            updated = true
        }
        return updated
    }
    
    func appendContent(to id: UUID, delta: String, persist: Bool = false) {
        _ = updateMessage(id: id, persist: persist) { message in
            message.content += delta
        }
    }

    func appendReasoning(to id: UUID, delta: String, persist: Bool = false) {
        _ = updateMessage(id: id, persist: persist) { message in
            let current = message.reasoningContent ?? ""
            message.reasoningContent = current + delta
        }
    }
    
    func setContent(for id: UUID, text: String, persist: Bool = true) {
        _ = updateMessage(id: id, persist: persist) { message in
            message.content = text
        }
    }
    
    @discardableResult
    func toggleReasoning(for id: UUID) -> Bool {
        updateMessage(id: id, persist: false) { message in
            message.isReasoningExpanded.toggle()
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
    func cachedHeight(for messageID: UUID, width: CGFloat, displayScale: CGFloat) -> CGFloat? {
        heightCache.cachedHeight(for: messageID, width: width, displayScale: displayScale)
    }

    func cacheHeight(_ height: CGFloat, for messageID: UUID, width: CGFloat, displayScale: CGFloat) {
        heightCache.cacheHeight(height, for: messageID, width: width, displayScale: displayScale)
    }

    func invalidateHeight(for messageID: UUID, width: CGFloat, displayScale: CGFloat) {
        heightCache.invalidateHeight(for: messageID, width: width, displayScale: displayScale)
    }

    func invalidateAllHeights() {
        heightCache.invalidateAll()
    }

    func pruneHeightCache() {
        let validIDs = Set(messages.map(\.id))
        heightCache.prune(validMessageIDs: validIDs)
    }
}

// MARK: - Helpers
private extension ChatViewModel {
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
