import UIKit

final class ChatViewModel {

    // MARK: - State
    private(set) var messages: [Message]
    private let heightCache: MessageHeightCache

    // MARK: - Lifecycle
    init(repository: MessageRepository, heightCache: MessageHeightCache = MessageHeightCache()) {
        self.messages = repository.loadInitialMessages()
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

// MARK: - Message Mutation
extension ChatViewModel {
    func appendMessage(_ message: Message) {
        messages.append(message)
    }

    /// Applies in-place mutation to an existing message by id.
    /// - Returns: true if target message exists and is updated.
    func updateMessage(id: UUID, mutate: (inout Message) -> Void) -> Bool {
        guard let idx = messages.firstIndex(where: { $0.id == id }) else { return false }
        mutate(&messages[idx])
        return true
    }
    
    func appendContent(to id: UUID, delta: String) {
        guard let idx = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[idx].content += delta
    }

    func setContent(for id: UUID, text: String) {
        guard let idx = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[idx].content = text
    }

    /// 可选：流式开始/结束时更新状态（面试加分）
    func setStatus(for id: UUID, status: Message.Status) {
        guard let idx = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[idx].status = status
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
