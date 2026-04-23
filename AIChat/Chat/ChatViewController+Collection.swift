import UIKit

// MARK: - Data Source & Snapshot
extension ChatViewController {
    func setupDataSource() {
        dataSource = UICollectionViewDiffableDataSource<Section, ChatItem.ID>(
            collectionView: collectionView
        ) { [weak self] collectionView, indexPath, id in
            guard let self, let item = self.displayedItem(id: id) else {
                return collectionView.dequeueReusableCell(
                    withReuseIdentifier: ChatTextBlockCell.reuseID,
                    for: indexPath
                )
            }

            return self.dequeueConfiguredCell(for: item, in: collectionView, at: indexPath)
        }
    }

    func applySnapshot(animatingDifferences: Bool = true) {
        let items = viewModel.chatItems
        snapshotApplyGeneration &+= 1
        let generation = snapshotApplyGeneration
        prepareDisplayedItemsForSnapshot(items)

        var snapshot = NSDiffableDataSourceSnapshot<Section, ChatItem.ID>()
        snapshot.appendSections([.main])
        snapshot.appendItems(items.map(\.id), toSection: .main)
        dataSource.apply(snapshot, animatingDifferences: animatingDifferences) { [weak self] in
            guard self?.snapshotApplyGeneration == generation else { return }
            self?.commitDisplayedItems(items)
        }
    }

    func appendMessage(_ message: Message, scrollToBottom: Bool = false) {
        viewModel.appendMessage(message)
        applySnapshot(animatingDifferences: true)
        viewModel.pruneHeightCache()
        updateScrollToBottomButtonVisibility()

        guard scrollToBottom else { return }
        DispatchQueue.main.async { [weak self] in
            self?.scrollToBottomByItem(animated: true)
        }
    }

    func reconfigureMessage(id: UUID, animated: Bool = true) {
        refreshMessageItems(id: id, animated: animated)
    }

    func reloadConversationMessages() {
        applySnapshot(animatingDifferences: false)
        viewModel.pruneHeightCache()
        collectionView.reloadData()
        updateScrollToBottomButtonVisibility()
    }

    /// Refreshes one message's rendered blocks and optionally keeps viewport pinned to bottom.
    func updateMessageUI(id: UUID, shouldPinToBottom: Bool) {
        refreshMessageItems(id: id, animated: false)

        guard shouldPinToBottom else { return }
        DispatchQueue.main.async { [weak self] in
            self?.scrollToBottomByItem(animated: false)
        }
    }

    func updateStreamingMessageUI(id: UUID, shouldPinToBottom: Bool) {
        guard viewModel.message(id: id) != nil else { return }

        let width = itemWidth()
        guard width > 0 else {
            updateMessageUI(id: id, shouldPinToBottom: shouldPinToBottom)
            return
        }

        let nextState = makeStreamingLayoutState(for: id, width: width)
        let previousState = streamingLayoutStates[id]
        streamingLayoutStates[id] = nextState

        guard previousState == nextState else {
            updateMessageUI(id: id, shouldPinToBottom: shouldPinToBottom)
            return
        }

        reconfigureVisibleMessageCellsIfNeeded(messageID: id)
    }

    func toggleReasoning(for id: UUID) {
        streamingLayoutStates.removeValue(forKey: id)
        guard viewModel.toggleReasoning(for: id) else { return }
        updateMessageUI(id: id, shouldPinToBottom: false)
        viewModel.save()
    }
}

private extension ChatViewController {
    func dequeueConfiguredCell(
        for item: ChatItem,
        in collectionView: UICollectionView,
        at indexPath: IndexPath
    ) -> UICollectionViewCell {
        switch item.kind {
        case .code:
            let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: ChatCodeBlockCell.reuseID,
                for: indexPath
            ) as! ChatCodeBlockCell
            cell.configure(with: item)
            configureCopyActions(for: cell, item: item)
            return cell

        case .image:
            let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: ChatImageBlockCell.reuseID,
                for: indexPath
            ) as! ChatImageBlockCell
            cell.configure(with: item)
            configureCopyActions(for: cell, item: item)
            return cell

        case .control(let action):
            let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: ChatControlCell.reuseID,
                for: indexPath
            ) as! ChatControlCell
            cell.configure(with: item)
            cell.onTapAction = { [weak self] in
                switch action {
                case .toggleReasoning:
                    self?.toggleReasoning(for: item.messageID)
                }
            }
            configureCopyActions(for: cell, item: item)
            return cell

        case .markdown, .reasoning, .status:
            let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: ChatTextBlockCell.reuseID,
                for: indexPath
            ) as! ChatTextBlockCell
            cell.configure(with: item)
            configureCopyActions(for: cell, item: item)
            return cell
        }
    }

    func configureExistingCell(_ cell: UICollectionViewCell, with item: ChatItem) {
        switch (cell, item.kind) {
        case (let cell as ChatCodeBlockCell, .code):
            cell.configure(with: item)
            configureCopyActions(for: cell, item: item)
        case (let cell as ChatImageBlockCell, .image):
            cell.configure(with: item)
            configureCopyActions(for: cell, item: item)
        case (let cell as ChatControlCell, .control):
            cell.configure(with: item)
            configureCopyActions(for: cell, item: item)
        case (let cell as ChatTextBlockCell, _):
            cell.configure(with: item)
            configureCopyActions(for: cell, item: item)
        default:
            break
        }
    }

    func configureCopyActions(for cell: ChatBubbleCell, item: ChatItem) {
        cell.onCopyBlock = item.isCopyable ? { [weak self] in
            self?.copyToPasteboard(item.copyText)
        } : nil

        cell.onCopyMessage = { [weak self] in
            guard let text = self?.viewModel.copyTextForMessage(id: item.messageID),
                  !text.isEmpty else { return }
            self?.copyToPasteboard(text)
        }
    }

    func copyToPasteboard(_ text: String) {
        UIPasteboard.general.string = text
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.success)
    }

    func refreshMessageItems(id: UUID, animated: Bool) {
        let oldIDs = dataSource.snapshot().itemIdentifiers.filter { $0.messageID == id }
        let newIDs = viewModel.itemIDs(for: id)

        guard oldIDs == newIDs else {
            applySnapshot(animatingDifferences: animated)
            return
        }

        guard !newIDs.isEmpty else { return }
        syncDisplayedItemsFromViewModel()
        collectionView.collectionViewLayout.invalidateLayout()

        var snapshot = dataSource.snapshot()
        let existingIDs = newIDs.filter { snapshot.indexOfItem($0) != nil }
        guard !existingIDs.isEmpty else { return }

        snapshot.reconfigureItems(existingIDs)
        dataSource.apply(snapshot, animatingDifferences: animated)
    }

    func reconfigureVisibleMessageCellsIfNeeded(messageID: UUID) {
        syncDisplayedItemsFromViewModel()
        let visibleIDs = viewModel.itemIDs(for: messageID)
        for itemID in visibleIDs {
            guard
                let item = displayedItem(id: itemID),
                let indexPath = dataSource.indexPath(for: itemID),
                let cell = collectionView.cellForItem(at: indexPath)
            else {
                continue
            }
            configureExistingCell(cell, with: item)
        }
    }

    func displayedItem(id: ChatItem.ID) -> ChatItem? {
        displayedItemsByID[id] ?? viewModel.chatItem(id: id)
    }

    func prepareDisplayedItemsForSnapshot(_ items: [ChatItem]) {
        for item in items {
            displayedItemsByID[item.id] = item
        }
    }

    func commitDisplayedItems(_ items: [ChatItem]) {
        displayedItemsByID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
    }

    func syncDisplayedItemsFromViewModel() {
        prepareDisplayedItemsForSnapshot(viewModel.chatItems)
    }
}

// MARK: - Layout Measurement
extension ChatViewController {
    func itemWidth() -> CGFloat {
        guard let layout = collectionView.collectionViewLayout as? UICollectionViewFlowLayout else {
            return collectionView.bounds.width
        }
        return collectionView.bounds.width - layout.sectionInset.left - layout.sectionInset.right
    }

    func measureHeight(for item: ChatItem, width: CGFloat) -> CGFloat {
        let displayScale = collectionView.traitCollection.displayScale

        if let cachedHeight = viewModel.cachedHeight(for: item, width: width, displayScale: displayScale) {
            return cachedHeight
        }

        let measuredHeight = fastMeasureHeight(for: item, width: width)
        viewModel.cacheHeight(measuredHeight, for: item, width: width, displayScale: displayScale)
        return measuredHeight
    }

    private func fastMeasureHeight(for item: ChatItem, width: CGFloat) -> CGFloat {
        let bubbleWidth = floor(width * 0.82)
        let outerVerticalInsets = (item.isFirstInMessage ? 6.0 : 0.0) + (item.isLastInMessage ? 6.0 : 0.0)

        switch item.kind {
        case .markdown:
            let font = UIFont.systemFont(ofSize: 16)
            let textWidth = max(0, bubbleWidth - 24)
            return outerVerticalInsets + 24 + richTextHeight(for: item, font: font, width: textWidth)

        case .reasoning, .status:
            let font = UIFont.systemFont(ofSize: 13)
            let textWidth = max(0, bubbleWidth - 24)
            return outerVerticalInsets + 24 + richTextHeight(for: item, font: font, width: textWidth)

        case .code(let language):
            let font = UIFont.monospacedSystemFont(ofSize: 14, weight: .regular)
            let textWidth = max(0, bubbleWidth - 40)
            let languageHeight: CGFloat = language == nil ? 0 : 22
            return outerVerticalInsets + 20 + 20 + languageHeight + textHeight(text: item.text, font: font, width: textWidth)

        case .image(_, let alt):
            let captionHeight = (alt?.isEmpty == false) ? 28.0 : 0
            return outerVerticalInsets + 20 + 180 + captionHeight

        case .control:
            let font = UIFont.systemFont(ofSize: 13, weight: .medium)
            let textWidth = max(0, bubbleWidth - 24)
            return outerVerticalInsets + 16 + max(22, textHeight(text: item.text, font: font, width: textWidth))
        }
    }

    private func textHeight(text: String, font: UIFont, width: CGFloat) -> CGFloat {
        let safeText = text.isEmpty ? " " : text
        let rect = (safeText as NSString).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font],
            context: nil
        )
        return ceil(rect.height)
    }

    private func richTextHeight(for item: ChatItem, font: UIFont, width: CGFloat) -> CGFloat {
        guard item.rendersMarkdown,
              let attributed = MarkdownRenderer.attributedString(
                from: item.text,
                baseFont: font,
                textColor: item.role == .user ? .white : .label
              )
        else {
            return textHeight(text: item.text, font: font, width: width)
        }

        let rect = attributed.boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        )
        return ceil(rect.height)
    }

    private func makeStreamingLayoutState(for messageID: UUID, width: CGFloat) -> StreamingLayoutState {
        let itemIDs = viewModel.itemIDs(for: messageID)
        let heights = itemIDs.map { itemID in
            viewModel.chatItem(id: itemID)
                .map { Int(measureHeight(for: $0, width: width).rounded()) } ?? 0
        }

        return StreamingLayoutState(itemIDs: itemIDs, estimatedHeights: heights)
    }
}

// MARK: - UICollectionViewDelegateFlowLayout
extension ChatViewController: UICollectionViewDelegateFlowLayout {
    func collectionView(_ collectionView: UICollectionView,
                        layout collectionViewLayout: UICollectionViewLayout,
                        sizeForItemAt indexPath: IndexPath) -> CGSize {
        let width = itemWidth()
        guard
            let id = dataSource.itemIdentifier(for: indexPath),
            let item = displayedItem(id: id)
        else {
            return CGSize(width: width, height: 1)
        }
        let height = measureHeight(for: item, width: width)
        return CGSize(width: width, height: height)
    }
}
