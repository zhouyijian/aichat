import UIKit

enum MarkdownRenderer {
    private static let cache: NSCache<NSString, NSAttributedString> = {
        let cache = NSCache<NSString, NSAttributedString>()
        cache.countLimit = 300
        cache.totalCostLimit = 2_000_000
        return cache
    }()

    static func attributedString(
        from markdown: String,
        baseFont: UIFont,
        textColor: UIColor
    ) -> NSAttributedString? {
        let normalized = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        let key = cacheKey(for: normalized, baseFont: baseFont, textColor: textColor)

        if let cached = cache.object(forKey: key) {
            return cached
        }

        let attributed = renderBlocksPreservingLineBreaks(
            from: normalized,
            baseFont: baseFont,
            textColor: textColor
        )
        cache.setObject(attributed, forKey: key, cost: normalized.utf16.count)
        return attributed
    }

    static func tableCellAttributedString(
        from markdown: String,
        baseFont: UIFont,
        textColor: UIColor,
        alignment: NSTextAlignment
    ) -> NSAttributedString {
        let style = paragraphStyle(for: baseFont, paragraphSpacing: 0)
        if let mutableStyle = style.mutableCopy() as? NSMutableParagraphStyle {
            mutableStyle.alignment = alignment
            return inlineAttributedString(
                from: markdown.isEmpty ? " " : markdown,
                baseFont: baseFont,
                textColor: textColor,
                paragraphStyle: mutableStyle
            )
        }

        return inlineAttributedString(
            from: markdown.isEmpty ? " " : markdown,
            baseFont: baseFont,
            textColor: textColor,
            paragraphStyle: style
        )
    }

    private static func cacheKey(for text: String, baseFont: UIFont, textColor: UIColor) -> NSString {
        let fontKey = "\(baseFont.fontName)-\(baseFont.pointSize)"
        let colorKey = textColor.resolvedColor(with: .current).description
        return "chat-md-v3|\(fontKey)|\(colorKey)|\(text)" as NSString
    }

    private static func renderBlocksPreservingLineBreaks(
        from markdown: String,
        baseFont: UIFont,
        textColor: UIColor
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        for (index, line) in lines.enumerated() {
            let block = blockStyle(for: line, baseFont: baseFont)
            result.append(
                inlineAttributedString(
                    from: block.text,
                    baseFont: block.font,
                    textColor: textColor,
                    paragraphStyle: block.paragraphStyle
                )
            )

            if index < lines.count - 1 {
                result.append(
                    NSAttributedString(
                        string: "\n",
                        attributes: [
                            .font: block.font,
                            .foregroundColor: textColor,
                            .paragraphStyle: block.paragraphStyle
                        ]
                    )
                )
            }
        }

        return result
    }

    private static func inlineAttributedString(
        from markdown: String,
        baseFont: UIFont,
        textColor: UIColor,
        paragraphStyle: NSParagraphStyle
    ) -> NSAttributedString {
        do {
            let options = AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace,
                failurePolicy: .returnPartiallyParsedIfPossible
            )
            let parsed = try AttributedString(markdown: markdown, options: options)
            let attributed = NSMutableAttributedString(attributedString: NSAttributedString(parsed))
            let fullRange = NSRange(location: 0, length: attributed.length)

            attributed.addAttribute(.foregroundColor, value: textColor, range: fullRange)
            attributed.addAttribute(.font, value: baseFont, range: fullRange)
            attributed.addAttribute(.paragraphStyle, value: paragraphStyle, range: fullRange)
            applyInlineMarkdownStyles(to: attributed, baseFont: baseFont)
            return attributed
        } catch {
            return NSAttributedString(
                string: markdown,
                attributes: [
                    .foregroundColor: textColor,
                    .font: baseFont,
                    .paragraphStyle: paragraphStyle
                ]
            )
        }
    }

    private struct BlockStyle {
        let text: String
        let font: UIFont
        let paragraphStyle: NSParagraphStyle
    }

    private static func blockStyle(for line: String, baseFont: UIFont) -> BlockStyle {
        if let heading = heading(in: line) {
            let font = headingFont(level: heading.level, baseFont: baseFont)
            return BlockStyle(
                text: heading.text,
                font: font,
                paragraphStyle: paragraphStyle(for: font, paragraphSpacing: 0)
            )
        }

        return BlockStyle(
            text: line,
            font: baseFont,
            paragraphStyle: paragraphStyle(for: baseFont, paragraphSpacing: 0)
        )
    }

    private static func heading(in line: String) -> (level: Int, text: String)? {
        var index = line.startIndex
        var level = 0

        while index < line.endIndex, line[index] == "#", level < 6 {
            level += 1
            index = line.index(after: index)
        }

        guard level > 0, index < line.endIndex, line[index].isWhitespace else { return nil }

        let textStart = line[index...].firstIndex { !$0.isWhitespace } ?? line.endIndex
        let text = String(line[textStart...]).trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        return (level, text)
    }

    private static func headingFont(level: Int, baseFont: UIFont) -> UIFont {
        let multiplier: CGFloat
        switch level {
        case 1:
            multiplier = 1.55
        case 2:
            multiplier = 1.38
        case 3:
            multiplier = 1.22
        case 4:
            multiplier = 1.12
        default:
            multiplier = 1.0
        }

        return UIFont.systemFont(ofSize: baseFont.pointSize * multiplier, weight: .semibold)
    }

    private static func paragraphStyle(for font: UIFont, paragraphSpacing: CGFloat) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byCharWrapping
        style.lineSpacing = 2
        style.paragraphSpacing = paragraphSpacing
        style.paragraphSpacingBefore = 0
        return style
    }

    private static func applyInlineMarkdownStyles(to attributed: NSMutableAttributedString, baseFont: UIFont) {
        let fullRange = NSRange(location: 0, length: attributed.length)
        attributed.enumerateAttribute(.inlinePresentationIntent, in: fullRange) { value, range, _ in
            let rawValue = inlineIntentRawValue(from: value)
            guard rawValue != 0 else { return }

            if rawValue & 4 != 0 {
                attributed.addAttribute(.font, value: UIFont.monospacedSystemFont(ofSize: baseFont.pointSize, weight: .regular), range: range)
            } else {
                attributed.addAttribute(.font, value: font(for: rawValue, baseFont: baseFont), range: range)
            }

            if rawValue & 32 != 0 {
                attributed.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
            }
        }
    }

    private static func inlineIntentRawValue(from value: Any?) -> Int {
        switch value {
        case let number as NSNumber:
            return number.intValue
        case let intent as InlinePresentationIntent:
            return Int(intent.rawValue)
        default:
            return 0
        }
    }

    private static func font(for rawValue: Int, baseFont: UIFont) -> UIFont {
        let isEmphasized = rawValue & 1 != 0
        let isStrong = rawValue & 2 != 0

        if isEmphasized, isStrong,
           let descriptor = baseFont.fontDescriptor.withSymbolicTraits([.traitBold, .traitItalic]) {
            return UIFont(descriptor: descriptor, size: baseFont.pointSize)
        }

        if isStrong {
            return UIFont.systemFont(ofSize: baseFont.pointSize, weight: .semibold)
        }

        if isEmphasized,
           let descriptor = baseFont.fontDescriptor.withSymbolicTraits(.traitItalic) {
            return UIFont(descriptor: descriptor, size: baseFont.pointSize)
        }

        return baseFont
    }
}
