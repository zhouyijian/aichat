import Foundation

enum ToolIntentRouter {
    static func toolCalls(
        for userText: String,
        now: Date = Date(),
        timeZone: TimeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
    ) -> [ToolCall] {
        let text = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }

        if isImageGenerationRequest(text) {
            return [
                ToolCall(
                    id: "local.generate_image.\(UUID().uuidString)",
                    name: "generate_image",
                    input: .object([
                        "prompt": .string(text),
                        "caption": .string(text),
                        "aspect_ratio": .string(aspectRatio(in: text)),
                        "n": .number(Double(imageCount(in: text)))
                    ])
                )
            ]
        }

        if isAlarmRequest(text),
           let scheduledAt = scheduledDate(in: text, now: now, timeZone: timeZone) {
            return [
                ToolCall(
                    id: "local.create_alarm.\(UUID().uuidString)",
                    name: "create_alarm",
                    input: .object([
                        "label": .string(alarmLabel(in: text)),
                        "fire_at": .string(isoString(from: scheduledAt, timeZone: timeZone)),
                        "repeat_rule": .string(repeatRule(in: text))
                    ])
                )
            ]
        }

        if isReminderRequest(text),
           let scheduledAt = scheduledDate(in: text, now: now, timeZone: timeZone) {
            return [
                ToolCall(
                    id: "local.create_reminder.\(UUID().uuidString)",
                    name: "create_reminder",
                    input: .object([
                        "title": .string(reminderTitle(in: text)),
                        "due_at": .string(isoString(from: scheduledAt, timeZone: timeZone)),
                        "notes": .string(text)
                    ])
                )
            ]
        }

        return []
    }

    private static func isImageGenerationRequest(_ text: String) -> Bool {
        guard !looksLikeMetaQuestion(text) else { return false }

        let actionWords = ["生成", "画", "绘制", "做一张", "做个", "设计", "创建", "制作"]
        let imageWords = ["图", "图片", "海报", "头像", "壁纸", "插画", "logo", "Logo", "表情包", "视觉"]
        return actionWords.contains { text.contains($0) } &&
            imageWords.contains { text.contains($0) }
    }

    private static func looksLikeMetaQuestion(_ text: String) -> Bool {
        let metaPrefixes = ["怎么", "如何", "为什么", "能不能", "是否", "讲讲", "解释"]
        let metaWords = ["文档", "代码", "方案", "原理", "实现", "为什么不能"]
        let asksAboutImages = text.contains("生成图片") || text.contains("画图")
        return asksAboutImages &&
            (metaPrefixes.contains { text.hasPrefix($0) } || metaWords.contains { text.contains($0) })
    }

    private static func aspectRatio(in text: String) -> String {
        let supported = ["16:9", "9:16", "4:3", "3:4", "1:1"]
        let normalized = text.replacingOccurrences(of: "：", with: ":")
        return supported.first { normalized.contains($0) } ?? "1:1"
    }

    private static func imageCount(in text: String) -> Int {
        if let range = text.range(of: #"([1-4])\s*张"#, options: .regularExpression),
           let value = Int(text[range].filter(\.isNumber)) {
            return value
        }

        let chineseCounts: [(String, Int)] = [
            ("一张", 1),
            ("两张", 2),
            ("二张", 2),
            ("三张", 3),
            ("四张", 4)
        ]
        return chineseCounts.first { text.contains($0.0) }?.1 ?? 1
    }

    private static func isAlarmRequest(_ text: String) -> Bool {
        let alarmWords = ["闹钟", "叫醒", "叫我起床", "叫起床", "起床", "响铃", "叫我"]
        return alarmWords.contains { text.contains($0) }
    }

    private static func isReminderRequest(_ text: String) -> Bool {
        guard !isAlarmRequest(text) else { return false }
        let reminderWords = ["提醒我", "提醒一下", "提醒", "待办", "记得"]
        return reminderWords.contains { text.contains($0) }
    }

    private static func repeatRule(in text: String) -> String {
        if text.contains("工作日") || text.contains("周一到周五") {
            return "weekdays"
        }
        if text.contains("周末") {
            return "weekends"
        }
        if text.contains("每天") || text.contains("每日") {
            return "daily"
        }
        return "none"
    }

    private static func scheduledDate(
        in text: String,
        now: Date,
        timeZone: TimeZone
    ) -> Date? {
        guard var time = clockTime(in: text) else { return nil }
        let period = dayPeriod(in: text)
        time.hour = adjustedHour(time.hour, period: period)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        var date = calendar.startOfDay(for: now)
        if text.contains("后天") {
            date = calendar.date(byAdding: .day, value: 2, to: date) ?? date
        } else if text.contains("明天") || text.contains("明早") || text.contains("明晚") {
            date = calendar.date(byAdding: .day, value: 1, to: date) ?? date
        }

        var components = calendar.dateComponents([.year, .month, .day], from: date)
        components.hour = time.hour
        components.minute = time.minute
        components.second = 0
        guard var candidate = calendar.date(from: components) else { return nil }

        if candidate <= now {
            let secondsBehind = now.timeIntervalSince(candidate)
            if secondsBehind <= 90 {
                candidate = now.addingTimeInterval(15)
            } else {
                candidate = calendar.date(byAdding: .day, value: 1, to: candidate) ?? candidate
            }
        }

        return candidate
    }

    private struct ClockTime {
        var hour: Int
        var minute: Int
    }

    private enum DayPeriod {
        case am
        case noon
        case pm
        case unspecified
    }

    private static func clockTime(in text: String) -> ClockTime? {
        let normalized = text
            .replacingOccurrences(of: "：", with: ":")
            .replacingOccurrences(of: "．", with: ".")

        if let match = firstMatch(
            #"(?<!\d)(\d{1,2})\s*[:.]\s*(\d{1,2})(?!\d)"#,
            in: normalized
        ),
           let hour = Int(match[1]),
           let minute = Int(match[2]),
           isValid(hour: hour, minute: minute) {
            return ClockTime(hour: hour, minute: minute)
        }

        if let match = firstMatch(
            #"(?<!\d)(\d{1,2})\s*[点时]\s*(?:(\d{1,2})\s*分?)?(半)?(?!\d)"#,
            in: normalized
        ),
           let hour = Int(match[1]) {
            let minute = match[3].isEmpty ? (Int(match[2]) ?? 0) : 30
            if isValid(hour: hour, minute: minute) {
                return ClockTime(hour: hour, minute: minute)
            }
        }

        return nil
    }

    private static func firstMatch(_ pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range) else { return nil }

        return (0..<match.numberOfRanges).map { index in
            let range = match.range(at: index)
            guard let swiftRange = Range(range, in: text) else { return "" }
            return String(text[swiftRange])
        }
    }

    private static func isValid(hour: Int, minute: Int) -> Bool {
        (0...23).contains(hour) && (0...59).contains(minute)
    }

    private static func dayPeriod(in text: String) -> DayPeriod {
        if ["下午", "晚上", "今晚", "明晚", "傍晚"].contains(where: text.contains) {
            return .pm
        }
        if text.contains("中午") {
            return .noon
        }
        if ["上午", "早上", "明早", "今早", "凌晨"].contains(where: text.contains) {
            return .am
        }
        return .unspecified
    }

    private static func adjustedHour(_ hour: Int, period: DayPeriod) -> Int {
        switch period {
        case .pm:
            return hour < 12 ? hour + 12 : hour
        case .noon:
            return hour < 11 ? hour + 12 : hour
        case .am:
            return hour == 12 ? 0 : hour
        case .unspecified:
            return hour
        }
    }

    private static func reminderTitle(in text: String) -> String {
        titleAfterAnyMarker(["提醒我", "提醒一下我", "提醒一下", "提醒"], in: text) ??
            cleanedTitle(from: text, fallback: "提醒")
    }

    private static func alarmLabel(in text: String) -> String {
        if text.contains("叫我起床") || text.contains("叫起床") {
            return "起床"
        }
        if text.contains("叫醒我") {
            return "叫醒我"
        }
        return titleAfterAnyMarker(["叫我", "叫醒", "闹钟"], in: text) ??
            cleanedTitle(from: text, fallback: "闹钟")
    }

    private static func titleAfterAnyMarker(_ markers: [String], in text: String) -> String? {
        for marker in markers {
            guard let range = text.range(of: marker) else { continue }
            let suffix = text[range.upperBound...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "，,。.!！?？"))
            if !suffix.isEmpty {
                return String(suffix)
            }
        }
        return nil
    }

    private static func cleanedTitle(from text: String, fallback: String) -> String {
        var title = text
        let removable = [
            "今天", "今晚", "明天", "明早", "明晚", "后天", "上午", "下午", "晚上", "早上", "中午",
            "提醒我", "提醒一下", "提醒", "设置", "新增", "添加", "闹钟", "叫醒我", "叫醒", "叫我"
        ]
        for token in removable {
            title = title.replacingOccurrences(of: token, with: "")
        }
        title = title.replacingOccurrences(
            of: #"(?<!\d)\d{1,2}\s*[:.点时]\s*\d{0,2}\s*分?半?(?!\d)"#,
            with: "",
            options: .regularExpression
        )
        title = title.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "，,。.!！?？"))
        return title.isEmpty ? fallback : title
    }

    private static func isoString(from date: Date, timeZone: TimeZone) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withColonSeparatorInTimeZone]
        formatter.timeZone = timeZone
        return formatter.string(from: date)
    }
}
