import Foundation

struct ToolPlanningResult: Sendable {
    let toolCalls: [ToolCall]
    let assistantText: String

    var shouldExecuteTool: Bool {
        !toolCalls.isEmpty
    }
}

final class ToolPlannerClient {
    private let configProvider: () throws -> StreamingServiceConfig
    private let session: URLSession

    init(
        configProvider: @escaping () throws -> StreamingServiceConfig = StreamingServiceConfig.loadLocal,
        session: URLSession = .shared
    ) {
        self.configProvider = configProvider
        self.session = session
    }

    func plan(
        request: ChatProviderRequest,
        tools: [ToolDefinition]
    ) async throws -> ToolPlanningResult {
        guard !tools.isEmpty else {
            return ToolPlanningResult(toolCalls: [], assistantText: "")
        }

        let config = try configProvider()
        let body = ToolPlannerRequest(
            model: config.model,
            maxTokens: config.toolPlannerMaxTokens,
            system: plannerSystemPrompt(base: request.systemPrompt),
            stream: false,
            messages: request.messages.map { message in
                ToolPlannerMessage(
                    role: message.role.rawValue,
                    content: [
                        ToolPlannerContentBlock(type: "text", text: message.content)
                    ]
                )
            },
            tools: tools,
            temperature: 0.1
        )

        var urlRequest = URLRequest(url: config.endpointURL)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await session.data(for: urlRequest)
        try Self.validate(response: response, data: data)

        let decoded = try JSONDecoder().decode(ToolPlannerResponse.self, from: data)
        let calls = decoded.content.compactMap { block -> ToolCall? in
            guard block.type == "tool_use",
                  let name = block.name,
                  let input = block.input
            else { return nil }

            return ToolCall(
                id: block.id ?? UUID().uuidString,
                name: name,
                input: input
            )
        }

        let assistantText = decoded.content
            .compactMap(\.text)
            .joined(separator: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return ToolPlanningResult(toolCalls: calls, assistantText: assistantText)
    }

    private func plannerSystemPrompt(base: String) -> String {
        let now = DateFormatter.toolDisplay.string(from: Date())
        return """
        \(base)

        你现在处于工具规划阶段。只在用户明确需要外部动作时调用工具：
        - 画图、生成图片、设计海报、头像、logo、壁纸、表情包时调用 generate_image。
          generate_image 的 caption 必须是完整中文图片说明，用于展示在图片下方，不要用英文 caption。
          prompt 可以按图像模型需要写得更详细，但除非用户明确要求英文文字，图片画面中不要出现英文单词、英文字母、水印、Logo 或可读英文。
        - 创建待办、提醒事项、到点提醒某件事时调用 create_reminder。
        - 设置闹钟、叫醒我、叫我起床、起床提醒、响铃提醒、明早/早上/下午几点叫醒时调用 create_alarm。
          只要用户意图是“叫醒/起床/响铃”，即使句子里出现“提醒我”，也必须优先调用 create_alarm，不要调用 create_reminder。

        如果用户只是咨询、讨论、让你写文本、解释概念，不要调用工具。
        当前时间：\(now)，时区：Asia/Shanghai。
        工具参数必须完整、结构化；涉及时间时，基于当前时间和时区推断，并输出带时区的 ISO-8601 时间。
        如果时间或动作缺少必要信息，不要调用工具，正常回复一个简短澄清问题。
        """
    }

    private static func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "Tool planner request failed."
            throw ToolExecutionError.executionFailed("工具规划失败（HTTP \(http.statusCode)）：\(message)")
        }
    }
}

private struct ToolPlannerRequest: Encodable {
    let model: String
    let maxTokens: Int
    let system: String
    let stream: Bool
    let messages: [ToolPlannerMessage]
    let tools: [ToolDefinition]
    let temperature: Double

    private enum CodingKeys: String, CodingKey {
        case model
        case maxTokens = "max_tokens"
        case system
        case stream
        case messages
        case tools
        case temperature
    }
}

private struct ToolPlannerMessage: Encodable {
    let role: String
    let content: [ToolPlannerContentBlock]
}

private struct ToolPlannerContentBlock: Encodable {
    let type: String
    let text: String
}

private struct ToolPlannerResponse: Decodable {
    let content: [ToolPlannerResponseBlock]
}

private struct ToolPlannerResponseBlock: Decodable {
    let type: String
    let id: String?
    let name: String?
    let input: JSONValue?
    let text: String?
}
