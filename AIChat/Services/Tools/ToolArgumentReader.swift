import Foundation

enum ToolArgumentReader {
    static func string(_ key: String, in input: JSONValue, required: Bool = true) throws -> String? {
        let value = input[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        if required, value?.isEmpty != false {
            throw ToolExecutionError.invalidArguments("缺少 \(key)")
        }
        return value?.isEmpty == true ? nil : value
    }

    static func int(_ key: String, in input: JSONValue, default defaultValue: Int) -> Int {
        input[key]?.intValue ?? defaultValue
    }

    static func isoDate(_ key: String, in input: JSONValue) throws -> Date {
        guard let raw = try string(key, in: input) else {
            throw ToolExecutionError.invalidArguments("缺少 \(key)")
        }

        if let date = ISO8601DateFormatter.withInternetDateTime.date(from: raw)
            ?? ISO8601DateFormatter.withFractionalSeconds.date(from: raw) {
            return date
        }

        throw ToolExecutionError.invalidArguments("\(key) 不是有效的 ISO-8601 时间：\(raw)")
    }
}

extension ISO8601DateFormatter {
    static let withInternetDateTime: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withColonSeparatorInTimeZone]
        return formatter
    }()

    static let withFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds, .withColonSeparatorInTimeZone]
        return formatter
    }()
}

extension DateFormatter {
    static let toolDisplay: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy年M月d日 HH:mm"
        return formatter
    }()
}

