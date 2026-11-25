import CoreGraphics
import Foundation

public struct GitBranchSummary: Identifiable, Equatable, Hashable, Sendable {
    public let name: String
    public let author: String
    public let date: Date?

    public var id: String { name }

    public init(name: String, author: String, date: Date?) {
        self.name = name
        self.author = author
        self.date = date
    }

    public static let refFormat = "%(refname:short)%00%(authorname)%00%(committerdate:unix)"

    public static func parseForEachRef(_ output: String) -> [GitBranchSummary] {
        output.split(separator: "\n").compactMap { line in
            let parts = String(line).split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 3 else { return nil }
            let branchName = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !branchName.isEmpty else { return nil }
            let timestamp = TimeInterval(parts[2]).map { Date(timeIntervalSince1970: $0) }
            return GitBranchSummary(name: branchName, author: parts[1], date: timestamp)
        }
    }

    public static func resolveEffectiveBranches(
        currentBranch: String,
        loaded: [GitBranchSummary],
        cached: [GitBranchSummary],
        knownBranchNames: [String]
    ) -> [GitBranchSummary] {
        let base: [GitBranchSummary]
        if !loaded.isEmpty {
            base = loaded
        } else if !cached.isEmpty {
            base = cached
        } else if !knownBranchNames.isEmpty {
            base = knownBranchNames.map { GitBranchSummary(name: $0, author: "", date: nil) }
        } else if !currentBranch.isEmpty {
            return [GitBranchSummary(name: currentBranch, author: "", date: nil)]
        } else {
            return []
        }

        guard !currentBranch.isEmpty,
              currentBranch != "Detached HEAD",
              currentBranch != "No Branch",
              !base.contains(where: { $0.name == currentBranch }) else {
            return base
        }
        return [GitBranchSummary(name: currentBranch, author: "", date: nil)] + base
    }
}

public enum ToolbarClusterMetrics {
    public static let reservedBaseChrome: CGFloat = 184
    public static let reservedIssuesChrome: CGFloat = 72
    public static let minUsableWidth: CGFloat = 320
    public static let titleHardMinWidth: CGFloat = 104
    public static let titleCompactMinWidth: CGFloat = 140
    public static let titleMaxWidthCap: CGFloat = 360
    public static let titleShareRatio: CGFloat = 0.38
    public static let pillMinWidth: CGFloat = 236
    public static let pillMaxWidthCap: CGFloat = 440

    public struct ResolvedWidths: Equatable, Sendable {
        public let usableWidth: CGFloat
        public let titleMaxWidth: CGFloat
        public let pillWidth: CGFloat

        public init(usableWidth: CGFloat, titleMaxWidth: CGFloat, pillWidth: CGFloat) {
            self.usableWidth = usableWidth
            self.titleMaxWidth = titleMaxWidth
            self.pillWidth = pillWidth
        }
    }

    public static func resolve(availableWidth: CGFloat, hasIssues: Bool) -> ResolvedWidths {
        let reservedChrome = reservedBaseChrome + (hasIssues ? reservedIssuesChrome : 0)
        let usableWidth = max(minUsableWidth, availableWidth - reservedChrome)
        let maxTitleWithoutCrowdingPill = max(titleHardMinWidth, usableWidth - pillMinWidth)
        let preferredTitle = max(titleCompactMinWidth, floor(usableWidth * titleShareRatio))
        let titleMaxWidth = min(titleMaxWidthCap, min(maxTitleWithoutCrowdingPill, preferredTitle))
        let pillWidth = min(pillMaxWidthCap, max(pillMinWidth, floor(usableWidth - titleMaxWidth)))
        return ResolvedWidths(usableWidth: usableWidth, titleMaxWidth: titleMaxWidth, pillWidth: pillWidth)
    }
}

public enum BranchPopoverLayoutMath {
    public static let popoverWidth: CGFloat = 360
    public static let minListHeight: CGFloat = 56
    public static let maxListHeight: CGFloat = 340
    public static let sectionHeaderHeight: CGFloat = 24
    public static let singleLineRowHeight: CGFloat = 30
    public static let twoLineRowHeight: CGFloat = 44
    public static let emptyStateHeight: CGFloat = 44
    public static let interItemSpacing: CGFloat = 2

    public static func estimatedListHeight(
        currentBranch: GitBranchSummary?,
        otherBranches: [GitBranchSummary]
    ) -> CGFloat {
        if currentBranch == nil && otherBranches.isEmpty {
            return max(minListHeight, emptyStateHeight)
        }
        var total: CGFloat = 0
        var itemCount = 0
        if let currentBranch {
            total += sectionHeaderHeight
            total += currentBranch.author.isEmpty ? singleLineRowHeight : twoLineRowHeight
            itemCount += 2
        }
        if !otherBranches.isEmpty {
            total += sectionHeaderHeight
            itemCount += 1
            for branch in otherBranches {
                total += branch.author.isEmpty ? singleLineRowHeight : twoLineRowHeight
                itemCount += 1
            }
        }
        if itemCount > 1 {
            total += CGFloat(itemCount - 1) * interItemSpacing
        }
        return min(maxListHeight, max(minListHeight, ceil(total)))
    }

    public static func resolvedListHeight(
        measuredContentHeight: CGFloat,
        currentBranch: GitBranchSummary?,
        otherBranches: [GitBranchSummary]
    ) -> CGFloat {
        let candidate = measuredContentHeight > 1
            ? ceil(measuredContentHeight)
            : estimatedListHeight(currentBranch: currentBranch, otherBranches: otherBranches)
        return min(maxListHeight, max(minListHeight, candidate))
    }

    public static func moveSelection(current: String?, candidates: [String], delta: Int) -> String? {
        guard !candidates.isEmpty else { return nil }
        guard let current, let currentIndex = candidates.firstIndex(of: current) else {
            return delta >= 0 ? candidates.first : candidates.last
        }
        let nextIndex = max(0, min(candidates.count - 1, currentIndex + delta))
        return candidates[nextIndex]
    }
}
