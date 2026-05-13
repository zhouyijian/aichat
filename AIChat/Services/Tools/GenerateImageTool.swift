import Foundation

struct GenerateImageTool: ChatTool {
    let name = "generate_image"
    private static let imageDownloadTimeout: TimeInterval = 300
    private static let imageDownloadResourceTimeout: TimeInterval = 600
    private static let imageDownloadSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = imageDownloadTimeout
        configuration.timeoutIntervalForResource = imageDownloadResourceTimeout
        configuration.waitsForConnectivity = true
        return URLSession(configuration: configuration)
    }()

    private let client: MiniMaxImageGenerationClient
    private let imageDataLoader: @Sendable (URL) async throws -> Data

    init(
        client: MiniMaxImageGenerationClient = MiniMaxImageGenerationClient(),
        imageDataLoader: @escaping @Sendable (URL) async throws -> Data = GenerateImageTool.defaultImageDataLoader
    ) {
        self.client = client
        self.imageDataLoader = imageDataLoader
    }

    var definition: ToolDefinition {
        ToolDefinition(
            name: name,
            description: "当用户想画图、生成图片、设计海报、logo、头像、壁纸、表情包或视觉素材时调用。",
            inputSchema: ToolSchemas.generateImage
        )
    }

    func execute(input: JSONValue) async throws -> ToolExecutionResult {
        guard let prompt = try ToolArgumentReader.string("prompt", in: input) else {
            throw ToolExecutionError.invalidArguments("缺少 prompt")
        }

        let caption = try ToolArgumentReader.string("caption", in: input, required: false) ?? prompt
        let aspectRatio = input["aspect_ratio"]?.stringValue ?? "1:1"
        let count = ToolArgumentReader.int("n", in: input, default: 1)
        let batch = try await client.generate(prompt: prompt, aspectRatio: aspectRatio, count: count)
        let displayURLs = try await persistedDisplayURLs(for: batch.urls, batchID: batch.id)

        var blocks: [MessageBlock] = [
            MessageBlock(kind: .markdown, text: "已生成 \(displayURLs.count) 张图片：", isComplete: true)
        ]
        blocks.append(
            contentsOf: displayURLs.enumerated().map { index, url in
                MessageBlock(
                    kind: .image(url: url, alt: caption),
                    text: displayURLs.count > 1 ? "\(caption) #\(index + 1)" : caption,
                    isComplete: true
                )
            }
        )

        return ToolExecutionResult(
            toolName: name,
            ok: true,
            displayText: "已生成 \(displayURLs.count) 张图片",
            blocks: blocks,
            structuredData: .object([
                "id": .string(batch.id),
                "image_urls": .array(displayURLs.map(JSONValue.string)),
                "source_image_urls": .array(batch.urls.map(JSONValue.string)),
                "success_count": .string(batch.successCount ?? "\(displayURLs.count)"),
                "failed_count": .string(batch.failedCount ?? "0"),
                "aspect_ratio": .string(aspectRatio),
                "prompt": .string(prompt),
                "caption": .string(caption)
            ])
        )
    }

    private func persistedDisplayURLs(for sourceURLs: [String], batchID: String) async throws -> [String] {
        try await withThrowingTaskGroup(of: (Int, String).self) { group in
            for (index, sourceURL) in sourceURLs.enumerated() {
                group.addTask {
                    let displayURL = try await persistImage(sourceURL: sourceURL, batchID: batchID, index: index)
                    return (index, displayURL)
                }
            }

            var indexedURLs: [(Int, String)] = []
            for try await result in group {
                indexedURLs.append(result)
            }

            return indexedURLs
                .sorted { $0.0 < $1.0 }
                .map(\.1)
        }
    }

    private func persistImage(sourceURL: String, batchID: String, index: Int) async throws -> String {
        guard let url = URL(string: sourceURL) else {
            throw ToolExecutionError.executionFailed("图片生成成功但返回了无效图片 URL")
        }

        let data = try await imageDataLoader(url)
        guard !data.isEmpty else {
            throw ToolExecutionError.executionFailed("图片生成成功但下载到的图片为空")
        }

        return try GeneratedImageStore.persist(data: data, batchID: batchID, index: index)
    }

    private static func defaultImageDataLoader(url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = imageDownloadTimeout

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await imageDownloadSession.data(for: request)
        } catch {
            if Task.isCancelled {
                throw CancellationError()
            }
            if let urlError = error as? URLError {
                switch urlError.code {
                case .timedOut:
                    throw ToolExecutionError.executionFailed("图片生成成功，但下载图片超时，请稍后重试")
                case .cancelled:
                    throw ToolExecutionError.executionFailed("图片生成成功，但图片下载被系统取消，请检查网络后重试")
                default:
                    break
                }
            }
            throw error
        }

        if let http = response as? HTTPURLResponse,
           !(200..<300).contains(http.statusCode) {
            throw ToolExecutionError.executionFailed("图片生成成功但图片下载失败（HTTP \(http.statusCode)）")
        }
        return data
    }
}
