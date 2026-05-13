import EventKit
import Foundation

struct CreateReminderTool: ChatTool {
    let name = "create_reminder"

    var definition: ToolDefinition {
        ToolDefinition(
            name: name,
            description: "当用户要求新增提醒事项、待办提醒、到某个时间提醒自己做某事时调用。不要用于“叫醒我、起床、响铃、闹钟”这类意图，这些应调用 create_alarm。",
            inputSchema: ToolSchemas.createReminder
        )
    }

    func execute(input: JSONValue) async throws -> ToolExecutionResult {
        guard let title = try ToolArgumentReader.string("title", in: input) else {
            throw ToolExecutionError.invalidArguments("缺少 title")
        }
        var dueAt = try ToolArgumentReader.isoDate("due_at", in: input)
        let notes = try ToolArgumentReader.string("notes", in: input, required: false)

        let now = Date()
        if dueAt <= now, now.timeIntervalSince(dueAt) <= 90 {
            dueAt = now.addingTimeInterval(15)
        }

        guard dueAt > now else {
            throw ToolExecutionError.invalidArguments("提醒时间已经过去")
        }

        let eventStore = EKEventStore()
        let granted = try await requestReminderAccess(eventStore)
        guard granted else {
            throw ToolExecutionError.permissionDenied("请在系统设置中允许访问提醒事项")
        }

        guard let calendar = eventStore.defaultCalendarForNewReminders() else {
            throw ToolExecutionError.executionFailed("没有可用的提醒事项列表")
        }

        let reminder = EKReminder(eventStore: eventStore)
        reminder.title = title
        reminder.notes = notes
        reminder.calendar = calendar
        reminder.addAlarm(EKAlarm(absoluteDate: dueAt))

        var components = Calendar(identifier: .gregorian)
            .dateComponents(in: TimeZone(identifier: "Asia/Shanghai") ?? .current, from: dueAt)
        components.calendar = Calendar(identifier: .gregorian)
        reminder.dueDateComponents = components

        try eventStore.save(reminder, commit: true)

        let displayTime = DateFormatter.toolDisplay.string(from: dueAt)
        let text = "已添加提醒：\(title)\n时间：\(displayTime)"
        return ToolExecutionResult(
            toolName: name,
            ok: true,
            displayText: text,
            blocks: [
                MessageBlock(kind: .markdown, text: text, isComplete: true)
            ],
            structuredData: .object([
                "reminder_id": .string(reminder.calendarItemIdentifier),
                "title": .string(title),
                "due_at": .string(ISO8601DateFormatter.withInternetDateTime.string(from: dueAt)),
                "notes": notes.map(JSONValue.string) ?? .null
            ])
        )
    }

    private func requestReminderAccess(_ eventStore: EKEventStore) async throws -> Bool {
        if #available(iOS 17.0, *) {
            return try await eventStore.requestFullAccessToReminders()
        }

        return try await withCheckedThrowingContinuation { continuation in
            eventStore.requestAccess(to: .reminder) { granted, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: granted)
                }
            }
        }
    }
}
