//
//  EventSource.swift
//  AIChat
//
//  Created by 周一见 on 2026/3/3.
//

import Foundation
import LDSwiftEventSource

private struct OpenAICompatStreamChunk: Decodable {
    struct Choice: Decodable {
        struct Delta: Decodable {
            let content: String?
        }

        let delta: Delta
        let finishReason: String?

        private enum CodingKeys: String, CodingKey {
            case delta
            case finishReason = "finish_reason"
        }
    }

    let choices: [Choice]
}

private struct OpenAICompatErrorEnvelope: Decodable {
    struct Err: Decodable {
        let code: String?
        let message: String
    }

    let error: Err
}


final class OpenAIEventSourceClient {

    private let apiKey: String
    private var eventSource: EventSource?

    init(apiKey: String) {
        self.apiKey = apiKey
    }

    /// 注意：EventSource.stop() 后不能再 restart（所以每次 stream 都 new 一个 EventSource）
    func startStream(prompt: String,
                     model: String = "MiniMax-M2.5",
                     onDelta: @escaping (String) -> Void,
                     onDone: @escaping () -> Void,
                     onError: @escaping (Error) -> Void) {

        stop() // 若之前有连接，先停掉（并 new 一个新的）

        // MiniMax OpenAI 兼容域名：api.minimaxi.com
        let url = URL(string: "https://api.minimaxi.com/v1/chat/completions")!

        // 1) 组装请求 body（OpenAI chat.completions 兼容格式）
        let bodyObj: [String: Any] = [
            "model": model,
            "stream": true,
            "messages": [
                [
                    "role": "system",
                    "content": "请始终使用简体中文输出，包括思考过程"
                ],
                ["role": "user", "content": prompt]
            ]
        ]
        let body = try? JSONSerialization.data(withJSONObject: bodyObj)

        // 2) 事件处理器：收 data（messageEvent.data）→ JSON decode → delta/done
        let handler = Handler(
            onDelta: onDelta,
            onDone: onDone,
            onError: onError
        )

        // 3) Config：method/body/headers
        var config = EventSource.Config(handler: handler, url: url)
        config.method = "POST"
        config.body = body
        config.headers = [
            "Authorization": "Bearer \(apiKey)",
            "Content-Type": "application/json",
            "Accept": "text/event-stream"
        ]

        let es = EventSource(config: config)
        self.eventSource = es
        es.start()
    }

    func stop() {
        eventSource?.stop()
        eventSource = nil
    }
}

private final class Handler: EventHandler {

    private let onDelta: (String) -> Void
    private let onDone: () -> Void
    private let onErrorCb: (Error) -> Void
    private var streamFinished = false

    init(onDelta: @escaping (String) -> Void,
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

        // OpenAI 兼容流结束标记
        if dataStr == "[DONE]" {
            emitDoneIfNeeded()
            return
        }

        guard let data = dataStr.data(using: .utf8) else { return }

        // 先处理 error envelope
        if let env = try? JSONDecoder().decode(OpenAICompatErrorEnvelope.self, from: data) {
            let nsError = NSError(
                domain: "MiniMax",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: env.error.message]
            )
            onError(error: nsError)
            return
        }

        // 再处理 chat.completions stream chunk
        if let chunk = try? JSONDecoder().decode(OpenAICompatStreamChunk.self, from: data),
           let first = chunk.choices.first {
            if let text = first.delta.content, !text.isEmpty {
                onDelta(text)
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
