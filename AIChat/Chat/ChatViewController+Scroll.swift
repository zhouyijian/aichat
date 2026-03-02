import UIKit

// MARK: - Bottom Scroll Button
extension ChatViewController {
    @objc func didTapScrollToBottom() {
        scrollToBottom(animated: true)
        updateScrollToBottomButtonVisibility()
    }

    func updateScrollToBottomButtonVisibility() {
        scrollToBottomButton.isHidden = isNearBottom(tolerance: 150)
    }

    func isNearBottom(tolerance: CGFloat = 60) -> Bool {
        let contentHeight = collectionView.contentSize.height
        let visibleHeight = collectionView.bounds.height - collectionView.adjustedContentInset.top - collectionView.adjustedContentInset.bottom
        let y = collectionView.contentOffset.y + collectionView.adjustedContentInset.top
        let maxOffsetY = max(0, contentHeight - visibleHeight)
        return (maxOffsetY - y) <= tolerance
    }

    func scrollToBottom(animated: Bool) {
        let lastItem = viewModel.messages.count - 1
        guard lastItem >= 0 else { return }
        collectionView.scrollToItem(at: IndexPath(item: lastItem, section: 0), at: .bottom, animated: animated)
    }
}

// MARK: - UIScrollViewDelegate
extension ChatViewController {
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        updateScrollToBottomButtonVisibility()
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        userIsInteracting = true
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate {
            userIsInteracting = false
        }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        userIsInteracting = false
    }
}
