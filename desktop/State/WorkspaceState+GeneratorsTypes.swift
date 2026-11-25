import AppKit
import Foundation

extension WorkspaceState {
    func inspectEnumMethods(
        typeName: String = "",
        trimPrefix: Bool = true,
        includeParse: Bool = true,
        includeIsValid: Bool = true,
        includeValues: Bool = true
    ) -> EnumMethodsPlanDTO? {
        guard let decoded = inspectEnumMethodsJob(typeName: typeName, trimPrefix: trimPrefix, includeParse: includeParse, includeIsValid: includeIsValid, includeValues: includeValues)?() else { return nil }
        activeEnumMethodsPlan = decoded
        return decoded
    }

    func inspectEnumMethods(
        typeName: String = "",
        trimPrefix: Bool = true,
        includeParse: Bool = true,
        includeIsValid: Bool = true,
        includeValues: Bool = true,
        completion: @escaping (EnumMethodsPlanDTO?) -> Void
    ) {
        runPreviewJob(GeneratorPreviewKey.enumMethods, inspectEnumMethodsJob(typeName: typeName, trimPrefix: trimPrefix, includeParse: includeParse, includeIsValid: includeIsValid, includeValues: includeValues)) { [weak self] decoded in
            guard let self, let decoded else {
                completion(nil)
                return
            }
            activeEnumMethodsPlan = decoded
            completion(decoded)
        }
    }

    private func inspectEnumMethodsJob(
        typeName: String,
        trimPrefix: Bool,
        includeParse: Bool,
        includeIsValid: Bool,
        includeValues: Bool
    ) -> (() -> EnumMethodsPlanDTO?)? {
        let filePath = activeFilePath
        let dirPath: String
        if !filePath.isEmpty {
            dirPath = (filePath as NSString).deletingLastPathComponent
        } else {
            dirPath = activeWorkspacePath
        }
        guard !dirPath.isEmpty || !filePath.isEmpty else { return nil }

        let currentSource: String
        if let tv = activeTextView as? GoLensTextView, let session = tv.document {
            currentSource = session.storage.string
        } else if !filePath.isEmpty, let session = documents[filePath] {
            currentSource = session.storage.string
        } else if !filePath.isEmpty, let disk = try? String(contentsOfFile: filePath, encoding: .utf8) {
            currentSource = disk
        } else {
            currentSource = ""
        }

        var line = max(1, cursorLine)
        var col = max(1, cursorCol)
        if let tv = activeTextView as? GoLensTextView {
            let (l, c) = tv.lineAndCol(forCharacterIndex: tv.selectedRange().location)
            line = max(1, l)
            col = max(1, c)
        }

        return { [line, col] in
            let replyStr: String? = dirPath.withCString { cDir in
                filePath.withCString { cFile in
                    currentSource.withCString { cContent in
                        typeName.withCString { cType in
                            guard let ptr = InspectGoEnumMethods(
                                UnsafeMutablePointer(mutating: cDir),
                                UnsafeMutablePointer(mutating: cFile),
                                UnsafeMutablePointer(mutating: cContent),
                                Int32(line),
                                Int32(col),
                                UnsafeMutablePointer(mutating: cType),
                                trimPrefix ? 1 : 0,
                                includeParse ? 1 : 0,
                                includeIsValid ? 1 : 0,
                                includeValues ? 1 : 0
                            ) else {
                                return nil
                            }
                            defer { FreeGoCString(ptr) }
                            return String(cString: ptr)
                        }
                    }
                }
            }
            guard let replyStr,
                  let decoded = try? JSONDecoder().decode(EnumMethodsPlanDTO.self, from: Data(replyStr.utf8)) else {
                return nil
            }
            return decoded
        }
    }

    func openGenerateEnumMethodsSheet() {
        guard activeFilePath.hasSuffix(".go") else {
            presentCommandFeedback("Open a Go file containing a typed constant block to generate enum methods.", title: "Generate Enum Methods")
            return
        }
        if let tv = activeTextView as? GoLensTextView,
           let win = tv.window,
           win.firstResponder === tv {
            win.makeFirstResponder(nil)
        }
        activeEnumMethodsPlan = inspectEnumMethods(
            typeName: "",
            trimPrefix: true,
            includeParse: true,
            includeIsValid: true,
            includeValues: true
        )
        showGenerateEnumMethodsSheet = true
    }

    func presentGenerateEnumMethodsSheet() {
        openGenerateEnumMethodsSheet()
    }

    func inspectStructConstructor(
        structName: String = "",
        includeOptions: Bool = true,
        returnPointer: Bool = true
    ) -> ConstructorPlanDTO? {
        guard let decoded = inspectStructConstructorJob(structName: structName, includeOptions: includeOptions, returnPointer: returnPointer)?() else { return nil }
        activeConstructorPlan = decoded
        return decoded
    }

    func inspectStructConstructor(
        structName: String = "",
        includeOptions: Bool = true,
        returnPointer: Bool = true,
        completion: @escaping (ConstructorPlanDTO?) -> Void
    ) {
        runPreviewJob(GeneratorPreviewKey.constructor, inspectStructConstructorJob(structName: structName, includeOptions: includeOptions, returnPointer: returnPointer)) { [weak self] decoded in
            guard let self, let decoded else {
                completion(nil)
                return
            }
            activeConstructorPlan = decoded
            completion(decoded)
        }
    }

    private func inspectStructConstructorJob(
        structName: String,
        includeOptions: Bool,
        returnPointer: Bool
    ) -> (() -> ConstructorPlanDTO?)? {
        let filePath = activeFilePath
        let dirPath: String
        if !filePath.isEmpty {
            dirPath = (filePath as NSString).deletingLastPathComponent
        } else {
            dirPath = activeWorkspacePath
        }
        guard !dirPath.isEmpty || !filePath.isEmpty else { return nil }

        let currentSource: String
        if let tv = activeTextView as? GoLensTextView, let session = tv.document {
            currentSource = session.storage.string
        } else if !filePath.isEmpty, let session = documents[filePath] {
            currentSource = session.storage.string
        } else if !filePath.isEmpty, let disk = try? String(contentsOfFile: filePath, encoding: .utf8) {
            currentSource = disk
        } else {
            currentSource = ""
        }

        var line = max(1, cursorLine)
        var col = max(1, cursorCol)
        if let tv = activeTextView as? GoLensTextView {
            let (l, c) = tv.lineAndCol(forCharacterIndex: tv.selectedRange().location)
            line = max(1, l)
            col = max(1, c)
        }

        return { [line, col] in
            let replyStr: String? = dirPath.withCString { cDir in
                filePath.withCString { cFile in
                    currentSource.withCString { cContent in
                        structName.withCString { cStruct in
                            guard let ptr = InspectGoStructConstructor(
                                UnsafeMutablePointer(mutating: cDir),
                                UnsafeMutablePointer(mutating: cFile),
                                UnsafeMutablePointer(mutating: cContent),
                                Int32(line),
                                Int32(col),
                                UnsafeMutablePointer(mutating: cStruct),
                                includeOptions ? 1 : 0,
                                returnPointer ? 1 : 0
                            ) else {
                                return nil
                            }
                            defer { FreeGoCString(ptr) }
                            return String(cString: ptr)
                        }
                    }
                }
            }
            guard let replyStr,
                  let decoded = try? JSONDecoder().decode(ConstructorPlanDTO.self, from: Data(replyStr.utf8)) else {
                return nil
            }
            return decoded
        }
    }

    func openGenerateConstructorSheet() {
        guard activeFilePath.hasSuffix(".go") else {
            presentCommandFeedback("Open a Go file containing a struct declaration to generate a constructor.", title: "Generate Constructor")
            return
        }
        if let tv = activeTextView as? GoLensTextView,
           let win = tv.window,
           win.firstResponder === tv {
            win.makeFirstResponder(nil)
        }
        activeConstructorPlan = inspectStructConstructor(structName: "", includeOptions: true, returnPointer: true)
        showGenerateConstructorSheet = true
    }

    func presentGenerateConstructorSheet() {
        openGenerateConstructorSheet()
    }
}
