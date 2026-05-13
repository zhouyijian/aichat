import Foundation
import ImageIO
import UniformTypeIdentifiers

enum GeneratedImageStore {
    static let urlScheme = "aichat-generated-image"
    private static let maxImageBytes = 30 * 1024 * 1024
    private static let maxPixelCount = 100_000_000

    static func persist(data: Data, batchID: String, index: Int) throws -> String {
        let image = try validatedImage(data)

        let fileName = "\(sanitizedFileName(batchID))-\(index + 1).\(image.fileExtension)"
        let fileURL = try directory().appendingPathComponent(fileName, isDirectory: false)
        try image.data.write(to: fileURL, options: [.atomic])
        return referenceString(fileName: fileName)
    }

    static func resolvedURL(for url: URL) -> URL? {
        guard url.scheme == urlScheme else { return url }
        guard let fileName = fileName(from: url) else { return nil }
        return try? directory().appendingPathComponent(fileName, isDirectory: false)
    }

    static func fileExists(forReference reference: String) -> Bool {
        guard let url = URL(string: reference),
              let resolvedURL = resolvedURL(for: url)
        else { return false }

        return FileManager.default.fileExists(atPath: resolvedURL.path)
    }

    private static func directory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = base.appendingPathComponent("GeneratedImages", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try excludeFromBackupIfNeeded(directory)
        return directory
    }

    private static func referenceString(fileName: String) -> String {
        let escaped = fileName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? fileName
        return "\(urlScheme):///\(escaped)"
    }

    private static func fileName(from url: URL) -> String? {
        guard url.scheme == urlScheme,
              let fileName = url.pathComponents.last,
              fileName != "/",
              !fileName.contains("..")
        else { return nil }

        return fileName
    }

    private static func sanitizedFileName(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let scalars = value.unicodeScalars.map { scalar -> Character in
            allowed.contains(scalar) ? Character(scalar) : "-"
        }
        let name = String(scalars).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return name.isEmpty ? UUID().uuidString : name
    }

    private static func excludeFromBackupIfNeeded(_ url: URL) throws {
        var mutableURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try mutableURL.setResourceValues(values)
    }

    private static func validatedImage(_ data: Data) throws -> ValidatedImage {
        guard !data.isEmpty else {
            throw ToolExecutionError.executionFailed("图片生成成功但下载到的图片为空")
        }
        guard data.count <= maxImageBytes else {
            throw ToolExecutionError.executionFailed("图片生成成功但图片文件过大")
        }

        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let typeIdentifier = CGImageSourceGetType(source),
              let fileExtension = fileExtension(forTypeIdentifier: typeIdentifier as String),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber
        else {
            throw ToolExecutionError.executionFailed("图片生成成功但下载内容不是有效图片")
        }

        let pixelCount = width.intValue * height.intValue
        guard width.intValue > 0, height.intValue > 0, pixelCount <= maxPixelCount else {
            throw ToolExecutionError.executionFailed("图片生成成功但图片尺寸异常")
        }

        return ValidatedImage(data: data, fileExtension: fileExtension)
    }

    private static func fileExtension(forTypeIdentifier typeIdentifier: String) -> String? {
        guard let type = UTType(typeIdentifier) else { return nil }
        if type.conforms(to: .png) { return "png" }
        if type.conforms(to: .jpeg) { return "jpg" }
        if type.conforms(to: .webP) { return "webp" }
        if type.conforms(to: .heic) { return "heic" }
        return nil
    }

    private struct ValidatedImage {
        let data: Data
        let fileExtension: String
    }
}
