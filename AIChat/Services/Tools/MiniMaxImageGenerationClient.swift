import Foundation

struct GeneratedImageBatch: Sendable {
    let id: String
    let urls: [String]
    let successCount: String?
    let failedCount: String?
}

final class MiniMaxImageGenerationClient {
    private let configProvider: () throws -> StreamingServiceConfig
    private let session: URLSession

    init(
        configProvider: @escaping () throws -> StreamingServiceConfig = StreamingServiceConfig.loadLocal,
        session: URLSession = .shared
    ) {
        self.configProvider = configProvider
        self.session = session
    }

    func generate(prompt: String, aspectRatio: String, count: Int) async throws -> GeneratedImageBatch {
        let config = try configProvider()
        let requestBody = MiniMaxImageGenerationRequest(
            model: config.imageModel,
            prompt: prompt,
            aspectRatio: aspectRatio,
            responseFormat: "url",
            n: max(1, min(count, 4)),
            promptOptimizer: true
        )

        var request = URLRequest(url: config.imageEndpointURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(requestBody)

        let (data, response) = try await session.data(for: request)
        try Self.validate(response: response, data: data)

        let decoded = try JSONDecoder().decode(MiniMaxImageGenerationResponse.self, from: data)
        if let baseResp = decoded.baseResp,
           baseResp.statusCode != 0 {
            throw ToolExecutionError.executionFailed(baseResp.statusMsg ?? "图片生成失败")
        }

        let urls = decoded.data.imageURLs.filter { !$0.isEmpty }
        guard !urls.isEmpty else {
            throw ToolExecutionError.executionFailed("图片生成成功但没有返回图片 URL")
        }

        return GeneratedImageBatch(
            id: decoded.id,
            urls: urls,
            successCount: decoded.metadata?.successCount,
            failedCount: decoded.metadata?.failedCount
        )
    }

    private static func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "Image generation request failed."
            throw ToolExecutionError.executionFailed("图片生成失败（HTTP \(http.statusCode)）：\(message)")
        }
    }
}

private struct MiniMaxImageGenerationRequest: Encodable {
    let model: String
    let prompt: String
    let aspectRatio: String
    let responseFormat: String
    let n: Int
    let promptOptimizer: Bool

    private enum CodingKeys: String, CodingKey {
        case model
        case prompt
        case aspectRatio = "aspect_ratio"
        case responseFormat = "response_format"
        case n
        case promptOptimizer = "prompt_optimizer"
    }
}

private struct MiniMaxImageGenerationResponse: Decodable {
    struct DataEnvelope: Decodable {
        let imageURLs: [String]

        private enum CodingKeys: String, CodingKey {
            case imageURLs = "image_urls"
        }
    }

    struct Metadata: Decodable {
        let failedCount: String?
        let successCount: String?

        private enum CodingKeys: String, CodingKey {
            case failedCount = "failed_count"
            case successCount = "success_count"
        }
    }

    struct BaseResp: Decodable {
        let statusCode: Int
        let statusMsg: String?

        private enum CodingKeys: String, CodingKey {
            case statusCode = "status_code"
            case statusMsg = "status_msg"
        }
    }

    let id: String
    let data: DataEnvelope
    let metadata: Metadata?
    let baseResp: BaseResp?

    private enum CodingKeys: String, CodingKey {
        case id
        case data
        case metadata
        case baseResp = "base_resp"
    }
}

