import AppKit
import Foundation

extension WorkspaceState {
    func presentPackageDependenciesSheet() {
        if let tv = activeTextView as? GoLensTextView,
           let win = tv.window,
           win.firstResponder === tv {
            win.makeFirstResponder(nil)
        }
        showPackageDependenciesSheet = true
    }

    func inspectWorkspacePackageDependencies() -> PackageDependencyReportDTO {
        Self.computePackageDependencies(dirPath: packageInspectionDirectory())
    }

    func inspectWorkspacePackageDependencies(completion: @escaping (PackageDependencyReportDTO) -> Void) {
        let dirPath = packageInspectionDirectory()
        BackgroundFFI.shared.run("packageDependencies", work: {
            Self.computePackageDependencies(dirPath: dirPath)
        }, deliver: completion)
    }

    private func packageInspectionDirectory() -> String {
        if !activeWorkspacePath.isEmpty {
            return activeWorkspacePath
        } else if !activeFilePath.isEmpty {
            return (activeFilePath as NSString).deletingLastPathComponent
        }
        return ""
    }

    static func computePackageDependencies(dirPath: String) -> PackageDependencyReportDTO {
        guard !dirPath.isEmpty else { return .empty }
        let jsonStr = BackgroundFFI.callString(dirPath) { InspectGoPackageDeps($0) }
        return BackgroundFFI.decode(PackageDependencyReportDTO.self, from: jsonStr) ?? .empty
    }

    func jumpToPackageImport(filePath: String, line: Int) {
        showPackageDependenciesSheet = false
        guard !filePath.isEmpty else { return }
        let targetLine = max(1, line)
        recordNavigationJump(toPath: filePath, line: targetLine, col: 1)
        openFile(filePath)
        restoreCaretLocation(line: targetLine, column: 1, inPath: filePath)
    }

    func openFunctionComplexityInspector() {
        if let tv = activeTextView as? GoLensTextView,
           let win = tv.window,
           win.firstResponder === tv {
            win.makeFirstResponder(nil)
        }
        showFunctionComplexitySheet = true
    }

    func presentFunctionComplexitySheet() {
        openFunctionComplexityInspector()
    }

    func inspectFunctionComplexity(includeWorkspace: Bool) -> ComplexityReportDTO {
        Self.computeFunctionComplexity(activeInspectionInput(), includeWorkspace: includeWorkspace)
    }

    func inspectFunctionComplexity(includeWorkspace: Bool, completion: @escaping (ComplexityReportDTO) -> Void) {
        let input = activeInspectionInput()
        BackgroundFFI.shared.run("functionComplexity", work: {
            Self.computeFunctionComplexity(input, includeWorkspace: includeWorkspace)
        }, deliver: completion)
    }

    struct ActiveInspectionInput {
        let workspacePath: String
        let filePath: String
        let source: String
    }

    func activeInspectionInput() -> ActiveInspectionInput {
        let wsPath: String
        if !activeWorkspacePath.isEmpty {
            wsPath = activeWorkspacePath
        } else if !activeFilePath.isEmpty {
            wsPath = (activeFilePath as NSString).deletingLastPathComponent
        } else {
            wsPath = ""
        }
        let filePath = activeFilePath
        let src: String
        if !filePath.isEmpty, filePath.hasSuffix(".go") {
            if let tv = activeTextView as? GoLensTextView, tv.filePath == filePath {
                src = tv.string
            } else if let session = documents[filePath] {
                src = session.storage.string
            } else if let disk = try? String(contentsOfFile: filePath, encoding: .utf8) {
                src = disk
            } else {
                src = ""
            }
        } else {
            src = ""
        }
        return ActiveInspectionInput(workspacePath: wsPath, filePath: filePath, source: src)
    }

    static func computeFunctionComplexity(_ input: ActiveInspectionInput, includeWorkspace: Bool) -> ComplexityReportDTO {
        let jsonStr: String? = input.workspacePath.withCString { cDir in
            input.filePath.withCString { cFile in
                input.source.withCString { cContent in
                    guard let ptr = InspectGoFunctionComplexity(
                        cDir,
                        cFile,
                        cContent,
                        includeWorkspace ? 1 : 0
                    ) else {
                        return nil
                    }
                    defer { FreeGoCString(ptr) }
                    return String(cString: ptr)
                }
            }
        }
        return BackgroundFFI.decode(ComplexityReportDTO.self, from: jsonStr) ?? .empty
    }

    func jumpToFunctionComplexity(filePath: String, line: Int) {
        showFunctionComplexitySheet = false
        guard !filePath.isEmpty else { return }
        let targetLine = max(1, line)
        recordNavigationJump(toPath: filePath, line: targetLine, col: 1)
        openFile(filePath)
        restoreCaretLocation(line: targetLine, column: 1, inPath: filePath)
    }
}
