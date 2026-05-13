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

    func testSetToolResultPersistsStructuredDataAndImageBlock() {
        let repository = InMemoryConversationRepository(conversations: [Conversation()])
        let viewModel = ChatViewModel(repository: repository)
        let assistant = Message(role: .assistant, content: "", status: .pending)
        viewModel.appendMessage(assistant, persist: false)

        let result = ToolExecutionResult(
            toolName: "generate_image",
            ok: true,
            displayText: "已生成 1 张图片",
            blocks: [
                MessageBlock(kind: .markdown, text: "已生成 1 张图片："),
                MessageBlock(kind: .image(url: "https://example.com/cat.png", alt: "猫"), text: "猫")
            ],
            structuredData: .object([
                "image_urls": .array([.string("https://example.com/cat.png")]),
                "prompt": .string("猫")
            ])
        )

        viewModel.setToolResult(for: assistant.id, result: result)

        let updated = viewModel.message(id: assistant.id)
        XCTAssertEqual(updated?.status, .success)
        XCTAssertEqual(updated?.toolResult?.toolName, "generate_image")
        XCTAssertEqual(updated?.toolResult?.structuredData["prompt"]?.stringValue, "猫")
        XCTAssertEqual(updated?.blocks.count, 2)
        XCTAssertEqual(viewModel.chatItems.filter { $0.messageID == assistant.id }.count, 2)
        XCTAssertFalse(repository.savedConversations.isEmpty)
    }

    func testNewConversationDoesNotPersistOrAppearInSummariesUntilMessageIsSent() {
        let existing = Conversation(title: "已有对话", messages: [Message(role: .user, content: "你好")])
        let repository = InMemoryConversationRepository(conversations: [existing])
        let viewModel = ChatViewModel(repository: repository)

        viewModel.startNewConversation()

        XCTAssertTrue(viewModel.messages.isEmpty)
        XCTAssertEqual(viewModel.conversationSummaries().map(\.id), [existing.id])
        XCTAssertTrue(repository.savedConversations.isEmpty)

        let message = Message(role: .user, content: "新问题")
        viewModel.appendMessage(message)

        XCTAssertEqual(viewModel.conversationSummaries().first?.title, "新问题")
        XCTAssertEqual(repository.savedConversations.last?.count, 2)
    }

    func testSaveFiltersEmptyDraftConversations() {
        let existing = Conversation(title: "已有对话", messages: [Message(role: .user, content: "你好")])
        let repository = InMemoryConversationRepository(conversations: [existing])
        let viewModel = ChatViewModel(repository: repository)

        viewModel.startNewConversation()
        viewModel.save()

        XCTAssertEqual(repository.savedConversations.last?.map(\.id), [existing.id])
    }

    func testDeletingCurrentConversationSelectsRemainingConversation() {
        let first = Conversation(title: "第一条", updatedAt: Date().addingTimeInterval(1), messages: [
            Message(role: .user, content: "第一条")
        ])
        let second = Conversation(title: "第二条", updatedAt: Date(), messages: [
            Message(role: .user, content: "第二条")
        ])
        let repository = InMemoryConversationRepository(conversations: [first, second])
        let viewModel = ChatViewModel(repository: repository)

        XCTAssertTrue(viewModel.deleteConversation(id: first.id))

        XCTAssertEqual(viewModel.conversationSummaries().map(\.id), [second.id])
        XCTAssertEqual(viewModel.messages.map(\.contentText), ["第二条"])
        XCTAssertEqual(repository.savedConversations.last?.map(\.id), [second.id])
    }

    func testUpdatesStreamingMessageAfterSwitchingAwayFromConversation() {
        let assistant = Message(role: .assistant, content: "开头", status: .streaming)
        let first = Conversation(title: "第一条", updatedAt: Date().addingTimeInterval(1), messages: [
            Message(role: .user, content: "第一条"),
            assistant
        ])
        let second = Conversation(title: "第二条", updatedAt: Date(), messages: [
            Message(role: .user, content: "第二条")
        ])
        let repository = InMemoryConversationRepository(conversations: [first, second])
        let viewModel = ChatViewModel(repository: repository)

        XCTAssertTrue(viewModel.selectConversation(id: second.id))
        viewModel.appendStreamDelta(to: assistant.id, contentDelta: "继续", reasoningDelta: nil)
        viewModel.setStatus(for: assistant.id, status: .success)

        XCTAssertEqual(viewModel.messages.map(\.contentText), ["第二条"])
        XCTAssertEqual(viewModel.message(id: assistant.id)?.contentText, "开头继续")
        XCTAssertEqual(viewModel.message(id: assistant.id)?.status, .success)
        XCTAssertEqual(repository.savedConversations.last?.first { $0.id == first.id }?.messages.last?.contentText, "开头继续")
    }

    func testChatProviderRequestCanBeBuiltForNonCurrentConversation() {
        let first = Conversation(title: "第一条", updatedAt: Date().addingTimeInterval(1), messages: [
            Message(role: .user, content: "第一条"),
            Message(role: .assistant, content: "第一条回复")
        ])
        let second = Conversation(title: "第二条", updatedAt: Date(), messages: [
            Message(role: .user, content: "第二条")
        ])
        let repository = InMemoryConversationRepository(conversations: [first, second])
        let viewModel = ChatViewModel(repository: repository)

        XCTAssertTrue(viewModel.selectConversation(id: second.id))
        let request = viewModel.chatProviderRequest(systemPrompt: "system", conversationID: first.id)

        XCTAssertEqual(request.messages.map(\.content), ["第一条", "第一条回复"])
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
