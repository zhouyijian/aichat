import Foundation

final class ToolRegistry: @unchecked Sendable {
    private let toolsByName: [String: any ChatTool]

    init(tools: [any ChatTool]) {
        self.toolsByName = Dictionary(uniqueKeysWithValues: tools.map { ($0.name, $0) })
    }

    var definitions: [ToolDefinition] {
        toolsByName.values.map(\.definition).sorted { $0.name < $1.name }
    }

    func execute(_ call: ToolCall) async throws -> ToolExecutionResult {
        guard let tool = toolsByName[call.name] else {
            throw ToolExecutionError.unknownTool(call.name)
        }
        return try await tool.execute(input: call.input)
    }
}

extension ToolRegistry {
    static func makeDefault() -> ToolRegistry {
        ToolRegistry(
            tools: [
                GenerateImageTool(),
                CreateReminderTool(),
                CreateAlarmTool()
            ]
        )
    }
}

