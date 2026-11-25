import SwiftUI
import AppKit
import GoLensFoundation

struct AlignedLine: Identifiable {
    let id: String
    let leftLineNum: Int?
    let leftContent: String?
    let rightLineNum: Int?
    let rightContent: String?
    let leftAttributed: AttributedString
    let rightAttributed: AttributedString
    let type: LineType
    var leftRef: GitPatchLineRef? = nil
    var rightRef: GitPatchLineRef? = nil
    var targetNewLine: Int = 1

    enum LineType: Equatable {
        case normal
        case added
        case deleted
        case modified
    }

    func leftBgColor() -> Color {
        switch type {
        case .deleted:
            return StatusTone.failure.fill
        case .modified:
            return StatusTone.failure.tint.opacity(0.11)
        default:
            return Color.clear
        }
    }

    func rightBgColor() -> Color {
        switch type {
        case .added:
            return StatusTone.success.fill
        case .modified:
            return StatusTone.success.tint.opacity(0.11)
        default:
            return Color.clear
        }
    }

    func leftGutterBarColor() -> Color {
        switch type {
        case .deleted, .modified:
            return StatusTone.failure.tint
        default:
            return Color.clear
        }
    }

    func rightGutterBarColor() -> Color {
        switch type {
        case .added, .modified:
            return StatusTone.success.tint
        default:
            return Color.clear
        }
    }

    func leftPrefixSymbol() -> String {
        switch type {
        case .deleted, .modified:
            return "-"
        default:
            return " "
        }
    }

    func rightPrefixSymbol() -> String {
        switch type {
        case .added, .modified:
            return "+"
        default:
            return " "
        }
    }

    func leftPrefixColor() -> Color {
        switch type {
        case .deleted, .modified:
            return StatusTone.failure.tint
        default:
            return .secondary
        }
    }

    func rightPrefixColor() -> Color {
        switch type {
        case .added, .modified:
            return StatusTone.success.tint
        default:
            return .secondary
        }
    }

    func unifiedBgColor() -> Color {
        switch type {
        case .added:
            return StatusTone.success.fill
        case .deleted:
            return StatusTone.failure.fill
        case .modified:
            return StatusTone.success.tint.opacity(0.12)
        default:
            return Color.clear
        }
    }

    func unifiedPrefix() -> String {
        switch type {
        case .added: return "+"
        case .deleted: return "-"
        default: return " "
        }
    }

    static func makeAttributedPair(
        left: String?,
        right: String?,
        type: LineType,
        baseTextColor: Color
    ) -> (AttributedString, AttributedString) {
        let rawLeft = left ?? " "
        let rawRight = right ?? " "

        var leftAttr = AttributedString(rawLeft.isEmpty ? " " : rawLeft)
        leftAttr.foregroundColor = baseTextColor

        var rightAttr = AttributedString(rawRight.isEmpty ? " " : rawRight)
        rightAttr.foregroundColor = baseTextColor

        if type == .modified, let l = left, let r = right, l != r, l.utf8.count <= 400, r.utf8.count <= 400 {
            let (lStart, lEnd, rStart, rEnd) = changedSpans(left: l, right: r)
            if lStart < lEnd,
               let lower = leftAttr.index(leftAttr.startIndex, offsetByCharacters: lStart),
               let upper = leftAttr.index(leftAttr.startIndex, offsetByCharacters: lEnd),
               lower < upper {
                leftAttr[lower..<upper].backgroundColor = StatusTone.failure.tint.opacity(0.30)
            }
            if rStart < rEnd,
               let lower = rightAttr.index(rightAttr.startIndex, offsetByCharacters: rStart),
               let upper = rightAttr.index(rightAttr.startIndex, offsetByCharacters: rEnd),
               lower < upper {
                rightAttr[lower..<upper].backgroundColor = StatusTone.success.tint.opacity(0.30)
            }
        }
        return (leftAttr, rightAttr)
    }

    private static func changedSpans(left: String, right: String) -> (Int, Int, Int, Int) {
        let lChars = Array(left)
        let rChars = Array(right)
        var prefix = 0
        let minLen = min(lChars.count, rChars.count)
        while prefix < minLen && lChars[prefix] == rChars[prefix] {
            prefix += 1
        }
        var lSuffix = lChars.count
        var rSuffix = rChars.count
        while lSuffix > prefix && rSuffix > prefix && lChars[lSuffix - 1] == rChars[rSuffix - 1] {
            lSuffix -= 1
            rSuffix -= 1
        }
        return (prefix, lSuffix, prefix, rSuffix)
    }
}

extension AttributedString {
    fileprivate func index(_ i: AttributedString.Index, offsetByCharacters distance: Int) -> AttributedString.Index? {
        guard distance >= 0 else { return nil }
        return characters.index(i, offsetBy: distance, limitedBy: endIndex)
    }
}

struct ComputedDiffDisplayResult {
    let items: [DisplayDiffItem]
    let addedCount: Int
    let removedCount: Int
    let hunkAnchorIds: [String]
    let firstChangedLine: Int?
    let runRefs: [String: [GitPatchLineRef]]
    var estimatedOriginalWidth: CGFloat = 0
    var estimatedModifiedWidth: CGFloat = 0

    var estimatedUnifiedWidth: CGFloat {
        max(estimatedOriginalWidth, estimatedModifiedWidth)
    }
}

func buildDisplayDiffOffMainThread(
    diffOutput: String,
    hunks _: [GitDiffHunk] = [],
    collapseEnabled: Bool,
    expandedBlockIds: Set<String>,
    baseTextColor: Color
) -> ComputedDiffDisplayResult {
    buildDisplayDiffOffMainThread(
        files: GitPatchBuilder.parse(diffOutput),
        collapseEnabled: collapseEnabled,
        expandedBlockIds: expandedBlockIds,
        baseTextColor: baseTextColor
    )
}

func buildDisplayDiffOffMainThread(
    files: [GitFilePatch],
    collapseEnabled: Bool,
    expandedBlockIds: Set<String>,
    baseTextColor: Color
) -> ComputedDiffDisplayResult {
    var rawEntries: [(gapBefore: (start: Int, end: Int)?, line: AlignedLine)] = []
    var runStarts: [Int: (hunk: GitDiffHunk, refs: [GitPatchLineRef])] = [:]
    var addedCount = 0
    var removedCount = 0
    var firstChangedLine: Int? = nil

    var leftLineCounter = 1
    var rightLineCounter = 1

    var pendingDeletes: [(text: String, ref: GitPatchLineRef)] = []
    var pendingAdds: [(text: String, ref: GitPatchLineRef)] = []
    var pendingGap: (start: Int, end: Int)? = nil
    var currentSection = ""

    func displayText(_ text: String) -> String {
        text.hasSuffix("\r") ? String(text.dropLast()) : text
    }

    func flush() {
        let maxCount = max(pendingDeletes.count, pendingAdds.count)
        guard maxCount > 0 else { return }
        let oldStart = pendingDeletes.isEmpty ? leftLineCounter - 1 : leftLineCounter
        let newStart = pendingAdds.isEmpty ? rightLineCounter - 1 : rightLineCounter
        let section = currentSection.isEmpty ? "" : " \(currentSection)"
        runStarts[rawEntries.count] = (
            hunk: GitDiffHunk(
                oldStart: oldStart,
                oldCount: pendingDeletes.count,
                newStart: newStart,
                newCount: pendingAdds.count,
                removedLines: pendingDeletes.map { displayText($0.text) },
                addedLines: pendingAdds.map { displayText($0.text) },
                header: "@@ -\(oldStart),\(pendingDeletes.count) +\(newStart),\(pendingAdds.count) @@\(section)"
            ),
            refs: pendingDeletes.map { $0.ref } + pendingAdds.map { $0.ref }
        )

        for i in 0..<maxCount {
            let left = i < pendingDeletes.count ? pendingDeletes[i] : nil
            let right = i < pendingAdds.count ? pendingAdds[i] : nil
            let leftVal = left.map { displayText($0.text) }
            let rightVal = right.map { displayText($0.text) }

            let type: AlignedLine.LineType
            if leftVal != nil && rightVal != nil {
                type = .modified
                addedCount += 1
                removedCount += 1
            } else if leftVal != nil {
                type = .deleted
                removedCount += 1
            } else {
                type = .added
                addedCount += 1
            }

            let lNum = leftVal != nil ? leftLineCounter : nil
            let rNum = rightVal != nil ? rightLineCounter : nil
            let jumpTarget = rNum ?? max(1, newStart)
            if firstChangedLine == nil {
                firstChangedLine = jumpTarget
            }
            let rowId = "row-\(rawEntries.count)-\(lNum ?? -1)-\(rNum ?? -1)"
            let (lAttr, rAttr) = AlignedLine.makeAttributedPair(
                left: leftVal,
                right: rightVal,
                type: type,
                baseTextColor: baseTextColor
            )

            let alignedLine = AlignedLine(
                id: rowId,
                leftLineNum: lNum,
                leftContent: leftVal,
                rightLineNum: rNum,
                rightContent: rightVal,
                leftAttributed: lAttr,
                rightAttributed: rAttr,
                type: type,
                leftRef: left?.ref,
                rightRef: right?.ref,
                targetNewLine: jumpTarget
            )
            rawEntries.append((gapBefore: pendingGap, line: alignedLine))
            pendingGap = nil

            if leftVal != nil { leftLineCounter += 1 }
            if rightVal != nil { rightLineCounter += 1 }
        }
        pendingDeletes.removeAll()
        pendingAdds.removeAll()
    }

    for (h, hunk) in files.flatMap(\.hunks).enumerated() {
        flush()
        let targetOld = hunk.oldCount == 0 ? hunk.oldStart + 1 : max(1, hunk.oldStart)
        let targetNew = hunk.newCount == 0 ? hunk.newStart + 1 : max(1, hunk.newStart)
        if targetOld > leftLineCounter {
            pendingGap = (start: leftLineCounter, end: targetOld - 1)
        }
        leftLineCounter = targetOld
        rightLineCounter = targetNew
        currentSection = hunk.section

        for (l, patchLine) in hunk.lines.enumerated() {
            let ref = GitPatchLineRef(hunk: h, line: l)
            switch patchLine.kind {
            case .removed:
                pendingDeletes.append((patchLine.text, ref))
            case .added:
                pendingAdds.append((patchLine.text, ref))
            case .context:
                flush()
                let content = displayText(patchLine.text)
                let rowId = "row-\(rawEntries.count)-\(leftLineCounter)-\(rightLineCounter)"
                let (lAttr, rAttr) = AlignedLine.makeAttributedPair(
                    left: content,
                    right: content,
                    type: .normal,
                    baseTextColor: baseTextColor
                )
                let alignedLine = AlignedLine(
                    id: rowId,
                    leftLineNum: leftLineCounter,
                    leftContent: content,
                    rightLineNum: rightLineCounter,
                    rightContent: content,
                    leftAttributed: lAttr,
                    rightAttributed: rAttr,
                    type: .normal,
                    targetNewLine: rightLineCounter
                )
                rawEntries.append((gapBefore: pendingGap, line: alignedLine))
                pendingGap = nil
                leftLineCounter += 1
                rightLineCounter += 1
            }
        }
    }
    flush()

    let alignedLines = rawEntries.map { $0.line }
    guard !alignedLines.isEmpty else {
        return ComputedDiffDisplayResult(items: [], addedCount: 0, removedCount: 0, hunkAnchorIds: [], firstChangedLine: nil, runRefs: [:])
    }

    let contextRadius = 3
    var isNearChange = Array(repeating: !collapseEnabled, count: alignedLines.count)
    if collapseEnabled {
        for idx in alignedLines.indices where alignedLines[idx].type != .normal {
            let low = max(0, idx - contextRadius)
            let high = min(alignedLines.count - 1, idx + contextRadius)
            for k in low...high {
                isNearChange[k] = true
            }
        }
    }

    var items: [DisplayDiffItem] = []
    var hunkAnchorIds: [String] = []
    var runRefs: [String: [GitPatchLineRef]] = [:]
    var i = 0

    while i < alignedLines.count {
        if let gap = rawEntries[i].gapBefore {
            let gapId = "gap-\(gap.start)-\(gap.end)"
            let gapCount = max(1, gap.end - gap.start + 1)
            if collapseEnabled && !expandedBlockIds.contains(gapId) {
                items.append(.collapsedBlock(
                    id: gapId,
                    lineCount: gapCount,
                    startLine: gap.start,
                    endLine: gap.end
                ))
            }
        }

        let line = alignedLines[i]
        if !isNearChange[i] {
            var end = i
            while end + 1 < alignedLines.count && !isNearChange[end + 1] && rawEntries[end + 1].gapBefore == nil {
                end += 1
            }
            let count = end - i + 1
            let blockId = "collapse-\(i)-\(end)"
            if count >= 4 && !expandedBlockIds.contains(blockId) {
                let firstLeft = alignedLines[i].leftLineNum ?? alignedLines[i].rightLineNum ?? (i + 1)
                let lastLeft = alignedLines[end].leftLineNum ?? alignedLines[end].rightLineNum ?? (end + 1)
                items.append(.collapsedBlock(
                    id: blockId,
                    lineCount: count,
                    startLine: firstLeft,
                    endLine: lastLeft
                ))
                i = end + 1
                continue
            }
        }

        if let run = runStarts[i] {
            let anchorId = "hunk-anchor-\(hunkAnchorIds.count)"
            hunkAnchorIds.append(anchorId)
            runRefs[anchorId] = run.refs
            items.append(.hunkHeader(
                id: anchorId,
                ordinal: hunkAnchorIds.count,
                leftStart: line.leftLineNum,
                rightStart: line.rightLineNum,
                hunk: run.hunk
            ))
        }

        items.append(.line(line))
        i += 1
    }

    var originalLines: [String] = []
    var modifiedLines: [String] = []
    originalLines.reserveCapacity(items.count)
    modifiedLines.reserveCapacity(items.count)
    for item in items {
        if case .line(let line) = item {
            if let left = line.leftContent {
                originalLines.append(left)
            }
            if let right = line.rightContent {
                modifiedLines.append(right)
            }
        }
    }
    let estimatedOriginal = DiffHorizontalScrollMetrics.estimatedColumnWidth(lines: originalLines)
    let estimatedModified = DiffHorizontalScrollMetrics.estimatedColumnWidth(lines: modifiedLines)

    return ComputedDiffDisplayResult(
        items: items,
        addedCount: addedCount,
        removedCount: removedCount,
        hunkAnchorIds: hunkAnchorIds,
        firstChangedLine: firstChangedLine,
        runRefs: runRefs,
        estimatedOriginalWidth: estimatedOriginal,
        estimatedModifiedWidth: estimatedModified
    )
}

