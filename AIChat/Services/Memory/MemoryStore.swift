import Foundation

nonisolated struct MemoryRecord: Hashable, Sendable, Codable {
    enum Kind: String, Hashable, Sendable, Codable {
        case preference
        case toolUsage
        case userFact
    }

    let id: UUID
    let kind: Kind
    var content: String
    var confidence: Double
    var createdAt: Date
    var updatedAt: Date
}

protocol MemoryStore {
    func load() -> [MemoryRecord]
    func save(_ records: [MemoryRecord])
}

struct LocalMemoryStore: MemoryStore {
    private let defaults: UserDefaults
    private let key: String
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(defaults: UserDefaults = .standard, key: String = "ai-chat.memories.v1") {
        self.defaults = defaults
        self.key = key
    }

    func load() -> [MemoryRecord] {
        guard let data = defaults.data(forKey: key),
              let records = try? decoder.decode([MemoryRecord].self, from: data) else {
            return []
        }
        return records.sorted { $0.updatedAt > $1.updatedAt }
    }

    func save(_ records: [MemoryRecord]) {
        let trimmed = Array(records.sorted { $0.updatedAt > $1.updatedAt }.prefix(80))
        guard let data = try? encoder.encode(trimmed) else { return }
        defaults.set(data, forKey: key)
    }
}

