import Foundation

enum ToolSchemas {
    static let generateImage = objectSchema(
        properties: [
            "prompt": stringSchema(description: "最终用于图片生成模型的高质量提示词，保留用户明确的风格、主体、构图和文字要求。"),
            "caption": stringSchema(description: "展示给用户的中文图片说明。应完整描述图片内容，不要省略成英文提示词。"),
            "aspect_ratio": enumSchema(values: ["1:1", "16:9", "9:16", "4:3", "3:4"]),
            "n": numberSchema(description: "生成图片数量，1 到 4。")
        ],
        required: ["prompt", "caption"]
    )

    static let createReminder = objectSchema(
        properties: [
            "title": stringSchema(description: "提醒事项标题。"),
            "due_at": stringSchema(description: "ISO-8601 日期时间，必须带时区，例如 2026-05-13T21:00:00+08:00。"),
            "notes": stringSchema(description: "可选备注。")
        ],
        required: ["title", "due_at"]
    )

    static let createAlarm = objectSchema(
        properties: [
            "label": stringSchema(description: "闹钟或通知标题。"),
            "fire_at": stringSchema(description: "ISO-8601 日期时间，必须带时区，例如 2026-05-14T07:30:00+08:00。"),
            "repeat_rule": enumSchema(values: ["none", "daily", "weekdays", "weekends"])
        ],
        required: ["label", "fire_at"]
    )

    static func objectSchema(properties: [String: JSONValue], required: [String]) -> JSONValue {
        .object([
            "type": .string("object"),
            "properties": .object(properties),
            "required": .array(required.map(JSONValue.string))
        ])
    }

    static func stringSchema(description: String? = nil) -> JSONValue {
        var object: [String: JSONValue] = ["type": .string("string")]
        if let description {
            object["description"] = .string(description)
        }
        return .object(object)
    }

    static func numberSchema(description: String? = nil) -> JSONValue {
        var object: [String: JSONValue] = ["type": .string("integer")]
        if let description {
            object["description"] = .string(description)
        }
        return .object(object)
    }

    static func enumSchema(values: [String]) -> JSONValue {
        .object([
            "type": .string("string"),
            "enum": .array(values.map(JSONValue.string))
        ])
    }
}
