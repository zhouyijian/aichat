import Foundation
import CoreGraphics

final class MessageHeightCache {

    // MARK: - Key
    private struct Key: Hashable {
        let messageID: UUID
        let pixelWidth: Int
    }

    // MARK: - State
    private var heights: [Key: CGFloat] = [:]
    private var keyIndex: [UUID: Set<Key>] = [:]

    // MARK: - Cache Operations
    func cachedHeight(for messageID: UUID, width: CGFloat, displayScale: CGFloat) -> CGFloat? {
        let key = makeKey(for: messageID, width: width, displayScale: displayScale)
        return heights[key]
    }

    func cacheHeight(_ height: CGFloat, for messageID: UUID, width: CGFloat, displayScale: CGFloat) {
        let key = makeKey(for: messageID, width: width, displayScale: displayScale)
        heights[key] = height
        keyIndex[messageID, default: []].insert(key)
    }

    func invalidateHeight(for messageID: UUID, width: CGFloat, displayScale: CGFloat) {
        let key = makeKey(for: messageID, width: width, displayScale: displayScale)
        heights.removeValue(forKey: key)
        keyIndex[messageID]?.remove(key)
        if keyIndex[messageID]?.isEmpty == true {
            keyIndex[messageID] = nil
        }
    }

    func invalidateAll() {
        heights.removeAll()
        keyIndex.removeAll()
    }

    func prune(validMessageIDs: Set<UUID>) {
        heights = heights.filter { validMessageIDs.contains($0.key.messageID) }
        keyIndex = keyIndex.filter { validMessageIDs.contains($0.key) }
    }

    // MARK: - Helpers
    private func makeKey(for messageID: UUID, width: CGFloat, displayScale: CGFloat) -> Key {
        let pixelWidth = Int((width * displayScale).rounded())
        return Key(messageID: messageID, pixelWidth: pixelWidth)
    }
}
