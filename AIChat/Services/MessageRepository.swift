import Foundation

protocol ConversationRepository {
    func loadConversations() -> [Conversation]
    func saveConversations(_ conversations: [Conversation])
}

struct LocalConversationRepository: ConversationRepository {
    private let defaults: UserDefaults
    private let key: String
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(
        defaults: UserDefaults = .standard,
        key: String = "ai-chat.conversations.v2.blocks"
    ) {
        self.defaults = defaults
        self.key = key
    }

    func loadConversations() -> [Conversation] {
        guard let data = defaults.data(forKey: key),
              let conversations = try? decoder.decode([Conversation].self, from: data) else {
            return [Conversation()]
        }

        let conversationsWithMessages = conversations.filter { !$0.messages.isEmpty }
        if conversationsWithMessages.isEmpty {
            return [Conversation()]
        }
        return conversationsWithMessages.sorted { $0.updatedAt > $1.updatedAt }
    }

    func saveConversations(_ conversations: [Conversation]) {
        let conversationsWithMessages = conversations.filter { !$0.messages.isEmpty }
        guard let data = try? encoder.encode(conversationsWithMessages) else { return }
        defaults.set(data, forKey: key)
    }
}
