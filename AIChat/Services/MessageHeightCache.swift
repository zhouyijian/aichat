import Foundation
import CoreGraphics

final class MessageHeightCache {

    // MARK: - Key
    private struct Key: Hashable {
        let itemKey: String
        let pixelWidth: Int
        let layoutVersion: Int
    }

    // MARK: - State
    private var heights: [Key: CGFloat] = [:]
    private var keyIndex: [String: Set<Key>] = [:]

    // MARK: - Cache Operations
    func cachedHeight(
        for itemKey: String,
        width: CGFloat,
        displayScale: CGFloat,
        layoutVersion: Int
    ) -> CGFloat? {
        let key = makeKey(
            for: itemKey,
            width: width,
            displayScale: displayScale,
            layoutVersion: layoutVersion
        )
        return heights[key]
    }

    func cacheHeight(
        _ height: CGFloat,
        for itemKey: String,
        width: CGFloat,
        displayScale: CGFloat,
        layoutVersion: Int
    ) {
        let key = makeKey(
            for: itemKey,
            width: width,
            displayScale: displayScale,
            layoutVersion: layoutVersion
        )
        removeStaleKeysIfNeeded(replacing: key)
        heights[key] = height
        keyIndex[itemKey, default: []].insert(key)
    }

    func invalidateHeight(
        for itemKey: String,
        width: CGFloat,
        displayScale: CGFloat,
        layoutVersion: Int
    ) {
        let key = makeKey(
            for: itemKey,
            width: width,
            displayScale: displayScale,
            layoutVersion: layoutVersion
        )
        heights.removeValue(forKey: key)
        keyIndex[itemKey]?.remove(key)
        if keyIndex[itemKey]?.isEmpty == true {
            keyIndex[itemKey] = nil
        }
    }

    func invalidateAll() {
        heights.removeAll()
        keyIndex.removeAll()
    }

    func prune(validItemKeys: Set<String>) {
        heights = heights.filter { validItemKeys.contains($0.key.itemKey) }
        keyIndex = keyIndex.filter { validItemKeys.contains($0.key) }
    }

    // MARK: - Helpers
    private func makeKey(
        for itemKey: String,
        width: CGFloat,
        displayScale: CGFloat,
        layoutVersion: Int
    ) -> Key {
        let pixelWidth = Int((width * displayScale).rounded())
        return Key(
            itemKey: itemKey,
            pixelWidth: pixelWidth,
            layoutVersion: layoutVersion
        )
    }

    private func removeStaleKeysIfNeeded(replacing key: Key) {
        guard let existingKeys = keyIndex[key.itemKey] else { return }

        let staleKeys = existingKeys.filter {
            $0.pixelWidth == key.pixelWidth && $0.layoutVersion != key.layoutVersion
        }

        guard !staleKeys.isEmpty else { return }

        for staleKey in staleKeys {
            heights.removeValue(forKey: staleKey)
            keyIndex[key.itemKey]?.remove(staleKey)
        }

        if keyIndex[key.itemKey]?.isEmpty == true {
            keyIndex[key.itemKey] = nil
        }
    }
}
