import AppKit
import GoLensFoundation
import SwiftUI

struct UnifiedDiffTextView: View {
    let items: [DisplayDiffItem]
    let estimatedWidth: CGFloat
    var resetKey = ""
    var scrollerAccessibilityLabel = "Diff Horizontal Scrollbar"

    @State private var horizontalScrollX: CGFloat = 0
    @State private var diffViewportWidth: CGFloat = 0
    @State private var measuredDiffWidth: CGFloat = 0

    static let gutterWidth: CGFloat = 3 + 40 + Spacing.standard + 40 + Spacing.standard + 16

    var body: some View {
        let contentWidth = max(estimatedWidth, measuredDiffWidth)
        let metrics = DiffHorizontalScrollMetrics(
            contentWidth: contentWidth,
            viewportWidth: diffViewportWidth,
            offset: horizontalScrollX
        )
        let scrollerHeight = NSScroller.scrollerWidth(for: .small, scrollerStyle: .legacy)
        VStack(spacing: 0) {
            ScrollView(.vertical) {
                UnifiedDiffRows(
                    items: items,
                    contentWidth: contentWidth,
                    scrollOffset: horizontalScrollX,
                    onViewportWidthChange: { width in
                        diffViewportWidth = width
                        horizontalScrollX = DiffHorizontalScrollMetrics(
                            contentWidth: max(estimatedWidth, measuredDiffWidth),
                            viewportWidth: width,
                            offset: horizontalScrollX
                        ).clampedOffset
                    },
                    onMeasuredWidthChange: { width in
                        if width > measuredDiffWidth { measuredDiffWidth = width }
                    }
                )
            }
            .background(
                DiffHorizontalWheelCatcher(
                    mode: .single,
                    leadingMetrics: metrics,
                    trailingMetrics: DiffHorizontalScrollMetrics(contentWidth: 0, viewportWidth: 0, offset: 0),
                    onLeadingOffsetChange: { horizontalScrollX = metrics.clamped($0) },
                    onTrailingOffsetChange: { _ in }
                )
            )
            .background(Color(nsColor: .textBackgroundColor))

            if metrics.needsScrollbar {
                HStack(spacing: 0) {
                    Color.clear.frame(width: Self.gutterWidth)
                    DiffHorizontalScroller(
                        metrics: metrics,
                        accessibilityLabel: scrollerAccessibilityLabel
                    ) { newOffset in
                        horizontalScrollX = metrics.clamped(newOffset)
                    }
                }
                .frame(height: scrollerHeight + Spacing.hairline * 2)
                .background(Color(nsColor: .controlBackgroundColor))
                .overlay(alignment: .top) { Divider() }
            }
        }
        .onChange(of: resetKey) { _, _ in
            horizontalScrollX = 0
            measuredDiffWidth = 0
        }
    }
}

struct UnifiedDiffRows: View {
    let items: [DisplayDiffItem]
    let contentWidth: CGFloat
    let scrollOffset: CGFloat
    let onViewportWidthChange: (CGFloat) -> Void
    let onMeasuredWidthChange: (CGFloat) -> Void

    private struct DiffEntry: Identifiable {
        let id: String
        let left: Int?
        let right: Int?
        let prefix: String
        let text: AttributedString
        let kind: AlignedLine.LineType

        var tint: Color? {
            switch kind {
            case .added: return StatusTone.success.tint
            case .deleted: return StatusTone.failure.tint
            default: return nil
            }
        }
    }

    private func expandEntries(_ lines: [AlignedLine]) -> [DiffEntry] {
        var result: [DiffEntry] = []
        result.reserveCapacity(lines.count * 2)
        for line in lines {
            if line.type == .modified {
                result.append(DiffEntry(
                    id: "\(line.id)-del",
                    left: line.leftLineNum,
                    right: nil,
                    prefix: "-",
                    text: line.leftAttributed,
                    kind: .deleted
                ))
                result.append(DiffEntry(
                    id: "\(line.id)-add",
                    left: nil,
                    right: line.rightLineNum,
                    prefix: "+",
                    text: line.rightAttributed,
                    kind: .added
                ))
            } else {
                result.append(DiffEntry(
                    id: line.id,
                    left: line.leftLineNum,
                    right: line.rightLineNum,
                    prefix: line.unifiedPrefix(),
                    text: line.type == .deleted ? line.leftAttributed : line.rightAttributed,
                    kind: line.type
                ))
            }
        }
        return result
    }

    var body: some View {
        let blocks = DiffRenderBlock.grouped(from: items)
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(blocks) { block in
                switch block {
                case .collapsed(_, let count, let startLine, let endLine):
                    gapBanner(count: count, startLine: startLine, endLine: endLine)
                case .hunk(_, let ordinal, let leftStart, let rightStart, _):
                    hunkBanner(ordinal: ordinal, line: rightStart ?? leftStart ?? 1)
                case .lines(_, let lines):
                    let entries = expandEntries(lines)
                    let blockHeight = CGFloat(entries.count) * 20
                    HStack(spacing: 0) {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(entries) { entry in
                                HStack(spacing: 0) {
                                    Rectangle()
                                        .fill(entry.tint ?? .clear)
                                        .frame(width: 3)
                                    Text(entry.left.map(String.init) ?? "")
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                                        .frame(width: 40, alignment: .trailing)
                                        .padding(.trailing, Spacing.standard)
                                    Text(entry.right.map(String.init) ?? "")
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                                        .frame(width: 40, alignment: .trailing)
                                        .padding(.trailing, Spacing.standard)
                                    Text(entry.prefix)
                                        .font(.caption.monospaced())
                                        .foregroundStyle(entry.tint ?? .secondary)
                                        .frame(width: 16, alignment: .center)
                                }
                                .frame(height: 20)
                                .background(entry.tint.map { $0.opacity(0.13) } ?? .clear)
                                .accessibilityHidden(true)
                            }
                        }

                        DiffCodeViewport(
                            blockHeight: blockHeight,
                            contentWidth: contentWidth,
                            scrollOffset: scrollOffset,
                            onViewportWidthChange: onViewportWidthChange,
                            onMeasuredWidthChange: onMeasuredWidthChange
                        ) {
                            ForEach(entries) { entry in
                                Text(entry.text)
                                    .font(.body.monospaced())
                                    .fixedSize(horizontal: true, vertical: false)
                                    .textSelection(.enabled)
                                    .padding(.trailing, Spacing.comfortable)
                                    .frame(maxWidth: .infinity, minHeight: 20, maxHeight: 20, alignment: .leading)
                                    .background(entry.tint.map { $0.opacity(0.13) } ?? .clear)
                                    .accessibilityElement(children: .ignore)
                                    .accessibilityLabel(Self.accessibilityLabel(kind: entry.kind, left: entry.left, right: entry.right, text: entry.text))
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(.bottom, Spacing.standard)
    }

    private func hunkBanner(ordinal: Int, line: Int) -> some View {
        HStack(spacing: Spacing.standard) {
            Text("Change #\(ordinal)")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, Spacing.row)
                .padding(.vertical, Spacing.hairline)
                .background(Color.accentColor.opacity(0.12), in: Capsule())
            Text("Line \(line)")
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, Spacing.section)
        .padding(.vertical, Spacing.compact)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.05))
        .overlay(alignment: .top) { Divider().opacity(0.6) }
        .overlay(alignment: .bottom) { Divider().opacity(0.6) }
        .accessibilityElement(children: .combine)
    }

    private func gapBanner(count: Int, startLine: Int, endLine: Int) -> some View {
        HStack(spacing: Spacing.standard) {
            Image(systemName: "ellipsis")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("\(count) unchanged lines (Lines \(startLine)–\(endLine))")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, Spacing.section)
        .padding(.vertical, Spacing.compact)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .quaternarySystemFill))
    }

    private static func accessibilityLabel(kind: AlignedLine.LineType, left: Int?, right: Int?, text: AttributedString) -> String {
        let content = String(text.characters).trimmingCharacters(in: .whitespaces)
        switch kind {
        case .added: return "Added line \(right ?? 0): \(content)"
        case .deleted: return "Removed line \(left ?? 0): \(content)"
        default: return "Line \(right ?? left ?? 0): \(content)"
        }
    }
}
