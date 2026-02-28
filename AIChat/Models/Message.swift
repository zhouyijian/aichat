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

nonisolated enum Role: Hashable, Sendable {
    case user
    case assistant
    case system
}

nonisolated struct Message: Hashable, Sendable {
    
    let id: UUID
    let role: Role
    var content: String
    let createdAt: Date
    var status: Status
    
    init(
        id: UUID = UUID(),
        role: Role,
        content: String,
        createdAt: Date = Date(),
        status: Status = .normal
    ) {
        self.id = id
        self.role = role
        self.content = content
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
     nonisolated enum Status: Hashable, Sendable {
        case normal
        case streaming
        case failed(String)
    }
}
