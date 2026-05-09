//
//  StreamingContinuationPrefixFilter.swift
//  AIChat
//
//  Created by OpenAI on 2026/5/8.
//

import Foundation

/// Removes duplicated text that sometimes appears at the start of a continuation stream.
/// The filter only buffers the first small prefix of a continuation, then becomes inert.
final class StreamingContinuationPrefixFilter {

    private let existingSuffix: String
    private var bufferedPrefix = ""
    private var sawPlausibleDuplicatedPrefix = false
    private(set) var isResolved = false

    private let minProbeCharacters = 28
    private let maxProbeCharacters = 160
    private let minOverlapCharacters = 6

    init(existingText: String) {
        let trimmed = existingText.trimmingCharacters(in: .whitespacesAndNewlines)
        self.existingSuffix = String(trimmed.suffix(1_000))
    }

    func consume(_ delta: String) -> String? {
        guard !delta.isEmpty else { return nil }
        guard !isResolved else { return delta }

        bufferedPrefix += delta
        guard shouldResolveBufferedPrefix() else { return nil }
        return resolveBufferedPrefix()
    }

    func flush() -> String? {
        guard !isResolved else { return nil }
        return resolveBufferedPrefix()
    }

    private func shouldResolveBufferedPrefix() -> Bool {
        let count = bufferedPrefix.count
        if count >= maxProbeCharacters {
            return true
        }

        if isPlausibleDuplicatedPrefix {
            sawPlausibleDuplicatedPrefix = true
            return false
        }

        if sawPlausibleDuplicatedPrefix {
            return true
        }

        return bufferedPrefix.contains("\n") || count >= minProbeCharacters
    }

    private func resolveBufferedPrefix() -> String? {
        isResolved = true

        let overlapCount = duplicatedPrefixLength()
        let output = String(bufferedPrefix.dropFirst(overlapCount))
        bufferedPrefix = ""

        return output.isEmpty ? nil : output
    }

    private func duplicatedPrefixLength() -> Int {
        guard existingSuffix.count >= minOverlapCharacters else { return 0 }

        let leadingWhitespaceCount = bufferedPrefix.prefix(while: \.isWhitespace).count
        let comparablePrefix = String(bufferedPrefix.dropFirst(leadingWhitespaceCount))
        let maxOverlap = min(existingSuffix.count, comparablePrefix.count)
        guard maxOverlap >= minOverlapCharacters else { return 0 }

        for length in stride(from: maxOverlap, through: minOverlapCharacters, by: -1) {
            if existingSuffix.suffix(length) == comparablePrefix.prefix(length) {
                return leadingWhitespaceCount + length
            }
        }

        return 0
    }

    private var isPlausibleDuplicatedPrefix: Bool {
        guard existingSuffix.count >= minOverlapCharacters else { return false }

        let leadingWhitespaceCount = bufferedPrefix.prefix(while: \.isWhitespace).count
        let comparablePrefix = String(bufferedPrefix.dropFirst(leadingWhitespaceCount))
        guard comparablePrefix.count >= minOverlapCharacters,
              comparablePrefix.count <= existingSuffix.count
        else {
            return false
        }

        return existingSuffix.range(of: comparablePrefix, options: .backwards) != nil
    }
}
