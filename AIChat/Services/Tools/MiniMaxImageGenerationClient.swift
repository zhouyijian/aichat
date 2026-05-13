import Foundation

struct GeneratedImageBatch: Sendable {
    let id: String
    let urls: [String]
    let successCount: String?
    let failedCount: String?
}

final class MiniMaxImageGenerationClient {
    private static let requestTimeout: TimeInterval = 300
    private static let resourceTimeout: TimeInterval = 600
    private static let defaultSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = resourceTimeout
        configuration.waitsForConnectivity = true
        return URLSession(configuration: configuration)
    }()

    private let configProvider: () throws -> StreamingServiceConfig
    private let session: URLSession

    init(
        configProvider: @escaping () throws -> StreamingServiceConfig = StreamingServiceConfig.loadLocal,
        session: URLSession = MiniMaxImageGenerationClient.defaultSession
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
        request.timeoutInterval = Self.requestTimeout

        let (data, response) = try await data(for: request)
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

    private func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch {
            if Task.isCancelled {
                throw CancellationError()
            }
            if let urlError = error as? URLError {
                switch urlError.code {
                case .timedOut:
                    throw ToolExecutionError.executionFailed("图片生成超时，请稍后重试或换一个更简单的提示词")
                case .cancelled:
                    throw ToolExecutionError.executionFailed("图片生成请求被系统取消，请检查网络后重试")
                default:
                    break
                }
            }
            throw error
        }
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
