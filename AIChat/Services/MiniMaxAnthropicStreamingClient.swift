//
//  MiniMaxAnthropicStreamingClient.swift
//  AIChat
//
//  Created by 周一见 on 2026/3/3.
//

import Foundation
import LDSwiftEventSource

struct StreamingServiceConfig {
    let apiKey: String
    let endpointURL: URL
    let model: String
    let maxTokens: Int
    let temperature: Double?

    nonisolated static func loadLocal() throws -> StreamingServiceConfig {
        guard let url = Bundle.main.url(forResource: "LocalConfig", withExtension: "plist") else {
            throw StreamingServiceConfigError.missingFile
        }

        let data = try Data(contentsOf: url)
        guard
            let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
            let apiKey = (plist["StreamingAPIKey"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
            !apiKey.isEmpty,
            let endpoint = (plist["StreamingEndpointURL"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
            let endpointURL = URL(string: endpoint),
            let model = (plist["StreamingModel"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
            !model.isEmpty
        else {
            throw StreamingServiceConfigError.invalidFile
        }

        let maxTokens = plist["StreamingMaxTokens"] as? Int ?? 2048
        let temperature = plist["StreamingTemperature"] as? Double
        guard (1...2048).contains(maxTokens),
              temperature.map({ $0 > 0 && $0 <= 1 }) ?? true else {
            throw StreamingServiceConfigError.invalidFile
        }

        return StreamingServiceConfig(
            apiKey: apiKey,
            endpointURL: endpointURL,
            model: model,
            maxTokens: maxTokens,
            temperature: temperature
        )
    }
}

enum StreamingServiceConfigError: LocalizedError {
    case missingFile
    case invalidFile

    var errorDescription: String? {
        switch self {
        case .missingFile:
            return "缺少本地配置文件 LocalConfig.plist"
        case .invalidFile:
            return "LocalConfig.plist 配置不完整，请检查 StreamingAPIKey、StreamingEndpointURL、StreamingModel、StreamingMaxTokens、StreamingTemperature"
        }
    }
}

struct ChatProviderRequest: Sendable {
    let systemPrompt: String
    let messages: [ChatProviderMessage]
}

struct ChatProviderMessage: Sendable {
    enum Role: String, Sendable {
        case user
        case assistant
    }

    let role: Role
    let content: String
}

enum StreamingFinishReason: Equatable, Sendable {
    case endTurn
    case maxTokens
    case stopSequence
    case toolUse
    case unknown(String?)

    init(stopReason: String?) {
        switch stopReason {
        case "end_turn":
            self = .endTurn
        case "max_tokens":
            self = .maxTokens
        case "stop_sequence":
            self = .stopSequence
        case "tool_use":
            self = .toolUse
        case let value:
            self = .unknown(value)
        }
    }
}

private struct MiniMaxAnthropicRequest: Encodable {
    let model: String
    let maxTokens: Int
    let system: String
    let stream: Bool
    let messages: [MiniMaxAnthropicMessage]
    let temperature: Double?

    private enum CodingKeys: String, CodingKey {
        case model
        case maxTokens = "max_tokens"
        case system
        case stream
        case messages
        case temperature
    }
}

private struct MiniMaxAnthropicMessage: Encodable {
    let role: String
    let content: [MiniMaxAnthropicContentBlock]
}

private struct MiniMaxAnthropicContentBlock: Encodable {
    let type: String
    let text: String
}

private struct StreamingErrorEnvelope: Decodable {
    struct Err: Decodable {
        let code: String?
        let message: String
    }

    let error: Err
}

private struct AnthropicStreamEvent: Decodable {
    let type: String?
    let delta: AnthropicStreamDelta?
    let error: AnthropicStreamError?
}

private struct AnthropicStreamDelta: Decodable {
    let type: String?
    let text: String?
    let thinking: String?
    let stopReason: String?

    private enum CodingKeys: String, CodingKey {
        case type
        case text
        case thinking
        case stopReason = "stop_reason"
    }
}

private struct AnthropicStreamError: Decodable {
    let type: String?
    let message: String
}

final class MiniMaxAnthropicStreamingClient {

    private let configProvider: () throws -> StreamingServiceConfig
    private var eventSource: EventSource?

    init(configProvider: @escaping () throws -> StreamingServiceConfig = StreamingServiceConfig.loadLocal) {
        self.configProvider = configProvider
    }

    /// 注意：EventSource.stop() 后不能再 restart（所以每次 stream 都 new 一个 EventSource）
    func startStream(request: ChatProviderRequest,
                     model: String? = nil,
                     onDelta: @escaping (_ content: String?, _ reasoning: String?) -> Void,
                     onDone: @escaping (StreamingFinishReason) -> Void,
                     onError: @escaping (Error) -> Void) {

        stop() // 若之前有连接，先停掉（并 new 一个新的）

        let config: StreamingServiceConfig
        do {
            config = try configProvider()
        } catch {
            onError(error)
            return
        }

        let anthropicRequest = MiniMaxAnthropicRequest(
            model: model ?? config.model,
            maxTokens: config.maxTokens,
            system: request.systemPrompt,
            stream: true,
            messages: request.messages.map { message in
                MiniMaxAnthropicMessage(
                    role: message.role.rawValue,
                    content: [
                        MiniMaxAnthropicContentBlock(type: "text", text: message.content)
                    ]
                )
            },
            temperature: config.temperature
        )

        let body: Data
        do {
            let encoder = JSONEncoder()
            body = try encoder.encode(anthropicRequest)
        } catch {
            onError(error)
            return
        }

        let handler = StreamingEventHandler(
            onDelta: onDelta,
            onDone: onDone,
            onError: onError
        )

        var eventSourceConfig = EventSource.Config(handler: handler, url: config.endpointURL)
        eventSourceConfig.method = "POST"
        eventSourceConfig.body = body
        eventSourceConfig.headers = [
            "Authorization": "Bearer \(config.apiKey)",
            "Content-Type": "application/json",
            "Accept": "text/event-stream"
        ]

        let es = EventSource(config: eventSourceConfig)
        self.eventSource = es
        es.start()
    }

    func stop() {
        eventSource?.stop()
        eventSource = nil
    }
}

private final class StreamingEventHandler: EventHandler {

    private let onDelta: (_ content: String?, _ reasoning: String?) -> Void
    private let onDone: (StreamingFinishReason) -> Void
    private let onErrorCb: (Error) -> Void
    private var streamFinished = false
    private var finishReason: StreamingFinishReason = .unknown(nil)

    init(onDelta: @escaping (_ content: String?, _ reasoning: String?) -> Void,
         onDone: @escaping (StreamingFinishReason) -> Void,
         onError: @escaping (Error) -> Void) {
        self.onDelta = onDelta
        self.onDone = onDone
        self.onErrorCb = onError
    }

    func onOpened() { }

    func onClosed() { }

    func onComment(comment: String) { }

    func onError(error: Error) {
        guard !streamFinished else { return }
        streamFinished = true
        onErrorCb(error)
    }

    func onMessage(eventType: String, messageEvent: MessageEvent) {
        let dataStr = messageEvent.data.trimmingCharacters(in: .whitespacesAndNewlines)
        if dataStr.isEmpty {
            return
        }

        if dataStr == "[DONE]" {
            emitDoneIfNeeded()
            return
        }

        guard let data = dataStr.data(using: .utf8) else { return }

        if let env = try? JSONDecoder().decode(StreamingErrorEnvelope.self, from: data) {
            let nsError = NSError(
                domain: "StreamingService",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: env.error.message]
            )
            onError(error: nsError)
            return
        }

        if let env = try? JSONDecoder().decode(AnthropicStreamEvent.self, from: data) {
            if let error = env.error {
                onError(error: NSError.streamingServiceError(error.message))
                return
            }

            switch env.type {
            case "content_block_delta":
                if env.delta?.type == "thinking_delta", let thinking = env.delta?.thinking, !thinking.isEmpty {
                    onDelta(nil, thinking)
                } else if let text = env.delta?.text, !text.isEmpty {
                    onDelta(text, nil)
                }
            case "message_delta":
                finishReason = StreamingFinishReason(stopReason: env.delta?.stopReason)
            case "message_stop":
                emitDoneIfNeeded()
            case "error":
                let message = env.error?.message ?? "MiniMax Anthropic stream returned an error."
                onError(error: NSError.streamingServiceError(message))
            default:
                break
            }
        }
    }

    private func emitDoneIfNeeded() {
        guard !streamFinished else { return }
        streamFinished = true
        onDone(finishReason)
    }
}

private extension NSError {
    static func streamingServiceError(_ message: String) -> NSError {
        NSError(
            domain: "StreamingService",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}
