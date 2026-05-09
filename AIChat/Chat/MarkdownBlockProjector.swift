import Foundation

nonisolated struct ProjectedMarkdownBlock: Hashable, Sendable {
    let keySuffix: String
    let kind: ChatItem.Kind
    let text: String
    let copyText: String
}

nonisolated enum MarkdownBlockProjector {
    static func project(_ markdown: String) -> [ProjectedMarkdownBlock] {
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard !lines.isEmpty else { return [] }

        var projected: [ProjectedMarkdownBlock] = []
        var paragraphLines: [String] = []
        var quoteLines: [String] = []
        var listDisplayLines: [String] = []
        var listRawLines: [String] = []

        func flushParagraph() {
            guard !paragraphLines.isEmpty else { return }
            let text = paragraphLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            paragraphLines.removeAll(keepingCapacity: true)
            guard !text.isEmpty else { return }
            projected.append(
                ProjectedMarkdownBlock(
                    keySuffix: "paragraph-\(projected.count)",
                    kind: .markdown,
                    text: text,
                    copyText: text
                )
            )
        }

        func flushQuote() {
            guard !quoteLines.isEmpty else { return }
            let text = quoteLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            quoteLines.removeAll(keepingCapacity: true)
            guard !text.isEmpty else { return }
            projected.append(
                ProjectedMarkdownBlock(
                    keySuffix: "quote-\(projected.count)",
                    kind: .quote,
                    text: text,
                    copyText: text
                )
            )
        }

        func flushList() {
            guard !listDisplayLines.isEmpty else { return }
            let displayText = listDisplayLines.joined(separator: "\n")
            let copyText = listRawLines.joined(separator: "\n")
            listDisplayLines.removeAll(keepingCapacity: true)
            listRawLines.removeAll(keepingCapacity: true)
            projected.append(
                ProjectedMarkdownBlock(
                    keySuffix: "list-\(projected.count)",
                    kind: .list,
                    text: displayText,
                    copyText: copyText
                )
            )
        }

        func flushStructuredBuffers() {
            flushParagraph()
            flushQuote()
            flushList()
        }

        var index = 0
        while index < lines.count {
            let line = lines[index]

            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                flushStructuredBuffers()
                index += 1
                continue
            }

            if let table = table(at: index, in: lines) {
                flushStructuredBuffers()
                projected.append(
                    ProjectedMarkdownBlock(
                        keySuffix: "table-\(projected.count)",
                        kind: .table(columns: table.columnCount, alignments: table.alignments),
                        text: table.serializedDisplayText,
                        copyText: table.rawMarkdown
                    )
                )
                index += table.consumedLineCount
                continue
            }

            if let heading = heading(in: line) {
                flushStructuredBuffers()
                projected.append(
                    ProjectedMarkdownBlock(
                        keySuffix: "heading-\(heading.level)-\(projected.count)",
                        kind: .heading(level: heading.level),
                        text: heading.text,
                        copyText: line
                    )
                )
                index += 1
                continue
            }

            if let quoteText = quoteContent(in: line) {
                flushParagraph()
                flushList()
                quoteLines.append(quoteText)
                index += 1
                continue
            }

            if let listItem = listItem(in: line) {
                flushParagraph()
                flushQuote()
                listDisplayLines.append(listItem.displayText)
                listRawLines.append(listItem.rawText)
                index += 1
                continue
            }

            flushQuote()
            flushList()
            paragraphLines.append(line)
            index += 1
        }

        flushStructuredBuffers()
        return projected
    }

    private static func heading(in line: String) -> (level: Int, text: String)? {
        var index = line.startIndex
        while index < line.endIndex, line[index].isWhitespace {
            index = line.index(after: index)
        }

        if line[index...].hasPrefix("---") {
            while index < line.endIndex, line[index] == "-" {
                index = line.index(after: index)
            }
            while index < line.endIndex, line[index].isWhitespace {
                index = line.index(after: index)
            }
        }

        var level = 0
        while index < line.endIndex, line[index] == "#", level < 6 {
            level += 1
            index = line.index(after: index)
        }

        guard level > 0, index < line.endIndex, line[index].isWhitespace else { return nil }

        let textStart = line[index...].firstIndex { !$0.isWhitespace } ?? line.endIndex
        let text = String(line[textStart...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return (level, text)
    }

    private static func quoteContent(in line: String) -> String? {
        var index = line.startIndex
        while index < line.endIndex, line[index].isWhitespace {
            index = line.index(after: index)
        }

        guard index < line.endIndex, line[index] == ">" else { return nil }
        index = line.index(after: index)
        if index < line.endIndex, line[index] == " " {
            index = line.index(after: index)
        }
        return String(line[index...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private struct ListItemMatch {
        let displayText: String
        let rawText: String
    }

    private static func listItem(in line: String) -> ListItemMatch? {
        let leadingWhitespaceCount = line.prefix { $0 == " " || $0 == "\t" }.reduce(0) { partialResult, character in
            partialResult + (character == "\t" ? 4 : 1)
        }
        let indentLevel = max(0, leadingWhitespaceCount / 2)
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        let unorderedMarkers = ["- ", "* ", "+ "]
        for marker in unorderedMarkers where trimmed.hasPrefix(marker) {
            let body = String(trimmed.dropFirst(marker.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { return nil }
            let prefix = String(repeating: "  ", count: indentLevel) + "• "
            return ListItemMatch(displayText: prefix + body, rawText: line)
        }

        let digits = trimmed.prefix { $0.isNumber }
        if !digits.isEmpty,
           trimmed.count > digits.count + 1 {
            let markerStart = trimmed.index(trimmed.startIndex, offsetBy: digits.count)
            let marker = trimmed[markerStart]
            let bodyStart = trimmed.index(after: markerStart)
            if (marker == "." || marker == ")"),
               bodyStart < trimmed.endIndex,
               trimmed[bodyStart] == " " {
                let contentStart = trimmed.index(after: bodyStart)
                let body = String(trimmed[contentStart...]).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !body.isEmpty else { return nil }
                let prefix = String(repeating: "  ", count: indentLevel) + "\(digits). "
                return ListItemMatch(displayText: prefix + body, rawText: line)
            }
        }

        return nil
    }

    private struct TableMatch {
        let serializedDisplayText: String
        let rawMarkdown: String
        let columnCount: Int
        let alignments: [TableColumnAlignment]
        let consumedLineCount: Int
    }

    private static func table(at startIndex: Int, in lines: [String]) -> TableMatch? {
        guard startIndex + 1 < lines.count else { return nil }

        let headerCells = tableCells(in: lines[startIndex])
        let delimiterCells = tableCells(in: lines[startIndex + 1])

        guard headerCells.count >= 2,
              headerCells.count == delimiterCells.count,
              isTableDelimiterRow(delimiterCells)
        else {
            return nil
        }

        var rows = [headerCells]
        var rawLines = [lines[startIndex], lines[startIndex + 1]]
        var consumed = 2
        var cursor = startIndex + 2

        while cursor < lines.count {
            let line = lines[cursor]
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                break
            }

            guard let cells = tableCellsIfPotentialRow(in: line) else {
                break
            }

            rows.append(normalizeTableRow(cells, columnCount: headerCells.count))
            rawLines.append(line)
            consumed += 1
            cursor += 1
        }

        let serialized = rows
            .map { $0.joined(separator: "\t") }
            .joined(separator: "\n")

        return TableMatch(
            serializedDisplayText: serialized,
            rawMarkdown: rawLines.joined(separator: "\n"),
            columnCount: headerCells.count,
            alignments: delimiterCells.map(tableAlignment(in:)),
            consumedLineCount: consumed
        )
    }

    private static func tableCellsIfPotentialRow(in line: String) -> [String]? {
        let cells = tableCells(in: line)
        return cells.count >= 2 ? cells : nil
    }

    private static func tableCells(in line: String) -> [String] {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("|") {
            trimmed.removeFirst()
        }
        if trimmed.hasSuffix("|") {
            trimmed.removeLast()
        }

        let parts = trimmed.split(separator: "|", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return parts.count >= 2 ? parts : []
    }

    private static func isTableDelimiterRow(_ cells: [String]) -> Bool {
        cells.allSatisfy { cell in
            let trimmed = cell.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return false }
            let stripped = trimmed.replacingOccurrences(of: ":", with: "")
            return stripped.count >= 3 && stripped.allSatisfy { $0 == "-" }
        }
    }

    private static func tableAlignment(in cell: String) -> TableColumnAlignment {
        let trimmed = cell.trimmingCharacters(in: .whitespaces)
        switch (trimmed.hasPrefix(":"), trimmed.hasSuffix(":")) {
        case (true, true):
            return .center
        case (false, true):
            return .trailing
        default:
            return .leading
        }
    }

    private static func normalizeTableRow(_ row: [String], columnCount: Int) -> [String] {
        if row.count == columnCount {
            return row
        }

        if row.count > columnCount {
            return Array(row.prefix(columnCount))
        }

        return row + Array(repeating: "", count: columnCount - row.count)
    }
}
