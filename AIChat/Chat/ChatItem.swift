import CoreGraphics
import Foundation

nonisolated enum TableColumnAlignment: Hashable, Sendable {
    case leading
    case center
    case trailing
}

nonisolated struct ChatItem: Hashable, Sendable {
    nonisolated struct ID: Hashable, Sendable {
        let messageID: UUID
        let blockKey: String

        var cacheKey: String {
            "\(messageID.uuidString):\(blockKey)"
        }
    }

    nonisolated enum Kind: Hashable, Sendable {
        case markdown
        case heading(level: Int)
        case quote
        case list
        case table(columns: Int, alignments: [TableColumnAlignment])
        case code(language: String?)
        case image(url: String, alt: String?)
        case reasoning
        case control(action: Action)
        case status
    }

    nonisolated enum Action: Hashable, Sendable {
        case toggleReasoning
        case continueGeneration
    }

    let id: ID
    let messageID: UUID
    let role: Role
    let kind: Kind
    let text: String
    let copyText: String
    let layoutVersion: Int
    let rendersMarkdown: Bool
    let previousKind: Kind?
    let nextKind: Kind?
    let isFirstInMessage: Bool
    let isLastInMessage: Bool

    var isCopyable: Bool {
        !copyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var outerTopSpacing: CGFloat {
        switch role {
        case .user, .system:
            return isFirstInMessage ? 6 : 2
        case .assistant:
            return assistantTopSpacing
        }
    }

    var outerBottomSpacing: CGFloat {
        switch role {
        case .user, .system:
            return isLastInMessage ? 6 : 2
        case .assistant:
            return isLastInMessage ? 8 : 0
        }
    }

    var outerVerticalPadding: CGFloat {
        outerTopSpacing + outerBottomSpacing
    }

    private var assistantTopSpacing: CGFloat {
        guard !isFirstInMessage, let previousKind else {
            return 6
        }

        if let level = Self.headingLevel(for: kind) {
            if Self.isHeading(previousKind) {
                return level <= 2 ? 10 : 8
            }
            if Self.isLargeBlock(previousKind) {
                return level <= 2 ? 14 : 12
            }
            return level <= 2 ? 16 : 12
        }

        if Self.isLargeBlock(kind) {
            return Self.isHeading(previousKind) ? 8 : 10
        }

        if Self.isLargeBlock(previousKind) {
            return 10
        }

        if Self.isHeading(previousKind) {
            return 6
        }

        if case .quote = kind {
            return 6
        }

        return 4
    }

    private static func headingLevel(for kind: Kind) -> Int? {
        if case .heading(let level) = kind {
            return level
        }
        return nil
    }

    private static func isHeading(_ kind: Kind) -> Bool {
        headingLevel(for: kind) != nil
    }

    private static func isLargeBlock(_ kind: Kind) -> Bool {
        switch kind {
        case .table, .code, .image, .reasoning:
            return true
        default:
            return false
        }
    }
}

enum MarkdownBlockWriter {
    private static let maxMarkdownBlockCharacters = 900
    private static let maxCodeBlockCharacters = 1_800

    static func append(_ delta: String, to blocks: inout [MessageBlock]) {
        guard !delta.isEmpty else { return }
        ensureActiveMarkdownBlock(in: &blocks)
        blocks[blocks.count - 1].append(delta)
        normalizeTail(in: &blocks, forceComplete: false)
    }

    static func finalize(_ blocks: inout [MessageBlock]) {
        guard !blocks.isEmpty else { return }
        normalizeTail(in: &blocks, forceComplete: true)
        for index in blocks.indices {
            blocks[index].isComplete = true
            blocks[index].version &+= 1
        }
    }

    static func blocks(from fullText: String, isComplete: Bool) -> [MessageBlock] {
        var blocks: [MessageBlock] = []
        append(fullText, to: &blocks)
        if isComplete {
            finalize(&blocks)
        }
        return blocks
    }

    private static func ensureActiveMarkdownBlock(in blocks: inout [MessageBlock]) {
        guard let last = blocks.last else {
            blocks.append(MessageBlock(kind: .markdown, text: "", isComplete: false))
            return
        }

        if last.isComplete {
            blocks.append(MessageBlock(kind: .markdown, text: "", isComplete: false))
        }
    }

    private static func normalizeTail(in blocks: inout [MessageBlock], forceComplete: Bool) {
        var madeProgress = true
        while madeProgress {
            madeProgress = false

            guard let lastIndex = blocks.indices.last else { return }
            switch blocks[lastIndex].kind {
            case .markdown:
                madeProgress = splitMarkdownTail(in: &blocks, at: lastIndex, forceComplete: forceComplete)
            case .code:
                madeProgress = splitCodeTail(in: &blocks, at: lastIndex, forceComplete: forceComplete)
            case .image:
                blocks[lastIndex].isComplete = true
            }
        }

        splitOversizedTail(in: &blocks, forceComplete: forceComplete)
    }

    private static func splitMarkdownTail(
        in blocks: inout [MessageBlock],
        at index: Int,
        forceComplete: Bool
    ) -> Bool {
        let text = blocks[index].text
        let imageMatch = firstMarkdownImage(in: text)
        let fenceRange = text.range(of: "```")
        if let fenceRange {
            let shouldPreferFence = imageMatch.map { fenceRange.lowerBound <= $0.fullRange.lowerBound } ?? true
            if shouldPreferFence,
               let lineEnd = text[fenceRange.upperBound...].firstIndex(of: "\n") {
                let prefix = String(text[..<fenceRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                let language = String(text[fenceRange.upperBound..<lineEnd])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let codeAndSuffix = String(text[text.index(after: lineEnd)...])

                blocks.remove(at: index)
                if !prefix.isEmpty {
                    blocks.insert(MessageBlock(kind: .markdown, text: prefix, isComplete: true), at: index)
                }

                let insertIndex = index + (prefix.isEmpty ? 0 : 1)
                if let closingRange = codeAndSuffix.range(of: "\n```") ?? codeAndSuffix.range(of: "```") {
                    let code = String(codeAndSuffix[..<closingRange.lowerBound]).trimmingCharacters(in: .newlines)
                    let suffixStart = closingFenceLineEnd(in: codeAndSuffix, closingRange: closingRange)
                    let suffix = String(codeAndSuffix[suffixStart...]).trimmingCharacters(in: .whitespacesAndNewlines)
                    blocks.insert(
                        MessageBlock(kind: .code(language: language.isEmpty ? nil : language), text: code, isComplete: true),
                        at: insertIndex
                    )
                    if !suffix.isEmpty {
                        blocks.insert(MessageBlock(kind: .markdown, text: suffix, isComplete: forceComplete), at: insertIndex + 1)
                    }
                } else {
                    blocks.insert(
                        MessageBlock(kind: .code(language: language.isEmpty ? nil : language), text: codeAndSuffix, isComplete: false),
                        at: insertIndex
                    )
                }
                return true
            }
        }

        if let imageMatch {
            let prefix = String(text[..<imageMatch.fullRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            let suffix = String(text[imageMatch.fullRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)

            blocks.remove(at: index)
            if !prefix.isEmpty {
                blocks.insert(MessageBlock(kind: .markdown, text: prefix, isComplete: true), at: index)
            }

            let insertIndex = index + (prefix.isEmpty ? 0 : 1)
            blocks.insert(
                MessageBlock(
                    kind: .image(url: imageMatch.url, alt: imageMatch.alt.isEmpty ? nil : imageMatch.alt),
                    text: imageMatch.alt,
                    isComplete: true
                ),
                at: insertIndex
            )
            if !suffix.isEmpty {
                blocks.insert(MessageBlock(kind: .markdown, text: suffix, isComplete: forceComplete), at: insertIndex + 1)
            }
            return true
        }

        return sealMarkdownTailIfNeeded(in: &blocks, at: index, forceComplete: forceComplete)
    }

    private static func splitCodeTail(
        in blocks: inout [MessageBlock],
        at index: Int,
        forceComplete: Bool
    ) -> Bool {
        let text = blocks[index].text
        guard let closingRange = text.range(of: "\n```") ?? text.range(of: "```") else {
            if recoverMarkdownSuffixFromPlainCodeBlock(in: &blocks, at: index, forceComplete: forceComplete) {
                return true
            }
            if forceComplete {
                blocks[index].isComplete = true
            }
            return false
        }

        let code = String(text[..<closingRange.lowerBound]).trimmingCharacters(in: .newlines)
        let suffixStart = closingFenceLineEnd(in: text, closingRange: closingRange)
        let suffix = String(text[suffixStart...]).trimmingCharacters(in: .whitespacesAndNewlines)

        blocks[index].replaceText(code, isComplete: true)
        if !suffix.isEmpty {
            blocks.insert(MessageBlock(kind: .markdown, text: suffix, isComplete: forceComplete), at: index + 1)
        }
        return true
    }

    private static func sealMarkdownTailIfNeeded(
        in blocks: inout [MessageBlock],
        at index: Int,
        forceComplete: Bool
    ) -> Bool {
        let text = blocks[index].text
        if forceComplete {
            blocks[index].isComplete = true
            return false
        }

        guard text.utf16.count >= maxMarkdownBlockCharacters else { return false }

        if let splitIndex = preferredStreamingSplitIndex(in: text, hardLimit: maxMarkdownBlockCharacters) {
            let prefix = String(text[..<splitIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
            let suffix = String(text[splitIndex...]).trimmingCharacters(in: .whitespacesAndNewlines)

            blocks[index].replaceText(prefix, isComplete: true)
            if !suffix.isEmpty {
                blocks.insert(MessageBlock(kind: .markdown, text: suffix, isComplete: false), at: index + 1)
            }
            return true
        }

        return false
    }

    private static func splitOversizedTail(in blocks: inout [MessageBlock], forceComplete: Bool) {
        guard let index = blocks.indices.last, !blocks[index].isComplete else { return }

        let limit: Int
        switch blocks[index].kind {
        case .markdown:
            limit = maxMarkdownBlockCharacters * 2
        case .code:
            limit = maxCodeBlockCharacters
        case .image:
            return
        }

        guard blocks[index].text.utf16.count > limit else { return }
        let text = blocks[index].text
        let split = text.index(text.startIndex, offsetBy: limit, limitedBy: text.endIndex) ?? text.endIndex
        let prefix = String(text[..<split])
        let suffix = String(text[split...])
        let kind = blocks[index].kind
        blocks[index].replaceText(prefix, isComplete: true)
        if !suffix.isEmpty {
            blocks.insert(MessageBlock(kind: kind, text: suffix, isComplete: forceComplete), at: index + 1)
        }
    }

    private static func preferredStreamingSplitIndex(in text: String, hardLimit: Int) -> String.Index? {
        let searchEnd = text.index(text.startIndex, offsetBy: hardLimit, limitedBy: text.endIndex) ?? text.endIndex
        var index = searchEnd
        var best: String.Index?

        while index > text.startIndex {
            let previous = text.index(before: index)
            let character = text[previous]
            if character == "\n" {
                best = index
                if previous > text.startIndex {
                    let beforePrevious = text.index(before: previous)
                    if text[beforePrevious] == "\n" {
                        return index
                    }
                }
            }
            index = previous
        }

        return best
    }

    private static func closingFenceLineEnd(
        in text: String,
        closingRange: Range<String.Index>
    ) -> String.Index {
        if let nextLine = text[closingRange.upperBound...].firstIndex(of: "\n") {
            return text.index(after: nextLine)
        }
        return closingRange.upperBound
    }

    private static func recoverMarkdownSuffixFromPlainCodeBlock(
        in blocks: inout [MessageBlock],
        at index: Int,
        forceComplete: Bool
    ) -> Bool {
        guard forceComplete else { return false }
        guard case .code(let language) = blocks[index].kind,
              language == nil
        else {
            return false
        }

        let text = blocks[index].text
        guard let headingRange = firstRecoverableMarkdownHeadingLine(in: text) else {
            return false
        }

        if headingRange.lowerBound == text.startIndex {
            blocks[index].kind = .markdown
            blocks[index].isComplete = forceComplete
            blocks[index].version &+= 1
            return true
        }

        let code = String(text[..<headingRange.lowerBound]).trimmingCharacters(in: .newlines)
        let suffix = String(text[headingRange.lowerBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty,
              !suffix.isEmpty,
              looksLikeRecoveredMarkdownSuffix(suffix)
        else { return false }

        blocks[index].replaceText(code, isComplete: true)
        blocks.insert(MessageBlock(kind: .markdown, text: suffix, isComplete: forceComplete), at: index + 1)
        return true
    }

    private static func firstRecoverableMarkdownHeadingLine(in text: String) -> Range<String.Index>? {
        var searchStart = text.startIndex

        while searchStart < text.endIndex {
            let lineEnd = text[searchStart...].firstIndex(of: "\n") ?? text.endIndex
            let line = String(text[searchStart..<lineEnd])
            if isRecoverableMarkdownHeadingLine(line) {
                return searchStart..<lineEnd
            }
            guard lineEnd < text.endIndex else { break }
            searchStart = text.index(after: lineEnd)
        }

        return nil
    }

    private static func isRecoverableMarkdownHeadingLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let candidate: String
        if trimmed.hasPrefix("---") {
            candidate = String(trimmed.drop { $0 == "-" }).trimmingCharacters(in: .whitespaces)
        } else {
            candidate = trimmed
        }

        guard candidate.hasPrefix("##") else { return false }
        let marker = candidate.prefix { $0 == "#" }
        guard (2...6).contains(marker.count),
              candidate.count > marker.count
        else {
            return false
        }

        let bodyStart = candidate.index(candidate.startIndex, offsetBy: marker.count)
        return candidate[bodyStart].isWhitespace
    }

    private static func looksLikeRecoveredMarkdownSuffix(_ suffix: String) -> Bool {
        let lines = suffix.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.first.map(isRecoverableMarkdownHeadingLine) == true else { return false }

        for line in lines.dropFirst().prefix(8) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            if isRecoverableMarkdownHeadingLine(trimmed)
                || trimmed.hasPrefix("|")
                || trimmed.hasPrefix("- ")
                || trimmed.hasPrefix("* ")
                || trimmed.hasPrefix("> ")
                || trimmed.hasPrefix("```")
                || trimmed.hasPrefix("![") {
                return true
            }

            if !looksLikeSourceCodeLine(trimmed),
               trimmed.rangeOfCharacter(from: CharacterSet(charactersIn: "，。；：,.!?")) != nil {
                return true
            }
        }

        return false
    }

    private static func looksLikeSourceCodeLine(_ line: String) -> Bool {
        let sourcePrefixes = ["//", "#!", "/*", "* ", "*/", "let ", "var ", "func ", "class ", "struct ", "import ", "echo ", "if ", "for ", "while "]
        if sourcePrefixes.contains(where: { line.hasPrefix($0) }) {
            return true
        }

        return line.contains("{")
            || line.contains("}")
            || line.contains("=")
            || line.hasSuffix(";")
    }

    private struct MarkdownImageMatch {
        let fullRange: Range<String.Index>
        let alt: String
        let url: String
    }

    private static func firstMarkdownImage(in text: String) -> MarkdownImageMatch? {
        guard let markerRange = text.range(of: "![") else { return nil }
        guard let altEnd = text[markerRange.upperBound...].firstIndex(of: "]") else { return nil }
        let parenStartCandidate = text.index(after: altEnd)
        guard parenStartCandidate < text.endIndex, text[parenStartCandidate] == "(" else { return nil }
        guard let parenEnd = text[text.index(after: parenStartCandidate)...].firstIndex(of: ")") else { return nil }

        let alt = String(text[markerRange.upperBound..<altEnd])
        let url = String(text[text.index(after: parenStartCandidate)..<parenEnd])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard URL(string: url) != nil else { return nil }

        return MarkdownImageMatch(
            fullRange: markerRange.lowerBound..<text.index(after: parenEnd),
            alt: alt,
            url: url
        )
    }
}

enum ThinkTagContentRouter {
    private static let openTag = "<think>"
    private static let closeTag = "</think>"

    static func append(_ delta: String, to message: inout Message) {
        guard !delta.isEmpty else { return }

        let combined = message.thinkRoutingState.pendingText + delta
        message.thinkRoutingState.pendingText = ""

        var remainder = combined[combined.startIndex...]
        while !remainder.isEmpty {
            if message.thinkRoutingState.isInsideThink {
                if let closeRange = remainder.range(of: closeTag) {
                    let reasoning = String(remainder[..<closeRange.lowerBound])
                    appendReasoning(reasoning, to: &message)
                    message.thinkRoutingState.isInsideThink = false
                    remainder = remainder[closeRange.upperBound...]
                } else {
                    let safe = splitSafePrefix(from: String(remainder), preservingPossibleSuffixOf: closeTag)
                    appendReasoning(safe.prefix, to: &message)
                    message.thinkRoutingState.pendingText = safe.pending
                    return
                }
            } else {
                if let openRange = remainder.range(of: openTag) {
                    let content = String(remainder[..<openRange.lowerBound])
                    appendContent(content, to: &message)
                    message.thinkRoutingState.isInsideThink = true
                    remainder = remainder[openRange.upperBound...]
                } else {
                    let safe = splitSafePrefix(from: String(remainder), preservingPossibleSuffixOf: openTag)
                    appendContent(safe.prefix, to: &message)
                    message.thinkRoutingState.pendingText = safe.pending
                    return
                }
            }
        }
    }

    static func finalize(_ message: inout Message) {
        if !message.thinkRoutingState.pendingText.isEmpty {
            if message.thinkRoutingState.isInsideThink {
                appendReasoning(message.thinkRoutingState.pendingText, to: &message)
            } else {
                appendContent(message.thinkRoutingState.pendingText, to: &message)
            }
            message.thinkRoutingState.pendingText = ""
        }
        message.thinkRoutingState.isInsideThink = false
    }

    private static func appendContent(_ text: String, to message: inout Message) {
        guard !text.isEmpty else { return }
        MarkdownBlockWriter.append(text, to: &message.blocks)
    }

    private static func appendReasoning(_ text: String, to message: inout Message) {
        guard !text.isEmpty else { return }
        MarkdownBlockWriter.append(text, to: &message.reasoningBlocks)
    }

    private static func splitSafePrefix(
        from text: String,
        preservingPossibleSuffixOf marker: String
    ) -> (prefix: String, pending: String) {
        let maxPendingLength = max(0, marker.count - 1)
        guard !text.isEmpty, maxPendingLength > 0 else {
            return (text, "")
        }

        let pendingLength = min(maxPendingLength, text.count)
        for length in stride(from: pendingLength, through: 1, by: -1) {
            let suffix = String(text.suffix(length))
            if marker.hasPrefix(suffix) {
                let splitIndex = text.index(text.endIndex, offsetBy: -length)
                return (String(text[..<splitIndex]), suffix)
            }
        }

        return (text, "")
    }
}
