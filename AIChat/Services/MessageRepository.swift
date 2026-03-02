import Foundation

protocol MessageRepository {
    func loadInitialMessages() -> [Message]
}

struct MockMessageRepository: MessageRepository {
    func loadInitialMessages() -> [Message] {
        [
            Message(role: .user, content: "Hello"),
            Message(role: .assistant, content: "Hi! This is a static chat cell."),
            Message(role: .user, content: "Hello2"),
            Message(role: .user, content: "Hello3"),
            Message(role: .assistant, content: "Hi! This is a static chat cell2.Hi! This is a static chat cell2.Hi! This is a static chat cell2.Hi! This is a static chat cell2.Hi! This is a static chat cell2.Hi! This is a static chat cell2."),
            Message(role: .user, content: "Hello4"),
            Message(role: .user, content: "Hello5"),
            Message(role: .assistant, content: "Hi! This is a static chat cell3."),
            Message(role: .user, content: "Hello"),
            Message(role: .assistant, content: "Hi! This is a static chat cell4.")
        ]
    }
}
