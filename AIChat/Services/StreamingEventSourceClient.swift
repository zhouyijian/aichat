//
//  StreamingEventSourceClient.swift
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

        return StreamingServiceConfig(apiKey: apiKey, endpointURL: endpointURL, model: model)
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
            return "LocalConfig.plist 配置不完整，请检查 StreamingAPIKey、StreamingEndpointURL、StreamingModel"
        }
    }
}

private struct StreamingResponseChunk: Decodable {
    struct Choice: Decodable {
        struct MessageDelta: Decodable {
            let content: String?
            let reasoningContent: String?
            let reasoning: String?

            private enum CodingKeys: String, CodingKey {
                case content
                case reasoningContent = "reasoning_content"
                case reasoning
            }
        }

        let delta: MessageDelta?
        let message: MessageDelta?
        let finishReason: String?
        let text: String?

        private enum CodingKeys: String, CodingKey {
            case delta
            case message
            case finishReason = "finish_reason"
            case text
        }
    }

    let choices: [Choice]
}

private struct StreamingErrorEnvelope: Decodable {
    struct Err: Decodable {
        let code: String?
        let message: String
    }

    let error: Err
}


final class StreamingEventSourceClient {

    private let configProvider: () throws -> StreamingServiceConfig
    private var eventSource: EventSource?

    init(configProvider: @escaping () throws -> StreamingServiceConfig = StreamingServiceConfig.loadLocal) {
        self.configProvider = configProvider
    }

    /// 注意：EventSource.stop() 后不能再 restart（所以每次 stream 都 new 一个 EventSource）
    func startStream(messages: [[String: String]],
                     model: String? = nil,
                     onDelta: @escaping (_ content: String?, _ reasoning: String?) -> Void,
                     onDone: @escaping () -> Void,
                     onError: @escaping (Error) -> Void) {

        stop() // 若之前有连接，先停掉（并 new 一个新的）

        let config: StreamingServiceConfig
        do {
            config = try configProvider()
        } catch {
            onError(error)
            return
        }

        let bodyObj: [String: Any] = [
            "model": model ?? config.model,
            "stream": true,
            "messages": messages
        ]
        let body = try? JSONSerialization.data(withJSONObject: bodyObj)

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
    private let onDone: () -> Void
    private let onErrorCb: (Error) -> Void
    private var streamFinished = false

    init(onDelta: @escaping (_ content: String?, _ reasoning: String?) -> Void,
         onDone: @escaping () -> Void,
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

        if let chunk = try? JSONDecoder().decode(StreamingResponseChunk.self, from: data),
           let first = chunk.choices.first {
            let delta = first.delta ?? first.message

            if let reasoning = (delta?.reasoningContent ?? delta?.reasoning), !reasoning.isEmpty {
                onDelta(nil, reasoning)
            }

            if let text = delta?.content, !text.isEmpty {
                onDelta(text, nil)
            } else if let text = first.text, !text.isEmpty {
                onDelta(text, nil)
            }

            if first.finishReason != nil {
                emitDoneIfNeeded()
            }
        }
    }

    private func emitDoneIfNeeded() {
        guard !streamFinished else { return }
        streamFinished = true
        onDone()
    }
}
