import UIKit

// MARK: - Bottom Scroll Button
extension ChatViewController {
    @objc func didTapScrollToBottom() {
        userIsInteracting = false
        scrollToBottomByItem(animated: true)
        refreshAutoPinForCurrentStreamIfNeeded()
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

    func distanceFromBottom() -> CGFloat {
        let adjustedInsets = collectionView.adjustedContentInset
        let visibleHeight = collectionView.bounds.height - adjustedInsets.top - adjustedInsets.bottom
        let currentOffsetY = collectionView.contentOffset.y + adjustedInsets.top
        let maxOffsetY = max(0, collectionView.contentSize.height - visibleHeight)

        return max(0, maxOffsetY - currentOffsetY)
    }

    func restoreBottomDistance(_ distance: CGFloat = 0) {
        collectionView.layoutIfNeeded()

        let adjustedInsets = collectionView.adjustedContentInset
        let visibleHeight = collectionView.bounds.height - adjustedInsets.top - adjustedInsets.bottom
        let maxOffsetY = max(0, collectionView.contentSize.height - visibleHeight)
        let targetOffsetY = maxOffsetY - max(0, distance) - adjustedInsets.top
        let minOffsetY = -adjustedInsets.top
        let maxContentOffsetY = max(minOffsetY, maxOffsetY - adjustedInsets.top)
        let clampedOffsetY = min(max(targetOffsetY, minOffsetY), maxContentOffsetY)

        guard abs(collectionView.contentOffset.y - clampedOffsetY) > 0.5 else {
            updateScrollToBottomButtonVisibility()
            return
        }

        collectionView.setContentOffset(
            CGPoint(x: collectionView.contentOffset.x, y: clampedOffsetY),
            animated: false
        )
        updateScrollToBottomButtonVisibility()
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
        if isNearBottom(tolerance: 80) {
            refreshAutoPinForCurrentStreamIfNeeded()
        }
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        userIsInteracting = true
        disableAutoPinForCurrentStream()
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate {
            userIsInteracting = false
            refreshAutoPinForCurrentStreamIfNeeded()
        }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        userIsInteracting = false
        refreshAutoPinForCurrentStreamIfNeeded()
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        userIsInteracting = false
        refreshAutoPinForCurrentStreamIfNeeded()
    }
}
