//
//  StreamingThrottler.swift
//  AIChat
//
//  Created by 周一见 on 2026/3/2.
//

import Foundation

@MainActor
final class StreamingThrottler {

    private var task: Task<Void, Never>?
    private var pendingID: UUID?
    private var hasPendingChanges = false
    private var shouldPinToBottomForCurrentStream = false

    private let intervalNs: UInt64
    private let shouldPinToBottom: () -> Bool
    private let onTick: (UUID, Bool) -> Void

    /// interval 默认约 30fps，流式文本增长会比 100ms 批量刷新自然一些。
    init(
        intervalNs: UInt64 = 33_000_000,
        shouldPinToBottom: @escaping () -> Bool = { false },
        onTick: @escaping (UUID, Bool) -> Void
    ) {
        self.intervalNs = intervalNs
        self.shouldPinToBottom = shouldPinToBottom
        self.onTick = onTick
    }

    /// 有新 token / 新内容时调用（只标记变化，不直接刷新 UI）
    func markChanged(id: UUID) {
        pendingID = id
        hasPendingChanges = true

        // 新一轮流式开始时，锁定一次“是否跟随到底部”的意图
        if task == nil {
            shouldPinToBottomForCurrentStream = shouldPinToBottom()
            startLoop()
        } else if shouldPinToBottom() {
            shouldPinToBottomForCurrentStream = true
        }
    }

    /// 用户手动滚动时，关闭当前流式会话的自动跟随到底部
    func disablePinToBottomForCurrentStream() {
        shouldPinToBottomForCurrentStream = false
    }

    /// 用户重新回到底部时，恢复当前流式会话的自动跟随到底部
    func refreshPinToBottomForCurrentStream() {
        guard task != nil else { return }
        shouldPinToBottomForCurrentStream = shouldPinToBottom()
    }

    /// 流式结束/页面退出时调用
    func stop(flushPending: Bool = true, shouldPinToBottom: Bool? = nil) {
        if flushPending, hasPendingChanges, let id = pendingID {
            hasPendingChanges = false
            onTick(id, shouldPinToBottom ?? shouldPinToBottomForCurrentStream)
        }

        task?.cancel()
        task = nil
        pendingID = nil
        hasPendingChanges = false
        shouldPinToBottomForCurrentStream = false
    }

    deinit {
        task?.cancel()
    }

    private func startLoop() {
        task = Task { [weak self] in
            guard let self else { return }

            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: self.intervalNs)
                if Task.isCancelled { break }
                if !self.hasPendingChanges { continue }

                self.hasPendingChanges = false

                if let id = self.pendingID {
                    self.onTick(id, self.shouldPinToBottomForCurrentStream)
                }
            }

            self.task = nil
            self.shouldPinToBottomForCurrentStream = false
        }
    }
}
