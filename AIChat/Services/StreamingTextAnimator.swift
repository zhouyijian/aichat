//
//  StreamingTextAnimator.swift
//  AIChat
//
//  Created by Codex on 2026/5/8.
//

import Foundation

@MainActor
final class StreamingTextAnimator {

    private struct PendingDelta {
        var content = ""
        var reasoning = ""
    }

    private var pendingByID: [UUID: PendingDelta] = [:]
    private var task: Task<Void, Never>?

    private let intervalNs: UInt64
    private let maxCharactersPerTick: Int
    private let onEmit: (UUID, String?, String?) -> Void

    init(
        intervalNs: UInt64 = 45_000_000,
        maxCharactersPerTick: Int = 2,
        onEmit: @escaping (UUID, String?, String?) -> Void
    ) {
        self.intervalNs = intervalNs
        self.maxCharactersPerTick = max(1, maxCharactersPerTick)
        self.onEmit = onEmit
    }

    func enqueue(id: UUID, contentDelta: String?, reasoningDelta: String?) {
        guard contentDelta?.isEmpty == false || reasoningDelta?.isEmpty == false else { return }

        var pending = pendingByID[id] ?? PendingDelta()
        if let contentDelta, !contentDelta.isEmpty {
            pending.content += contentDelta
        }
        if let reasoningDelta, !reasoningDelta.isEmpty {
            pending.reasoning += reasoningDelta
        }
        pendingByID[id] = pending
        startLoopIfNeeded()
    }

    func flush(id: UUID) {
        guard let pending = pendingByID.removeValue(forKey: id) else { return }
        emit(id: id, content: pending.content, reasoning: pending.reasoning)
        stopLoopIfIdle()
    }

    func drain(id: UUID) async {
        while pendingByID[id] != nil {
            emitNextSlice(for: id, accelerated: false)
            try? await Task.sleep(nanoseconds: intervalNs)
        }
        stopLoopIfIdle()
    }

    func discard(id: UUID) {
        pendingByID.removeValue(forKey: id)
        stopLoopIfIdle()
    }

    func discardAll() {
        pendingByID.removeAll()
        task?.cancel()
        task = nil
    }

    private func startLoopIfNeeded() {
        guard task == nil else { return }

        task = Task { [weak self] in
            guard let self else { return }

            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: self.intervalNs)
                if Task.isCancelled { break }
                self.emitNextSlices()
                if self.pendingByID.isEmpty {
                    break
                }
            }

            self.task = nil
        }
    }

    private func stopLoopIfIdle() {
        guard pendingByID.isEmpty else { return }
        task?.cancel()
        task = nil
    }

    private func emitNextSlices() {
        for id in Array(pendingByID.keys) {
            emitNextSlice(for: id, accelerated: false)
        }
    }

    private func emit(id: UUID, content: String, reasoning: String) {
        guard !content.isEmpty || !reasoning.isEmpty else { return }
        onEmit(id, content.isEmpty ? nil : content, reasoning.isEmpty ? nil : reasoning)
    }

    private func emitNextSlice(for id: UUID, accelerated: Bool) {
        guard var pending = pendingByID[id] else { return }

        let limit = sliceLimit(for: pending, accelerated: accelerated)
        let content = takePrefix(from: &pending.content, limit: limit)
        let reasoning = takePrefix(from: &pending.reasoning, limit: limit)

        if pending.content.isEmpty && pending.reasoning.isEmpty {
            pendingByID.removeValue(forKey: id)
        } else {
            pendingByID[id] = pending
        }

        emit(id: id, content: content, reasoning: reasoning)
    }

    private func sliceLimit(for pending: PendingDelta, accelerated: Bool) -> Int {
        if accelerated {
            return maxCharactersPerTick * 2
        }

        let backlog = pending.content.count + pending.reasoning.count
        if backlog > 600 {
            return maxCharactersPerTick * 3
        }
        if backlog > 220 {
            return maxCharactersPerTick * 2
        }
        return maxCharactersPerTick
    }

    private func takePrefix(from text: inout String, limit: Int) -> String {
        guard !text.isEmpty else { return "" }

        let endIndex = text.index(
            text.startIndex,
            offsetBy: max(1, limit),
            limitedBy: text.endIndex
        ) ?? text.endIndex
        let prefix = String(text[..<endIndex])
        text.removeSubrange(..<endIndex)
        return prefix
    }
}
