import UIKit

private struct ChatItemDraft {
    let blockKey: String
    let kind: ChatItem.Kind
    let text: String
    let copyText: String
    let layoutVersion: Int
    let rendersMarkdown: Bool
}

private struct ContentDraftCacheKey: Hashable {
    let keyPrefix: String
    let blockID: UUID
    let blockIndex: Int
    let blockKind: MessageBlockKind
    let blockVersion: Int
    let forceMarkdown: Bool
    let forcedKind: ChatItem.Kind?
}

private struct MarkdownProjectionCacheKey: Hashable {
    let blockID: UUID
    let blockVersion: Int
}

final class ChatViewModel {

    // MARK: - State
    private(set) var conversations: [Conversation]
    private(set) var currentConversationID: UUID
    private var currentConversationIndex: Int
    private let repository: ConversationRepository
    private let heightCache: MessageHeightCache
    private var conversationIndexByID: [UUID: Int] = [:]
    private var currentMessageIndexByID: [UUID: Int] = [:]
    private var messageItemsByID: [UUID: [ChatItem]] = [:]
    private var renderedItems: [ChatItem] = []
    private var currentItemIndexByID: [ChatItem.ID: Int] = [:]
    private var contentDraftCache: [ContentDraftCacheKey: [ChatItemDraft]] = [:]
    private var markdownProjectionCache: [MarkdownProjectionCacheKey: [ProjectedMarkdownBlock]] = [:]

    var messages: [Message] {
        currentConversation?.messages ?? []
    }

    var chatItems: [ChatItem] {
        renderedItems
    }

    var currentConversationTitle: String {
        currentConversation?.title ?? "新对话"
    }

    // MARK: - Lifecycle
    init(repository: ConversationRepository, heightCache: MessageHeightCache = MessageHeightCache()) {
        self.repository = repository
        self.conversations = repository.loadConversations().sorted(by: { $0.updatedAt > $1.updatedAt })
        if conversations.isEmpty {
            conversations = [Conversation()]
        }
        self.currentConversationID = conversations[0].id
        self.currentConversationIndex = 0
        self.heightCache = heightCache
        rebuildConversationIndex()
        rebuildCurrentMessageIndex()
        rebuildCurrentChatItems()
    }
}

// MARK: - Message Query
extension ChatViewModel {
    func message(at indexPath: IndexPath) -> Message {
        messages[indexPath.item]
    }

    func message(id: UUID) -> Message? {
        guard
            let index = currentMessageIndexByID[id],
            let conversation = currentConversation,
            conversation.messages.indices.contains(index)
        else {
            return nil
        }

        return conversation.messages[index]
    }

    func chatItem(at indexPath: IndexPath) -> ChatItem? {
        guard renderedItems.indices.contains(indexPath.item) else { return nil }
        return renderedItems[indexPath.item]
    }

    func chatItem(id: ChatItem.ID) -> ChatItem? {
        guard
            let index = currentItemIndexByID[id],
            renderedItems.indices.contains(index)
        else {
            return nil
        }

        return renderedItems[index]
    }

    func itemIDs(for messageID: UUID) -> [ChatItem.ID] {
        messageItemsByID[messageID]?.map(\.id) ?? []
    }

    func copyTextForMessage(id: UUID) -> String? {
        guard let message = message(id: id) else { return nil }

        var parts: [String] = []
        let reasoning = message.reasoningText
        if !reasoning.isEmpty {
            parts.append(reasoning)
        }

        let content = message.contentText
        if !content.isEmpty {
            parts.append(content)
        }

        return parts.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func latestContinuableAssistantID() -> UUID? {
        for message in messages.reversed() {
            if message.role == .assistant, message.status == .needsContinuation {
                return message.id
            }
            if message.role == .user {
                return nil
            }
        }
        return nil
    }
}

// MARK: - Conversation Operations
extension ChatViewModel {
    func conversationSummaries() -> [ConversationSummary] {
        conversations
            .sorted(by: { $0.updatedAt > $1.updatedAt })
            .map { conversation in
                ConversationSummary(
                    id: conversation.id,
                    title: conversation.title,
                    preview: makePreview(for: conversation),
                    updatedAt: conversation.updatedAt,
                    isSelected: conversation.id == currentConversationID
                )
            }
    }

    @discardableResult
    func startNewConversation() -> Conversation {
        let conversation = Conversation()
        conversations.insert(conversation, at: 0)
        currentConversationID = conversation.id
        currentConversationIndex = 0
        rebuildConversationIndex()
        rebuildCurrentMessageIndex()
        rebuildCurrentChatItems()
        invalidateAllHeights()
        save()
        return conversation
    }

    @discardableResult
    func selectConversation(id: UUID) -> Bool {
        guard let index = conversationIndexByID[id] else { return false }
        currentConversationID = id
        currentConversationIndex = index
        rebuildCurrentMessageIndex()
        rebuildCurrentChatItems()
        invalidateAllHeights()
        return true
    }

    func chatProviderRequest(systemPrompt: String) -> ChatProviderRequest {
        var requestMessages: [ChatProviderMessage] = []

        for message in messages {
            guard let role = apiRole(from: message.role),
                  let content = normalizedHistoryContent(from: message),
                  !content.isEmpty else { continue }
            requestMessages.append(ChatProviderMessage(role: role, content: content))
        }

        return ChatProviderRequest(systemPrompt: systemPrompt, messages: requestMessages)
    }

    func save() {
        repository.saveConversations(conversations)
    }
}

// MARK: - Message Mutation
extension ChatViewModel {
    func appendMessage(_ message: Message, persist: Bool = true) {
        var appendedIndex: Int?
        mutateCurrentConversation(persist: persist, touchUpdatedAt: persist) { conversation in
            conversation.messages.append(message)
            appendedIndex = conversation.messages.count - 1
            if message.role == .user, conversation.title == "新对话" {
                conversation.title = makeTitle(from: message.contentText)
            }
        }
        if let appendedIndex {
            currentMessageIndexByID[message.id] = appendedIndex
        }
        cacheItems(for: message)
        rebuildRenderedItemsFromMessageCache()
    }

    @discardableResult
    func updateMessage(
        id: UUID,
        persist: Bool = false,
        mutate: (inout Message) -> Void
    ) -> Bool {
        var updated = false

        mutateCurrentConversation(persist: persist, touchUpdatedAt: persist) { conversation in
            guard let idx = currentMessageIndexByID[id] else { return }
            mutate(&conversation.messages[idx])
            updated = true
        }

        guard updated else { return false }
        if let message = message(id: id) {
            let items = cacheItems(for: message)
            if !replaceRenderedItems(for: message.id, with: items) {
                rebuildRenderedItemsFromMessageCache()
            }
        } else {
            rebuildRenderedItemsFromMessageCache()
        }
        return true
    }

    func appendContent(to id: UUID, delta: String, persist: Bool = false) {
        _ = updateMessage(id: id, persist: persist) { message in
            ThinkTagContentRouter.append(delta, to: &message)
            message.advanceLayoutVersion()
        }
    }

    func appendReasoning(to id: UUID, delta: String, persist: Bool = false) {
        _ = updateMessage(id: id, persist: persist) { message in
            MarkdownBlockWriter.append(delta, to: &message.reasoningBlocks)
            message.advanceLayoutVersion()
        }
    }

    func appendStreamDelta(
        to id: UUID,
        contentDelta: String?,
        reasoningDelta: String?,
        persist: Bool = false
    ) {
        guard contentDelta?.isEmpty == false || reasoningDelta?.isEmpty == false else { return }

        _ = updateMessage(id: id, persist: persist) { message in
            if let reasoningDelta, !reasoningDelta.isEmpty {
                MarkdownBlockWriter.append(reasoningDelta, to: &message.reasoningBlocks)
            }
            if let contentDelta, !contentDelta.isEmpty {
                ThinkTagContentRouter.append(contentDelta, to: &message)
            }
            if !message.status.isTerminal, message.status != .streaming {
                message.status = .streaming
            }
            message.advanceLayoutVersion()
        }
    }

    func setContent(for id: UUID, text: String, persist: Bool = true) {
        _ = updateMessage(id: id, persist: persist) { message in
            message.blocks = []
            message.reasoningBlocks = []
            message.thinkRoutingState = ThinkRoutingState()
            ThinkTagContentRouter.append(text, to: &message)
            ThinkTagContentRouter.finalize(&message)
            MarkdownBlockWriter.finalize(&message.blocks)
            MarkdownBlockWriter.finalize(&message.reasoningBlocks)
            message.advanceLayoutVersion()
        }
    }

    func setToolResult(
        for id: UUID,
        result: ToolExecutionResult,
        persist: Bool = true
    ) {
        _ = updateMessage(id: id, persist: persist) { message in
            message.blocks = result.blocks
            message.reasoningBlocks = []
            message.thinkRoutingState = ThinkRoutingState()
            message.toolResult = ToolResultRecord(
                toolName: result.toolName,
                ok: result.ok,
                displayText: result.displayText,
                structuredData: result.structuredData
            )
            message.status = result.ok ? .success : .failed(result.displayText)
            message.advanceLayoutVersion()
        }
    }

    @discardableResult
    func toggleReasoning(for id: UUID) -> Bool {
        updateMessage(id: id, persist: false) { message in
            message.isReasoningExpanded.toggle()
            message.advanceLayoutVersion()
        }
    }

    func setStatus(for id: UUID, status: Message.Status, persist: Bool = true) {
        if let message = message(id: id), message.status == status, !status.isTerminal {
            return
        }

        _ = updateMessage(id: id, persist: persist) { message in
            message.status = status
            if status.isTerminal {
                ThinkTagContentRouter.finalize(&message)
                MarkdownBlockWriter.finalize(&message.blocks)
                MarkdownBlockWriter.finalize(&message.reasoningBlocks)
            }
            message.advanceLayoutVersion()
        }
    }

    @discardableResult
    func incrementMaxTokenHitCount(for id: UUID) -> Int {
        var count = 0
        _ = updateMessage(id: id, persist: false) { message in
            count = (message.maxTokenHitCount ?? 0) + 1
            message.maxTokenHitCount = count
        }
        return count
    }
}

// MARK: - Height Cache Operations
extension ChatViewModel {
    func cachedHeight(for item: ChatItem, width: CGFloat, displayScale: CGFloat) -> CGFloat? {
        heightCache.cachedHeight(
            for: item.id.cacheKey,
            width: width,
            displayScale: displayScale,
            layoutVersion: item.layoutVersion
        )
    }

    func cacheHeight(_ height: CGFloat, for item: ChatItem, width: CGFloat, displayScale: CGFloat) {
        heightCache.cacheHeight(
            height,
            for: item.id.cacheKey,
            width: width,
            displayScale: displayScale,
            layoutVersion: item.layoutVersion
        )
    }

    func invalidateHeight(for item: ChatItem, width: CGFloat, displayScale: CGFloat) {
        heightCache.invalidateHeight(
            for: item.id.cacheKey,
            width: width,
            displayScale: displayScale,
            layoutVersion: item.layoutVersion
        )
    }

    func invalidateAllHeights() {
        heightCache.invalidateAll()
    }

    func pruneHeightCache() {
        let validItemKeys = Set(renderedItems.map(\.id.cacheKey))
        heightCache.prune(validItemKeys: validItemKeys)
    }
}

// MARK: - Render Projection
private extension ChatViewModel {
    func rebuildCurrentChatItems() {
        messageItemsByID = Dictionary(
            uniqueKeysWithValues: messages.map { message in
                (message.id, makeChatItems(for: message))
            }
        )
        rebuildRenderedItemsFromMessageCache()
    }

    func rebuildItems(for message: Message) {
        cacheItems(for: message)
    }

    @discardableResult
    func cacheItems(for message: Message) -> [ChatItem] {
        let items = makeChatItems(for: message)
        messageItemsByID[message.id] = items
        return items
    }

    func rebuildRenderedItemsFromMessageCache() {
        renderedItems = messages.flatMap { messageItemsByID[$0.id] ?? [] }
        currentItemIndexByID = Dictionary(
            uniqueKeysWithValues: renderedItems.enumerated().map { ($1.id, $0) }
        )
        pruneRenderCachesToCurrentConversation()
    }

    func replaceRenderedItems(for messageID: UUID, with items: [ChatItem]) -> Bool {
        guard
            let firstIndex = renderedItems.firstIndex(where: { $0.messageID == messageID }),
            let lastIndex = renderedItems.lastIndex(where: { $0.messageID == messageID }),
            firstIndex <= lastIndex
        else {
            return false
        }

        renderedItems.replaceSubrange(firstIndex...lastIndex, with: items)
        currentItemIndexByID = Dictionary(
            uniqueKeysWithValues: renderedItems.enumerated().map { ($1.id, $0) }
        )
        pruneRenderCachesToCurrentConversation()
        return true
    }

    func makeChatItems(for message: Message) -> [ChatItem] {
        let drafts: [ChatItemDraft]

        switch message.role {
        case .user, .system:
            drafts = makeContentDrafts(
                from: message.blocks.isEmpty ? [MessageBlock(kind: .markdown, text: "...", isComplete: true)] : message.blocks,
                keyPrefix: message.role == .user ? "user" : "system",
                role: message.role,
                forceMarkdown: message.role != .user
            )
        case .assistant:
            drafts = makeAssistantDrafts(for: message)
        }

        return drafts.enumerated().map { index, draft in
            ChatItem(
                id: ChatItem.ID(messageID: message.id, blockKey: draft.blockKey),
                messageID: message.id,
                role: message.role,
                kind: draft.kind,
                text: draft.text,
                copyText: draft.copyText,
                layoutVersion: draft.layoutVersion,
                rendersMarkdown: draft.rendersMarkdown,
                previousKind: index > 0 ? drafts[index - 1].kind : nil,
                nextKind: index + 1 < drafts.count ? drafts[index + 1].kind : nil,
                isFirstInMessage: index == 0,
                isLastInMessage: index == drafts.count - 1
            )
        }
    }

    func makeAssistantDrafts(for message: Message) -> [ChatItemDraft] {
        var drafts: [ChatItemDraft] = []

        if !message.reasoningBlocks.isEmpty {
            drafts.append(
                ChatItemDraft(
                    blockKey: "reasoning-toggle",
                    kind: .control(action: .toggleReasoning),
                    text: message.isReasoningExpanded ? "隐藏思考过程" : "显示思考过程",
                    copyText: "",
                    layoutVersion: message.layoutVersion,
                    rendersMarkdown: false
                )
            )

            if message.isReasoningExpanded {
                drafts.append(
                    contentsOf: makeContentDrafts(
                        from: message.reasoningBlocks,
                        keyPrefix: "reasoning",
                        role: .assistant,
                        forceMarkdown: true,
                        forcedKind: .reasoning
                    )
                )
            }
        }

        if message.blocks.isEmpty {
            drafts.append(
                ChatItemDraft(
                    blockKey: "response-placeholder",
                    kind: .markdown,
                    text: "...",
                    copyText: "",
                    layoutVersion: message.layoutVersion,
                    rendersMarkdown: false
                )
            )
        } else {
            drafts.append(
                contentsOf: makeContentDrafts(
                    from: message.blocks,
                    keyPrefix: "response",
                    role: .assistant,
                    forceMarkdown: true
                )
            )
        }

        if let statusDraft = makeStatusDraft(for: message) {
            drafts.append(statusDraft)
        }

        return drafts
    }

    func makeContentDrafts(
        from blocks: [MessageBlock],
        keyPrefix: String,
        role: Role,
        forceMarkdown: Bool,
        forcedKind: ChatItem.Kind? = nil
    ) -> [ChatItemDraft] {
        var drafts: [ChatItemDraft] = []
        drafts.reserveCapacity(blocks.count)

        for (index, block) in blocks.enumerated() {
            drafts.append(
                contentsOf: cachedDrafts(
                    for: block,
                    index: index,
                    keyPrefix: keyPrefix,
                    forceMarkdown: forceMarkdown,
                    forcedKind: forcedKind
                ).filter(isRenderableDraft)
            )
        }

        return drafts
    }

    func makeStatusDraft(for message: Message) -> ChatItemDraft? {
        switch message.status {
        case .pending where message.blocks.isEmpty:
            return ChatItemDraft(
                blockKey: "status",
                kind: .status,
                text: "正在准备回复...",
                copyText: "",
                layoutVersion: message.layoutVersion,
                rendersMarkdown: false
            )
        case .canceled:
            return ChatItemDraft(
                blockKey: "status",
                kind: .status,
                text: "已停止生成",
                copyText: "",
                layoutVersion: message.layoutVersion,
                rendersMarkdown: false
            )
        case .failed(let reason) where message.blocks.isEmpty:
            return ChatItemDraft(
                blockKey: "status",
                kind: .status,
                text: "生成失败：\(reason)",
                copyText: "",
                layoutVersion: message.layoutVersion,
                rendersMarkdown: false
            )
        case .needsContinuation:
            return ChatItemDraft(
                blockKey: "continue-generation",
                kind: .control(action: .continueGeneration),
                text: "继续生成",
                copyText: "",
                layoutVersion: message.layoutVersion,
                rendersMarkdown: false
            )
        default:
            return nil
        }
    }

    func cachedDrafts(
        for block: MessageBlock,
        index: Int,
        keyPrefix: String,
        forceMarkdown: Bool,
        forcedKind: ChatItem.Kind?
    ) -> [ChatItemDraft] {
        let cacheKey = ContentDraftCacheKey(
            keyPrefix: keyPrefix,
            blockID: block.id,
            blockIndex: index,
            blockKind: block.kind,
            blockVersion: block.version,
            forceMarkdown: forceMarkdown,
            forcedKind: forcedKind
        )

        if let cached = contentDraftCache[cacheKey] {
            return cached
        }

        let drafts = makeDrafts(
            for: block,
            index: index,
            keyPrefix: keyPrefix,
            forceMarkdown: forceMarkdown,
            forcedKind: forcedKind
        )
        contentDraftCache[cacheKey] = drafts
        return drafts
    }

    func makeDrafts(
        for block: MessageBlock,
        index: Int,
        keyPrefix: String,
        forceMarkdown: Bool,
        forcedKind: ChatItem.Kind?
    ) -> [ChatItemDraft] {
        let key = "\(keyPrefix)-\(block.id.uuidString)-\(index)"
        let layoutVersion = block.version &* 31 &+ (block.isComplete ? 1 : 0)

        switch block.kind {
        case .markdown:
            if forceMarkdown, block.isComplete, forcedKind == nil {
                let projectedBlocks = cachedProjectedBlocks(for: block)
                if !projectedBlocks.isEmpty {
                    let drafts = projectedBlocks.enumerated().compactMap { projectedIndex, projected in
                        let draft = ChatItemDraft(
                            blockKey: "\(key)-\(projected.keySuffix)-\(projectedIndex)",
                            kind: projected.kind,
                            text: projected.text,
                            copyText: projected.copyText,
                            layoutVersion: block.version &* 31 &+ projectedIndex &* 7 &+ 1,
                            rendersMarkdown: true
                        )
                        return isRenderableDraft(draft) ? draft : nil
                    }
                    if !drafts.isEmpty {
                        return drafts
                    }
                }
            }

            guard hasRenderableText(block.text) else { return [] }
            return [
                ChatItemDraft(
                    blockKey: key,
                    kind: forcedKind ?? .markdown,
                    text: displayText(for: block.text),
                    copyText: block.text,
                    layoutVersion: layoutVersion,
                    rendersMarkdown: forceMarkdown && block.isComplete
                )
            ]
        case .code(let language):
            if language == nil,
               block.isComplete,
               let recoveredDrafts = recoverMarkdownDraftsFromPlainCodeBlock(
                block: block,
                key: key,
                layoutVersion: layoutVersion,
                forceMarkdown: forceMarkdown
               ) {
                return recoveredDrafts
            }

            let trimmedCode = block.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard hasRenderableText(trimmedCode) else { return [] }
            return [
                ChatItemDraft(
                    blockKey: key,
                    kind: .code(language: language),
                    text: trimmedCode,
                    copyText: block.text,
                    layoutVersion: layoutVersion,
                    rendersMarkdown: false
                )
            ]
        case .image(let url, let alt):
            return [
                ChatItemDraft(
                    blockKey: key,
                    kind: .image(url: url, alt: alt),
                    text: displayText(for: block.text),
                    copyText: "![\(alt ?? "")](\(url))",
                    layoutVersion: layoutVersion,
                    rendersMarkdown: false
                )
            ]
        }
    }

    func recoverMarkdownDraftsFromPlainCodeBlock(
        block: MessageBlock,
        key: String,
        layoutVersion: Int,
        forceMarkdown: Bool
    ) -> [ChatItemDraft]? {
        guard let headingRange = firstRecoverableMarkdownHeadingLine(in: block.text) else {
            return nil
        }

        let codePrefix = String(block.text[..<headingRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        let markdownSuffix = String(block.text[headingRange.lowerBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard hasRenderableText(markdownSuffix),
              looksLikeRecoveredMarkdownSuffix(markdownSuffix)
        else { return nil }

        var drafts: [ChatItemDraft] = []
        if hasRenderableText(codePrefix) {
            drafts.append(
                ChatItemDraft(
                    blockKey: "\(key)-recovered-code",
                    kind: .code(language: nil),
                    text: codePrefix,
                    copyText: codePrefix,
                    layoutVersion: layoutVersion,
                    rendersMarkdown: false
                )
            )
        }

        let projectedBlocks = MarkdownBlockProjector.project(markdownSuffix)
        if projectedBlocks.isEmpty {
            drafts.append(
                ChatItemDraft(
                    blockKey: "\(key)-recovered-markdown",
                    kind: .markdown,
                    text: displayText(for: markdownSuffix),
                    copyText: markdownSuffix,
                    layoutVersion: layoutVersion &+ 1,
                    rendersMarkdown: forceMarkdown
                )
            )
        } else {
            drafts.append(
                contentsOf: projectedBlocks.enumerated().compactMap { projectedIndex, projected in
                    let draft = ChatItemDraft(
                        blockKey: "\(key)-recovered-\(projected.keySuffix)-\(projectedIndex)",
                        kind: projected.kind,
                        text: projected.text,
                        copyText: projected.copyText,
                        layoutVersion: layoutVersion &+ projectedIndex &+ 1,
                        rendersMarkdown: forceMarkdown
                    )
                    return isRenderableDraft(draft) ? draft : nil
                }
            )
        }

        return drafts.isEmpty ? nil : drafts
    }

    func firstRecoverableMarkdownHeadingLine(in text: String) -> Range<String.Index>? {
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

    func isRecoverableMarkdownHeadingLine(_ line: String) -> Bool {
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

    func looksLikeRecoveredMarkdownSuffix(_ suffix: String) -> Bool {
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

    func looksLikeSourceCodeLine(_ line: String) -> Bool {
        let sourcePrefixes = ["//", "#!", "/*", "* ", "*/", "let ", "var ", "func ", "class ", "struct ", "import ", "echo ", "if ", "for ", "while "]
        if sourcePrefixes.contains(where: { line.hasPrefix($0) }) {
            return true
        }

        return line.contains("{")
            || line.contains("}")
            || line.contains("=")
            || line.hasSuffix(";")
    }

    func cachedProjectedBlocks(for block: MessageBlock) -> [ProjectedMarkdownBlock] {
        let cacheKey = MarkdownProjectionCacheKey(blockID: block.id, blockVersion: block.version)
        if let cached = markdownProjectionCache[cacheKey] {
            return cached
        }

        let projectedBlocks = MarkdownBlockProjector.project(block.text)
        markdownProjectionCache[cacheKey] = projectedBlocks
        return projectedBlocks
    }

    func displayText(for text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "..." : text
    }

    func isRenderableDraft(_ draft: ChatItemDraft) -> Bool {
        switch draft.kind {
        case .image, .control, .status:
            return true
        case .markdown, .heading, .quote, .list, .table, .code, .reasoning:
            return hasRenderableText(draft.text)
        }
    }

    func hasRenderableText(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            guard !CharacterSet.whitespacesAndNewlines.contains(scalar),
                  !CharacterSet.controlCharacters.contains(scalar)
            else {
                return false
            }

            switch scalar.value {
            case 0x00AD, // soft hyphen
                 0x034F, // combining grapheme joiner
                 0x061C, // Arabic letter mark
                 0x180E, // Mongolian vowel separator
                 0x200B...0x200F, // zero-width and bidi marks
                 0x202A...0x202E, // bidi embeddings and overrides
                 0x2060...0x206F, // word joiner and invisible formatting
                 0xFEFF: // zero-width no-break space
                return false
            default:
                return true
            }
        }
    }

    func pruneRenderCachesToCurrentConversation() {
        var validBlockVersions = Set<MarkdownProjectionCacheKey>()
        for message in messages {
            for block in message.blocks {
                validBlockVersions.insert(MarkdownProjectionCacheKey(blockID: block.id, blockVersion: block.version))
            }
            for block in message.reasoningBlocks {
                validBlockVersions.insert(MarkdownProjectionCacheKey(blockID: block.id, blockVersion: block.version))
            }
        }

        markdownProjectionCache = markdownProjectionCache.filter { validBlockVersions.contains($0.key) }
        contentDraftCache = contentDraftCache.filter { key, _ in
            validBlockVersions.contains(
                MarkdownProjectionCacheKey(blockID: key.blockID, blockVersion: key.blockVersion)
            )
        }
    }
}

// MARK: - Helpers
private extension ChatViewModel {
    var currentConversation: Conversation? {
        guard conversations.indices.contains(currentConversationIndex) else { return nil }
        let conversation = conversations[currentConversationIndex]
        guard conversation.id == currentConversationID else { return nil }
        return conversation
    }

    func makeTitle(from content: String) -> String {
        let trimmed = content
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        guard !trimmed.isEmpty else { return "新对话" }
        return String(trimmed.prefix(20))
    }

    func makePreview(for conversation: Conversation) -> String {
        for message in conversation.messages.reversed() {
            guard let normalized = normalizedHistoryContent(from: message), !normalized.isEmpty else { continue }
            return normalized.replacingOccurrences(of: "\n", with: " ")
        }
        return "还没有消息"
    }

    func apiRole(from role: Role) -> ChatProviderMessage.Role? {
        switch role {
        case .user:
            return .user
        case .assistant:
            return .assistant
        case .system:
            return nil
        }
    }

    func normalizedHistoryContent(from message: Message) -> String? {
        let content = message.contentText
            .removingThinkTagContent()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return content.isEmpty ? nil : content
    }

    func mutateCurrentConversation(
        persist: Bool,
        touchUpdatedAt: Bool = true,
        mutate: (inout Conversation) -> Void
    ) {
        guard let idx = resolveCurrentConversationIndex() else { return }
        mutate(&conversations[idx])
        if touchUpdatedAt {
            conversations[idx].updatedAt = Date()
            conversations.sort(by: { $0.updatedAt > $1.updatedAt })
            refreshCurrentConversationIndex()
        }
        if persist {
            save()
        }
    }

    @discardableResult
    func resolveCurrentConversationIndex() -> Int? {
        if conversations.indices.contains(currentConversationIndex),
           conversations[currentConversationIndex].id == currentConversationID {
            return currentConversationIndex
        }

        refreshCurrentConversationIndex()
        guard conversations.indices.contains(currentConversationIndex) else { return nil }
        return currentConversationIndex
    }

    func refreshCurrentConversationIndex() {
        rebuildConversationIndex()
        if let index = conversationIndexByID[currentConversationID] {
            currentConversationIndex = index
        }
    }

    func rebuildConversationIndex() {
        conversationIndexByID = Dictionary(
            uniqueKeysWithValues: conversations.enumerated().map { ($1.id, $0) }
        )
    }

    func rebuildCurrentMessageIndex() {
        guard let conversation = currentConversation else {
            currentMessageIndexByID = [:]
            return
        }

        currentMessageIndexByID = Dictionary(
            uniqueKeysWithValues: conversation.messages.enumerated().map { ($1.id, $0) }
        )
    }

    func indexAfterLineLimit(in text: String, lineLimit: Int) -> String.Index? {
        guard lineLimit > 0 else { return text.startIndex }

        var lineBreakCount = 0
        for index in text.indices {
            if text[index] == "\n" {
                lineBreakCount += 1
                if lineBreakCount == lineLimit {
                    return text.index(after: index)
                }
            }
        }
        return nil
    }
}

private extension String {
    func removingThinkTagContent() -> String {
        replacingOccurrences(
            of: "<think>[\\s\\S]*?</think>",
            with: "",
            options: .regularExpression
        )
    }
}
