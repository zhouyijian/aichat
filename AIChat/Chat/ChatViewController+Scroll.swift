import UIKit

// MARK: - Bottom Scroll Button
extension ChatViewController {
    @objc func didTapScrollToBottom() {
        scrollToBottomByItem(animated: true)
        updateScrollToBottomButtonVisibility()
    }

    func updateScrollToBottomButtonVisibility() {
        scrollToBottomButton.isHidden = isNearBottom(tolerance: 450)
    }

    func isNearBottom(tolerance: CGFloat = 120) -> Bool {
        let adjustedInsets = collectionView.adjustedContentInset
        let visibleHeight = collectionView.bounds.height - adjustedInsets.top - adjustedInsets.bottom
        let currentOffsetY = collectionView.contentOffset.y + adjustedInsets.top
        let maxOffsetY = max(0, collectionView.contentSize.height - visibleHeight)

        return (maxOffsetY - currentOffsetY) <= tolerance
    }
    
    func scrollToBottomByItem(animated: Bool = false) {
        let lastItem = viewModel.chatItems.count - 1
        guard lastItem >= 0 else { return }

        let indexPath = IndexPath(item: lastItem, section: 0)
        collectionView.scrollToItem(at: indexPath, at: .bottom, animated: animated)
        updateScrollToBottomButtonVisibility()
    }
    
}

// MARK: - UIScrollViewDelegate
extension ChatViewController {
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        updateScrollToBottomButtonVisibility()
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        userIsInteracting = true
        disableAutoPinForCurrentStream()
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
