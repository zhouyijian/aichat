//
//  Message.swift
//  AIChat
//
//  Created by 周一见 on 2026/2/28.
//

import Foundation

nonisolated enum Section: Hashable, Sendable {
    case main
}

nonisolated enum Role: String, Hashable, Sendable, Codable {
    case user
    case assistant
    case system
}

nonisolated struct Message: Hashable, Sendable, Codable {
    
    let id: UUID
    let role: Role
    var content: String
    var reasoningContent: String?
    var isReasoningExpanded: Bool
    let createdAt: Date
    var status: Status
    
    init(
        id: UUID = UUID(),
        role: Role,
        content: String,
        reasoningContent: String? = nil,
        isReasoningExpanded: Bool = false,
        createdAt: Date = Date(),
        status: Status = .success
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.reasoningContent = reasoningContent
        self.isReasoningExpanded = isReasoningExpanded
        self.createdAt = createdAt
        self.status = status
    }
    
    // 只用 id 参与 Hash
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
    
    // Equatable 也只比较 id
    static func == (lhs: Message, rhs: Message) -> Bool {
        return lhs.id == rhs.id
    }
}

extension Message {
    nonisolated enum Status: Hashable, Sendable, Codable {
        case pending
        case canceled
        case success
        case streaming
        case failed(String)

        private enum CodingKeys: String, CodingKey {
            case type
            case value
        }

        private enum Kind: String, Codable {
            case pending
            case canceled
            case success
            case streaming
            case failed
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let type = try container.decode(Kind.self, forKey: .type)
            switch type {
            case .pending:
                self = .pending
            case .canceled:
                self = .canceled
            case .success:
                self = .success
            case .streaming:
                self = .streaming
            case .failed:
                let value = try container.decode(String.self, forKey: .value)
                self = .failed(value)
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .pending:
                try container.encode(Kind.pending, forKey: .type)
            case .canceled:
                try container.encode(Kind.canceled, forKey: .type)
            case .success:
                try container.encode(Kind.success, forKey: .type)
            case .streaming:
                try container.encode(Kind.streaming, forKey: .type)
            case .failed(let value):
                try container.encode(Kind.failed, forKey: .type)
                try container.encode(value, forKey: .value)
            }
        }
    }
}

nonisolated struct Conversation: Hashable, Sendable, Codable {
    let id: UUID
    var title: String
    let createdAt: Date
    var updatedAt: Date
    var messages: [Message]

    init(
        id: UUID = UUID(),
        title: String = "新对话",
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        messages: [Message] = []
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.messages = messages
    }
}

nonisolated struct ConversationSummary: Hashable, Sendable {
    let id: UUID
    let title: String
    let preview: String
    let updatedAt: Date
    let isSelected: Bool
}
