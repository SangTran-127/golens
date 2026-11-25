import AppKit
import GoLensFoundation
import SwiftUI

enum LensTrackMode: String, Equatable, CaseIterable {
    case edit
    case debug
    case profile
    case conflict
}

struct OpticalLensLineItem {
    let lineNumber: Int
    let mode: LensTrackMode
    let conflictActions: [MergeConflictLensAction]
    let debugValue: String?
    let profileHeat: Double?
    let escapeNote: String?
    let issues: [DiagnosticData]
    let usages: Int?
    let usageInteractive: Bool
    let implementations: [LSPLocation]
    let implementsDirection: ImplementationDirection
    let author: String?
    let goplsLenses: [CodeLensItem]
    let moduleNote: String?
    let renameOffer: RenameSuggestion?
    let renameShortcutDisplay: String
    let activeLineBlame: String?

    var usagesLabel: String? {
        guard let usages else { return nil }
        return usages == 1 ? "1 usage" : "\(usages) usages"
    }

    var implementationsLabel: String? {
        guard implementsDirection != .none else { return nil }
        let count = implementations.count
        if implementsDirection == .implements {
            return count == 1 ? "implements 1 interface" : "implements \(count) interfaces"
        }
        return count == 1 ? "1 implementation" : "\(count) implementations"
    }

    var compactImplementationsLabel: String? {
        guard implementsDirection != .none else { return nil }
        let count = implementations.count
        if implementsDirection == .implements {
            return count == 1 ? "impls 1" : "impls \(count)"
        }
        return count == 1 ? "1 impl" : "\(count) impls"
    }

    var totalInteractiveOrInfoCount: Int {
        switch mode {
        case .conflict:
            return conflictActions.count
        case .debug:
            return (debugValue != nil ? 1 : 0) + issues.count
        case .profile:
            return (profileHeat != nil ? 1 : 0) + (escapeNote != nil ? 1 : 0) + issues.count
        case .edit:
            var count = issues.count
            if usages != nil { count += 1 }
            if implementsDirection != .none { count += 1 }
            count += goplsLenses.count
            if moduleNote != nil { count += 1 }
            if renameOffer != nil { count += 1 }
            if activeLineBlame != nil { count += 1 }
            if author != nil && activeLineBlame == nil { count += 1 }
            return max(1, count)
        }
    }

    var compactPillSpec: (text: String, tone: StatusTone?) {
        if !issues.isEmpty {
            let isError = issues.contains(where: { $0.severity == 1 })
            return ("!\(issues.count)", isError ? .failure : .warning)
        }
        switch mode {
        case .conflict:
            return ("!\(conflictActions.count)", .warning)
        case .debug:
            return ("•1", .info)
        case .profile:
            if let heat = profileHeat {
                let pct = min(99, max(1, Int((heat * 100).rounded())))
                return ("\(pct)%", .warning)
            }
            return ("!1", .warning)
        case .edit:
            return ("•\(totalInteractiveOrInfoCount)", nil)
        }
    }

    var accessibilitySummary: String {
        switch mode {
        case .conflict:
            return "Merge conflict actions (\(conflictActions.map(\.title).joined(separator: ", ")))"
        case .debug:
            if let debugValue { return debugValue }
            return issues.first?.message ?? "Debug value"
        case .profile:
            var parts: [String] = []
            if let heat = profileHeat {
                parts.append(String(format: "%.0f%% CPU", heat * 100))
            }
            if let escapeNote {
                parts.append(escapeNote)
            }
            return parts.joined(separator: ", ")
        case .edit:
            var parts: [String] = []
            if let first = issues.first {
                let firstLine = first.message.split(whereSeparator: \.isNewline).first.map(String.init) ?? first.message
                parts.append(firstLine)
            }
            if let usagesLabel { parts.append(usagesLabel) }
            if let implementationsLabel { parts.append(implementationsLabel) }
            for lens in goplsLenses { parts.append(lens.title) }
            if let moduleNote { parts.append(moduleNote) }
            if let renameOffer { parts.append(renameOffer.title) }
            if let activeLineBlame { parts.append(activeLineBlame) }
            return parts.joined(separator: ", ")
        }
    }
}

enum OpticalLensCoordinator {
    static func resolveFileTrackMode(
        hasMergeConflicts: Bool,
        isDebugInlineActive: Bool,
        hasProfileOrEscape: Bool
    ) -> LensTrackMode {
        if hasMergeConflicts { return .conflict }
        if isDebugInlineActive { return .debug }
        if hasProfileOrEscape { return .profile }
        return .edit
    }

    static func lineItem(
        lineNumber: Int,
        filePath: String,
        isGoFile: Bool,
        isGoModFile: Bool,
        lensStyle: EffectiveOpticalLensStyle,
        showGitBlame: Bool,
        conflictRole: MergeConflictLineRole?,
        isDebugInlineActive: Bool,
        debugValue: String?,
        hasProfileModeInFile: Bool,
        profileHeat: Double?,
        escapeNote: String?,
        lineIssues: [DiagnosticData]?,
        lensInfo: CodeLensInfo?,
        packageHasErrors: Bool,
        goplsLenses: [CodeLensItem]?,
        moduleNote: String?,
        renameOffer: RenameSuggestion?,
        renameShortcutDisplay: String,
        activeLineBlame: String?
    ) -> OpticalLensLineItem? {
        if let conflictRole {
            guard conflictRole == .currentMarker else { return nil }
            return OpticalLensLineItem(
                lineNumber: lineNumber,
                mode: .conflict,
                conflictActions: MergeConflictLensAction.all,
                debugValue: nil,
                profileHeat: nil,
                escapeNote: nil,
                issues: lineIssues ?? [],
                usages: nil,
                usageInteractive: false,
                implementations: [],
                implementsDirection: .none,
                author: nil,
                goplsLenses: [],
                moduleNote: nil,
                renameOffer: nil,
                renameShortcutDisplay: "",
                activeLineBlame: nil
            )
        }

        if isDebugInlineActive {
            if let debugValue, !debugValue.isEmpty {
                return OpticalLensLineItem(
                    lineNumber: lineNumber,
                    mode: .debug,
                    conflictActions: [],
                    debugValue: debugValue,
                    profileHeat: nil,
                    escapeNote: nil,
                    issues: lineIssues ?? [],
                    usages: nil,
                    usageInteractive: false,
                    implementations: [],
                    implementsDirection: .none,
                    author: nil,
                    goplsLenses: [],
                    moduleNote: nil,
                    renameOffer: nil,
                    renameShortcutDisplay: "",
                    activeLineBlame: nil
                )
            }
            if let lineIssues, !lineIssues.isEmpty {
                return OpticalLensLineItem(
                    lineNumber: lineNumber,
                    mode: .edit,
                    conflictActions: [],
                    debugValue: nil,
                    profileHeat: nil,
                    escapeNote: nil,
                    issues: lineIssues,
                    usages: nil,
                    usageInteractive: false,
                    implementations: [],
                    implementsDirection: .none,
                    author: nil,
                    goplsLenses: [],
                    moduleNote: nil,
                    renameOffer: nil,
                    renameShortcutDisplay: "",
                    activeLineBlame: nil
                )
            }
            return nil
        }

        if hasProfileModeInFile, (profileHeat != nil || escapeNote != nil) {
            return OpticalLensLineItem(
                lineNumber: lineNumber,
                mode: .profile,
                conflictActions: [],
                debugValue: nil,
                profileHeat: profileHeat,
                escapeNote: escapeNote,
                issues: lineIssues ?? [],
                usages: nil,
                usageInteractive: false,
                implementations: [],
                implementsDirection: .none,
                author: nil,
                goplsLenses: [],
                moduleNote: nil,
                renameOffer: nil,
                renameShortcutDisplay: "",
                activeLineBlame: nil
            )
        }

        let resolvedIssues = lineIssues ?? []
        if lensStyle == .minimalOnly {
            guard !resolvedIssues.isEmpty || renameOffer != nil else { return nil }
            return OpticalLensLineItem(
                lineNumber: lineNumber,
                mode: .edit,
                conflictActions: [],
                debugValue: nil,
                profileHeat: nil,
                escapeNote: nil,
                issues: resolvedIssues,
                usages: nil,
                usageInteractive: false,
                implementations: [],
                implementsDirection: .none,
                author: nil,
                goplsLenses: [],
                moduleNote: nil,
                renameOffer: renameOffer,
                renameShortcutDisplay: renameShortcutDisplay,
                activeLineBlame: nil
            )
        }

        let isColumn: Bool = {
            if case .column = lensStyle { return true }
            return false
        }()

        var resolvedUsages: Int? = nil
        var usageInteractive = false
        var implementations: [LSPLocation] = []
        var implementsDirection: ImplementationDirection = .none
        var author: String? = nil

        if isGoFile, let lensInfo {
            if let usages = lensInfo.usages, usages > 0 || !packageHasErrors {
                resolvedUsages = usages
                usageInteractive = usages > 0
            }
            if lensInfo.implementsDirection != .none {
                implementations = lensInfo.implementations
                implementsDirection = lensInfo.implementsDirection
            }
            if isColumn && showGitBlame && (resolvedUsages != nil || implementsDirection != .none) {
                author = lensInfo.author
            }
        }

        let resolvedGopls = goplsLenses.map { Array($0.prefix(8)) } ?? []
        let resolvedModuleNote = isGoModFile ? moduleNote : nil
        let resolvedBlame = (isColumn && showGitBlame && author == nil) ? activeLineBlame : nil

        let hasAny = !resolvedIssues.isEmpty ||
            resolvedUsages != nil ||
            implementsDirection != .none ||
            author != nil ||
            !resolvedGopls.isEmpty ||
            resolvedModuleNote != nil ||
            renameOffer != nil ||
            resolvedBlame != nil

        guard hasAny else { return nil }

        return OpticalLensLineItem(
            lineNumber: lineNumber,
            mode: .edit,
            conflictActions: [],
            debugValue: nil,
            profileHeat: nil,
            escapeNote: nil,
            issues: resolvedIssues,
            usages: resolvedUsages,
            usageInteractive: usageInteractive,
            implementations: implementations,
            implementsDirection: implementsDirection,
            author: author,
            goplsLenses: resolvedGopls,
            moduleNote: resolvedModuleNote,
            renameOffer: renameOffer,
            renameShortcutDisplay: renameShortcutDisplay,
            activeLineBlame: resolvedBlame
        )
    }
}
