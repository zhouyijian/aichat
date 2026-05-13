import Foundation

nonisolated struct ToolDefinition: Hashable, Sendable, Encodable {
    let name: String
    let description: String
    let inputSchema: JSONValue

    private enum CodingKeys: String, CodingKey {
        case name
        case description
        case inputSchema = "input_schema"
    }
}

nonisolated struct ToolCall: Hashable, Sendable {
    let id: String
    let name: String
    let input: JSONValue
}

nonisolated struct ToolExecutionResult: Hashable, Sendable {
    let toolName: String
    let ok: Bool
    let displayText: String
    let blocks: [MessageBlock]
    let structuredData: JSONValue
}

enum ToolExecutionError: LocalizedError {
    case unknownTool(String)
    case invalidArguments(String)
    case permissionDenied(String)
    case executionFailed(String)

    var errorDescription: String? {
        switch self {
        case .unknownTool(let name):
            return "未知工具：\(name)"
        case .invalidArguments(let reason):
            return "工具参数无效：\(reason)"
        case .permissionDenied(let reason):
            return "缺少权限：\(reason)"
        case .executionFailed(let reason):
            return reason
        }
    }
}

protocol ChatTool: Sendable {
    var name: String { get }
    var definition: ToolDefinition { get }
    func execute(input: JSONValue) async throws -> ToolExecutionResult
}

