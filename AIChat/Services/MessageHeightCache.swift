import Foundation
import CoreGraphics

final class MessageHeightCache {

    // MARK: - Key
    private struct Key: Hashable {
        let messageID: UUID
        let pixelWidth: Int
        let layoutVersion: Int
    }

    // MARK: - State
    private var heights: [Key: CGFloat] = [:]
    private var keyIndex: [UUID: Set<Key>] = [:]

    // MARK: - Cache Operations
    func cachedHeight(
        for messageID: UUID,
        width: CGFloat,
        displayScale: CGFloat,
        layoutVersion: Int
    ) -> CGFloat? {
        let key = makeKey(
            for: messageID,
            width: width,
            displayScale: displayScale,
            layoutVersion: layoutVersion
        )
        return heights[key]
    }

    func cacheHeight(
        _ height: CGFloat,
        for messageID: UUID,
        width: CGFloat,
        displayScale: CGFloat,
        layoutVersion: Int
    ) {
        let key = makeKey(
            for: messageID,
            width: width,
            displayScale: displayScale,
            layoutVersion: layoutVersion
        )
        removeStaleKeysIfNeeded(replacing: key)
        heights[key] = height
        keyIndex[messageID, default: []].insert(key)
    }

    func invalidateHeight(
        for messageID: UUID,
        width: CGFloat,
        displayScale: CGFloat,
        layoutVersion: Int
    ) {
        let key = makeKey(
            for: messageID,
            width: width,
            displayScale: displayScale,
            layoutVersion: layoutVersion
        )
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
    private func makeKey(
        for messageID: UUID,
        width: CGFloat,
        displayScale: CGFloat,
        layoutVersion: Int
    ) -> Key {
        let pixelWidth = Int((width * displayScale).rounded())
        return Key(
            messageID: messageID,
            pixelWidth: pixelWidth,
            layoutVersion: layoutVersion
        )
    }

    private func removeStaleKeysIfNeeded(replacing key: Key) {
        guard let existingKeys = keyIndex[key.messageID] else { return }

        let staleKeys = existingKeys.filter {
            $0.pixelWidth == key.pixelWidth && $0.layoutVersion != key.layoutVersion
        }

        guard !staleKeys.isEmpty else { return }

        for staleKey in staleKeys {
            heights.removeValue(forKey: staleKey)
            keyIndex[key.messageID]?.remove(staleKey)
        }

        if keyIndex[key.messageID]?.isEmpty == true {
            keyIndex[key.messageID] = nil
        }
    }
}
