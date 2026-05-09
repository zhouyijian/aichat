import XCTest
@testable import AIChat

@MainActor
final class ChatViewModelContinuationTests: XCTestCase {

    func testIncrementMaxTokenHitCountIsPerMessageAndDoesNotPersistImplicitly() {
        let repository = InMemoryConversationRepository(conversations: [Conversation()])
        let viewModel = ChatViewModel(repository: repository)
        let assistant = Message(role: .assistant, content: "未完成回复", status: .streaming)
        viewModel.appendMessage(assistant, persist: false)

        XCTAssertEqual(viewModel.incrementMaxTokenHitCount(for: assistant.id), 1)
        XCTAssertEqual(viewModel.incrementMaxTokenHitCount(for: assistant.id), 2)
        XCTAssertEqual(viewModel.message(id: assistant.id)?.maxTokenHitCount, 2)
        XCTAssertTrue(repository.savedConversations.isEmpty)
    }

    func testLatestContinuableAssistantIDReturnsMostRecentNeedsContinuationMessage() {
        let repository = InMemoryConversationRepository(conversations: [Conversation()])
        let viewModel = ChatViewModel(repository: repository)
        let first = Message(role: .assistant, content: "第一段", status: .needsContinuation)
        let second = Message(role: .assistant, content: "第二段", status: .needsContinuation)

        viewModel.appendMessage(first, persist: false)
        viewModel.appendMessage(second, persist: false)

        XCTAssertEqual(viewModel.latestContinuableAssistantID(), second.id)
    }

    func testLatestContinuableAssistantIDStopsAtNewerUserMessage() {
        let repository = InMemoryConversationRepository(conversations: [Conversation()])
        let viewModel = ChatViewModel(repository: repository)
        let assistant = Message(role: .assistant, content: "需要继续", status: .needsContinuation)
        let user = Message(role: .user, content: "新问题")

        viewModel.appendMessage(assistant, persist: false)
        viewModel.appendMessage(user, persist: false)

        XCTAssertNil(viewModel.latestContinuableAssistantID())
    }

    func testAppendingBufferedDeltaDoesNotOverrideTerminalStatus() {
        let repository = InMemoryConversationRepository(conversations: [Conversation()])
        let viewModel = ChatViewModel(repository: repository)
        let assistant = Message(role: .assistant, content: "已输出", status: .canceled)
        viewModel.appendMessage(assistant, persist: false)

        viewModel.appendStreamDelta(to: assistant.id, contentDelta: "尾部缓存", reasoningDelta: nil)

        XCTAssertEqual(viewModel.message(id: assistant.id)?.status, .canceled)
        XCTAssertEqual(viewModel.message(id: assistant.id)?.contentText, "已输出\n\n尾部缓存")
    }
}

private final class InMemoryConversationRepository: ConversationRepository {
    private let loadedConversations: [Conversation]
    private(set) var savedConversations: [[Conversation]] = []

    init(conversations: [Conversation]) {
        self.loadedConversations = conversations
    }

    func loadConversations() -> [Conversation] {
        loadedConversations
    }

    func saveConversations(_ conversations: [Conversation]) {
        savedConversations.append(conversations)
    }
}
