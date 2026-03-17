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
        key: String = "ai-chat.conversations.v1"
    ) {
        self.defaults = defaults
        self.key = key
    }

    func loadConversations() -> [Conversation] {
        guard let data = defaults.data(forKey: key),
              let conversations = try? decoder.decode([Conversation].self, from: data) else {
            return [Conversation()]
        }

        if conversations.isEmpty {
            return [Conversation()]
        }
        return conversations.sorted { $0.updatedAt > $1.updatedAt }
    }

    func saveConversations(_ conversations: [Conversation]) {
        guard let data = try? encoder.encode(conversations) else { return }
        defaults.set(data, forKey: key)
    }
}
