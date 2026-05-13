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

nonisolated enum MessageBlockKind: Hashable, Sendable, Codable {
    case markdown
    case code(language: String?)
    case image(url: String, alt: String?)
}

nonisolated struct MessageBlock: Hashable, Sendable, Codable {
    let id: UUID
    var kind: MessageBlockKind
    var text: String
    var isComplete: Bool
    var version: Int

    init(
        id: UUID = UUID(),
        kind: MessageBlockKind,
        text: String,
        isComplete: Bool = true,
        version: Int = 0
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.isComplete = isComplete
        self.version = version
    }

    mutating func append(_ delta: String) {
        text += delta
        version &+= 1
    }

    mutating func replaceText(_ nextText: String, isComplete: Bool? = nil) {
        text = nextText
        if let isComplete {
            self.isComplete = isComplete
        }
        version &+= 1
    }
}

nonisolated struct ThinkRoutingState: Hashable, Sendable, Codable {
    var isInsideThink: Bool
    var pendingText: String

    init(isInsideThink: Bool = false, pendingText: String = "") {
        self.isInsideThink = isInsideThink
        self.pendingText = pendingText
    }
}

nonisolated struct Message: Hashable, Sendable, Codable {

    let id: UUID
    let role: Role
    var blocks: [MessageBlock]
    var reasoningBlocks: [MessageBlock]
    var thinkRoutingState: ThinkRoutingState
    var isReasoningExpanded: Bool
    var layoutVersion: Int
    var maxTokenHitCount: Int?
    var toolResult: ToolResultRecord?
    let createdAt: Date
    var status: Status

    init(
        id: UUID = UUID(),
        role: Role,
        content: String = "",
        blocks: [MessageBlock]? = nil,
        reasoningBlocks: [MessageBlock] = [],
        thinkRoutingState: ThinkRoutingState = ThinkRoutingState(),
        isReasoningExpanded: Bool = false,
        layoutVersion: Int = 0,
        maxTokenHitCount: Int? = nil,
        toolResult: ToolResultRecord? = nil,
        createdAt: Date = Date(),
        status: Status = .success
    ) {
        self.id = id
        self.role = role
        if let blocks {
            self.blocks = blocks
        } else if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, role == .assistant {
            self.blocks = []
        } else {
            self.blocks = [
                MessageBlock(kind: .markdown, text: content, isComplete: status.isTerminal)
            ]
        }
        self.reasoningBlocks = reasoningBlocks
        self.thinkRoutingState = thinkRoutingState
        self.isReasoningExpanded = isReasoningExpanded
        self.layoutVersion = layoutVersion
        self.maxTokenHitCount = maxTokenHitCount
        self.toolResult = toolResult
        self.createdAt = createdAt
        self.status = status
    }

    var contentText: String {
        Message.joinedText(from: blocks)
    }

    var reasoningText: String {
        Message.joinedText(from: reasoningBlocks)
    }

    static func joinedText(from blocks: [MessageBlock]) -> String {
        blocks
            .map { block in
                switch block.kind {
                case .markdown:
                    return block.text
                case .code(let language):
                    let fence = language.map { "```\($0)" } ?? "```"
                    return "\(fence)\n\(block.text)\n```"
                case .image(let url, let alt):
                    return "![\(alt ?? "")](\(url))"
                }
            }
            .joined(separator: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: Message, rhs: Message) -> Bool {
        lhs.id == rhs.id
    }

    mutating func advanceLayoutVersion() {
        layoutVersion &+= 1
    }
}

nonisolated struct ToolResultRecord: Hashable, Sendable, Codable {
    let toolName: String
    let ok: Bool
    let displayText: String
    let structuredData: JSONValue
    let createdAt: Date

    init(
        toolName: String,
        ok: Bool,
        displayText: String,
        structuredData: JSONValue,
        createdAt: Date = Date()
    ) {
        self.toolName = toolName
        self.ok = ok
        self.displayText = displayText
        self.structuredData = structuredData
        self.createdAt = createdAt
    }
}

extension Message {
    nonisolated enum Status: Hashable, Sendable, Codable {
        case pending
        case canceled
        case success
        case streaming
        case failed(String)
        case needsContinuation

        var isTerminal: Bool {
            switch self {
            case .canceled, .success, .failed, .needsContinuation:
                return true
            case .pending, .streaming:
                return false
            }
        }

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
            case needsContinuation
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
            case .needsContinuation:
                self = .needsContinuation
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
            case .needsContinuation:
                try container.encode(Kind.needsContinuation, forKey: .type)
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
