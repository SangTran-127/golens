import AppKit
import CoreGraphics
import Foundation

public struct DiffHorizontalScrollMetrics: Equatable, Sendable {
    public var contentWidth: CGFloat
    public var viewportWidth: CGFloat
    public var offset: CGFloat

    public init(contentWidth: CGFloat, viewportWidth: CGFloat, offset: CGFloat) {
        self.contentWidth = contentWidth
        self.viewportWidth = viewportWidth
        self.offset = offset
    }

    public var maxOffset: CGFloat {
        max(0, contentWidth - viewportWidth)
    }

    public var needsScrollbar: Bool {
        viewportWidth > 1 && maxOffset > 1
    }

    public var clampedOffset: CGFloat {
        clamped(offset)
    }

    public func clamped(_ candidate: CGFloat) -> CGFloat {
        min(max(0, candidate), maxOffset)
    }

    public var knobProportion: CGFloat {
        guard contentWidth > 0, viewportWidth > 0, needsScrollbar else { return 1 }
        return min(1, max(0.06, viewportWidth / contentWidth))
    }

    public var normalizedValue: Double {
        guard maxOffset > 0 else { return 0 }
        return Double(clampedOffset / maxOffset)
    }

    public static func offset(fromNormalized value: Double, maxOffset: CGFloat) -> CGFloat {
        min(max(0, CGFloat(value) * maxOffset), maxOffset)
    }

    public static func steppedOffset(
        current: CGFloat,
        maxOffset: CGFloat,
        viewportWidth: CGFloat,
        part: NSScroller.Part
    ) -> CGFloat? {
        let pageStep = max(40, viewportWidth * 0.85)
        switch part {
        case .decrementPage:
            return max(0, current - pageStep)
        case .incrementPage:
            return min(maxOffset, current + pageStep)
        default:
            return nil
        }
    }

    public static func wheelAdjustedOffset(
        current: CGFloat,
        maxOffset: CGFloat,
        scrollingDeltaX: CGFloat,
        scrollingDeltaY: CGFloat,
        isPrecise: Bool,
        shiftHeld: Bool
    ) -> (newOffset: CGFloat, consumedVerticalAsHorizontal: Bool)? {
        if abs(scrollingDeltaX) > 0.01 {
            let delta = isPrecise ? scrollingDeltaX : scrollingDeltaX * 12
            return (min(max(0, current - delta), maxOffset), false)
        }
        if shiftHeld && abs(scrollingDeltaY) > 0.01 {
            let delta = isPrecise ? scrollingDeltaY : scrollingDeltaY * 12
            return (min(max(0, current - delta), maxOffset), true)
        }
        return nil
    }

    public static func estimatedColumnWidth(
        lines: [String],
        trailingPadding: CGFloat = 16,
        safetyMargin: CGFloat = 4
    ) -> CGFloat {
        guard !lines.isEmpty else { return 0 }
        var topCandidates: [(score: Int, text: String)] = []
        topCandidates.reserveCapacity(4)

        for line in lines where !line.isEmpty {
            var tabCount = 0
            for byte in line.utf8 where byte == 0x09 {
                tabCount += 1
            }
            let score = line.utf16.count + tabCount * 7
            if topCandidates.count < 4 {
                topCandidates.append((score, line))
                topCandidates.sort { $0.score > $1.score }
            } else if let smallest = topCandidates.last, score > smallest.score {
                topCandidates[topCandidates.count - 1] = (score, line)
                topCandidates.sort { $0.score > $1.score }
            }
        }

        guard !topCandidates.isEmpty else { return 0 }
        let font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        var widest: CGFloat = 0
        for candidate in topCandidates {
            let width = (candidate.text as NSString).size(withAttributes: attributes).width
            if width > widest {
                widest = width
            }
        }
        return ceil(widest) + trailingPadding + safetyMargin
    }
}
