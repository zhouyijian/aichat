import Foundation
import UserNotifications

struct CreateAlarmTool: ChatTool {
    let name = "create_alarm"

    var definition: ToolDefinition {
        ToolDefinition(
            name: name,
            description: "当用户要求设置闹钟、叫醒自己、叫自己起床、早上/明早/下午几点叫醒、按时响铃通知时调用。只要用户意图是叫醒或响铃，本工具优先于 create_reminder。此工具创建本 App 的本地通知闹钟。",
            inputSchema: ToolSchemas.createAlarm
        )
    }

    func execute(input: JSONValue) async throws -> ToolExecutionResult {
        guard let label = try ToolArgumentReader.string("label", in: input) else {
            throw ToolExecutionError.invalidArguments("缺少 label")
        }
        var fireAt = try ToolArgumentReader.isoDate("fire_at", in: input)
        let repeatRule = input["repeat_rule"]?.stringValue ?? "none"

        let now = Date()
        if fireAt <= now, now.timeIntervalSince(fireAt) <= 90 {
            fireAt = now.addingTimeInterval(15)
        }

        guard fireAt > now else {
            throw ToolExecutionError.invalidArguments("闹钟时间已经过去")
        }

        let center = UNUserNotificationCenter.current()
        let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
        guard granted else {
            throw ToolExecutionError.permissionDenied("请在系统设置中允许通知权限")
        }

        let content = UNMutableNotificationContent()
        content.title = label
        content.body = "闹钟时间到了"
        content.sound = .default

        let requests = makeRequests(content: content, fireAt: fireAt, repeatRule: repeatRule)
        for request in requests {
            try await center.add(request)
        }

        let displayTime = DateFormatter.toolDisplay.string(from: fireAt)
        let text = "已设置闹钟：\(label)\n时间：\(displayTime)"
        return ToolExecutionResult(
            toolName: name,
            ok: true,
            displayText: text,
            blocks: [
                MessageBlock(kind: .markdown, text: text, isComplete: true)
            ],
            structuredData: .object([
                "alarm_ids": .array(requests.map { .string($0.identifier) }),
                "label": .string(label),
                "fire_at": .string(ISO8601DateFormatter.withInternetDateTime.string(from: fireAt)),
                "repeat_rule": .string(repeatRule)
            ])
        )
    }

    private func makeRequests(
        content: UNNotificationContent,
        fireAt: Date,
        repeatRule: String
    ) -> [UNNotificationRequest] {
        let calendar = Calendar(identifier: .gregorian)
        let timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        var components = calendar.dateComponents(in: timeZone, from: fireAt)

        switch repeatRule {
        case "daily":
            components.year = nil
            components.month = nil
            components.day = nil
            components.weekday = nil
            return [
                UNNotificationRequest(
                    identifier: "ai-chat.alarm.\(UUID().uuidString)",
                    content: content,
                    trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
                )
            ]
        case "weekdays", "weekends":
            components.year = nil
            components.month = nil
            components.day = nil
            let weekdays = repeatRule == "weekdays" ? [2, 3, 4, 5, 6] : [1, 7]
            return weekdays.map { weekday in
                var repeatedComponents = components
                repeatedComponents.weekday = weekday
                return UNNotificationRequest(
                    identifier: "ai-chat.alarm.\(UUID().uuidString)",
                    content: content,
                    trigger: UNCalendarNotificationTrigger(dateMatching: repeatedComponents, repeats: true)
                )
            }
        default:
            return [
                UNNotificationRequest(
                    identifier: "ai-chat.alarm.\(UUID().uuidString)",
                    content: content,
                    trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
                )
            ]
        }
    }
}
