import UIKit

// MARK: - Data Source & Snapshot
extension ChatViewController {
    func setupDataSource() {
        dataSource = UICollectionViewDiffableDataSource<Section, UUID>(
            collectionView: collectionView
        ) { [weak self] collectionView, indexPath, id in
            let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: MessageCell.reuseID,
                for: indexPath
            ) as! MessageCell
            guard let self, let message = self.viewModel.message(id: id) else {
                return cell
            }
            let segments = message.role == .assistant ? self.viewModel.assistantSegments(for: message) : nil
            cell.configure(with: message, assistantSegments: segments)
            cell.onToggleContentExpansion = { [weak self] in
                self?.toggleContentExpansion(for: id)
            }
            cell.onToggleReasoning = { [weak self] in
                self?.toggleReasoning(for: id)
            }
            return cell
        }
    }

    func applySnapshot(animatingDifferences: Bool = true) {
        var snapshot = NSDiffableDataSourceSnapshot<Section, UUID>()
        snapshot.appendSections([.main])
        snapshot.appendItems(viewModel.messages.map(\.id), toSection: .main)
        dataSource.apply(snapshot, animatingDifferences: animatingDifferences)
    }

    func appendMessage(_ message: Message, scrollToBottom: Bool = false) {
        viewModel.appendMessage(message)

        var snapshot = dataSource.snapshot()
        if snapshot.sectionIdentifiers.isEmpty {
            snapshot.appendSections([.main])
        }
        snapshot.appendItems([message.id], toSection: .main)
        dataSource.apply(snapshot, animatingDifferences: true)

        viewModel.pruneHeightCache()
        updateScrollToBottomButtonVisibility()

        guard scrollToBottom else { return }
        DispatchQueue.main.async { [weak self] in
            self?.scrollToBottomByItem(animated: true)
        }
    }

    func reconfigureMessage(id: UUID, animated: Bool = true) {
        var snapshot = dataSource.snapshot()
        snapshot.reconfigureItems([id])
        dataSource.apply(snapshot, animatingDifferences: animated)
    }
    
    func reloadConversationMessages() {
        applySnapshot(animatingDifferences: false)
        viewModel.pruneHeightCache()
        collectionView.reloadData()
        updateScrollToBottomButtonVisibility()
    }

    /// Refreshes one message row and optionally keeps viewport pinned to bottom.
    func updateMessageUI(id: UUID, shouldPinToBottom: Bool) {
        let width = itemWidth()
        let scale = collectionView.traitCollection.displayScale

        viewModel.invalidateHeight(for: id, width: width, displayScale: scale)
        reconfigureMessage(id: id, animated: false)

        guard shouldPinToBottom else { return }
        DispatchQueue.main.async { [weak self] in
            self?.scrollToBottomByItem(animated: false)
        }
    }
    
    func toggleReasoning(for id: UUID) {
        guard viewModel.toggleReasoning(for: id) else { return }
        updateMessageUI(id: id, shouldPinToBottom: false)
        viewModel.save()
    }

    func toggleContentExpansion(for id: UUID) {
        guard viewModel.toggleContentExpansion(for: id) else { return }
        updateMessageUI(id: id, shouldPinToBottom: false)
        viewModel.save()
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

    func measureHeight(for message: Message, width: CGFloat) -> CGFloat {
        let displayScale = collectionView.traitCollection.displayScale

        if let cachedHeight = viewModel.cachedHeight(
            for: message.id,
            width: width,
            displayScale: displayScale
        ) {
            return cachedHeight
        }

        let measuredHeight: CGFloat
        if shouldUseFastMeasure(for: message) {
            measuredHeight = fastMeasureHeight(for: message, width: width)
        } else {
            measuredHeight = exactMeasureHeight(for: message, width: width)
        }

        viewModel.cacheHeight(
            measuredHeight,
            for: message.id,
            width: width,
            displayScale: displayScale
        )
        return measuredHeight
    }
    
    private func shouldUseFastMeasure(for message: Message) -> Bool {
        guard message.role == .assistant else { return false }

        let segments = viewModel.assistantSegments(for: message)
        let totalLength = segments.responseText.count + (segments.reasoningText?.count ?? 0)

        return isActivelyStreaming(message) || totalLength > 200
    }
    
    private func isActivelyStreaming(_ message: Message) -> Bool {
        switch message.status {
        // 按你的实际枚举调整
        case .streaming, .pending:
            return true
        default:
            return false
        }
    }
    
    private func fastMeasureHeight(for message: Message, width: CGFloat) -> CGFloat {
        let bubbleWidth = floor(width * 0.82)

        // bubble 内 stackView 左右 inset
        let stackHorizontalInsets: CGFloat = 12 * 2
        let stackVerticalInsets: CGFloat = 12 * 2

        // cell 外层 bubble 上下 inset
        let outerVerticalInsets: CGFloat = 6 * 2

        let stackSpacing: CGFloat = 8

        let messageFont = UIFont.systemFont(ofSize: 16)
        let reasoningFont = UIFont.systemFont(ofSize: 13)
        let buttonFont = UIFont.systemFont(ofSize: 13, weight: .medium)

        let segments = message.role == .assistant ? viewModel.assistantSegments(for: message) : nil

        let textWidth = max(0, bubbleWidth - stackHorizontalInsets)

        var arrangedHeights: [CGFloat] = []

        switch message.role {
        case .user, .system:
            let text = normalizedMainText(for: message, segments: segments)
            let messageHeight = textHeight(text: text, font: messageFont, width: textWidth)
            arrangedHeights.append(messageHeight)

        case .assistant:
            let responseText = segments?.displayedResponseText(isExpanded: message.isContentExpanded) ?? fallbackResponseText(for: message)
            let responseHeight = textHeight(text: responseText, font: messageFont, width: textWidth)
            arrangedHeights.append(responseHeight)

            if segments?.isResponseFoldable == true {
                let contentButtonHeight = max(ceil(buttonFont.lineHeight), 20)
                arrangedHeights.append(contentButtonHeight)
            }

            let reasoningText = segments?.reasoningText
            let hasReasoning = !(reasoningText?.isEmpty ?? true)

            if hasReasoning {
                let buttonHeight = max(ceil(buttonFont.lineHeight), 20)
                arrangedHeights.append(buttonHeight)

                if message.isReasoningExpanded, let reasoningText, !reasoningText.isEmpty {
                    // reasoningLabel 在 reasoningContainerView 内还有 10 + 10 的左右 inset
                    let reasoningTextWidth = max(0, textWidth - 20)
                    let reasoningTextHeight = textHeight(
                        text: reasoningText,
                        font: reasoningFont,
                        width: reasoningTextWidth
                    )

                    // reasoningContainerView 高度 = reasoningLabel 高度 + 上下 10 + 10
                    let reasoningContainerHeight = reasoningTextHeight + 20
                    arrangedHeights.append(reasoningContainerHeight)
                }
            }
        }

        let arrangedContentHeight = arrangedHeights.reduce(0, +)
        let totalSpacing = CGFloat(max(0, arrangedHeights.count - 1)) * stackSpacing

        let totalHeight =
            outerVerticalInsets +
            stackVerticalInsets +
            arrangedContentHeight +
            totalSpacing

        return ceil(totalHeight)
    }
    
    private func normalizedMainText(for message: Message, segments: AssistantSegments?) -> String {
        switch message.role {
        case .assistant:
            return segments?.displayedResponseText(isExpanded: message.isContentExpanded) ?? fallbackResponseText(for: message)
        case .user, .system:
            let text = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? "..." : text
        }
    }

    private func fallbackResponseText(for message: Message) -> String {
        let text = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "..." : text
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
    
    private func exactMeasureHeight(for message: Message, width: CGFloat) -> CGFloat {
        sizingCell.frame = CGRect(x: 0, y: 0, width: width, height: 1000)
        let assistantSegments = message.role == .assistant ? viewModel.assistantSegments(for: message) : nil
        sizingCell.configure(with: message, assistantSegments: assistantSegments)
        sizingCell.layoutIfNeeded()

        let target = CGSize(width: width, height: UIView.layoutFittingCompressedSize.height)
        let size = sizingCell.contentView.systemLayoutSizeFitting(
            target,
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        return ceil(size.height)
    }
}

// MARK: - UICollectionViewDelegateFlowLayout
extension ChatViewController: UICollectionViewDelegateFlowLayout {
    func collectionView(_ collectionView: UICollectionView,
                        layout collectionViewLayout: UICollectionViewLayout,
                        sizeForItemAt indexPath: IndexPath) -> CGSize {
        let width = itemWidth()
        let message = viewModel.message(at: indexPath)
        let height = measureHeight(for: message, width: width)
        return CGSize(width: width, height: height)
    }
}
