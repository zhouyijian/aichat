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

            if let message = self?.viewModel.message(id: id) {
                cell.configure(with: message)
                cell.onToggleReasoning = { [weak self] in
                    self?.toggleReasoning(for: id)
                }
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
            self?.scrollToBottom(animated: true)
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
            self?.scrollToBottom(animated: true)
        }
    }
    
    func toggleReasoning(for id: UUID) {
        guard viewModel.toggleReasoning(for: id) else { return }
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

        sizingCell.frame = CGRect(x: 0, y: 0, width: width, height: 1000)
        sizingCell.configure(with: message)
        sizingCell.layoutIfNeeded()

        let target = CGSize(width: width, height: UIView.layoutFittingCompressedSize.height)
        let size = sizingCell.contentView.systemLayoutSizeFitting(
            target,
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )

        let measuredHeight = ceil(size.height)
        viewModel.cacheHeight(
            measuredHeight,
            for: message.id,
            width: width,
            displayScale: displayScale
        )
        return measuredHeight
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
