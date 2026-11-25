import AppKit
import Foundation

extension WorkspaceState {
    private func invokeGenerateTableDrivenTest(testFuncName: String, includeParallel: Bool, apply: Bool) -> GenerateTestPreviewDTO? {
        guard let tv = activeTextView as? GoLensTextView,
              let session = tv.document,
              session.path.hasSuffix(".go") else {
            return nil
        }
        struct Req: Encodable {
            let path: String
            let src: String
            let offset: Int
            let testFuncName: String
            let includeParallel: Bool
            let apply: Bool
        }
        let path = session.path
        let src = session.storage.string
        let offset = session.utf8.byteOffset(tv.selectedRange().location)
        guard let reqData = try? JSONEncoder().encode(Req(
            path: path,
            src: src,
            offset: offset,
            testFuncName: testFuncName,
            includeParallel: includeParallel,
            apply: apply
        )), let reqStr = String(data: reqData, encoding: .utf8) else {
            return nil
        }
        let replyStr: String? = reqStr.withCString { cReq in
            guard let ptr = GenerateGoTableDrivenTest(cReq) else { return nil }
            defer { FreeGoCString(ptr) }
            return String(cString: ptr)
        }
        guard let replyStr else { return nil }
        return try? JSONDecoder().decode(GenerateTestPreviewDTO.self, from: Data(replyStr.utf8))
    }

    func presentGenerateTableDrivenTestSheet() {
        let preview = invokeGenerateTableDrivenTest(testFuncName: "", includeParallel: false, apply: false)
        guard let preview,
              (preview.error ?? "").isEmpty,
              !(preview.previewCode ?? "").isEmpty else {
            presentCommandFeedback(
                Self.formatCommandReason(preview?.error, fallback: "Open a Go file and place the cursor inside a function or method to generate a table-driven test."),
                title: "Generate Table-Driven Test"
            )
            return
        }
        if let tv = activeTextView as? GoLensTextView,
           let win = tv.window,
           win.firstResponder === tv {
            win.makeFirstResponder(nil)
        }
        activeGenerateTestPreview = preview
        showGenerateTestSheet = true
    }

    func refreshTableDrivenTestPreview(testFuncName: String, includeParallel: Bool) -> GenerateTestPreviewDTO? {
        invokeGenerateTableDrivenTest(testFuncName: testFuncName, includeParallel: includeParallel, apply: false)
    }

    func applyGenerateTableDrivenTest(testFuncName: String, includeParallel: Bool) {
        showGenerateTestSheet = false
        let reply = invokeGenerateTableDrivenTest(testFuncName: testFuncName, includeParallel: includeParallel, apply: true)
        guard let reply,
              (reply.error ?? "").isEmpty,
              let testFilePath = reply.testFilePath,
              !testFilePath.isEmpty else {
            presentCommandFeedback(
                Self.formatCommandReason(reply?.error, fallback: "Could not write the generated table-driven test."),
                title: "Generate Table-Driven Test",
                tone: .failure
            )
            return
        }
        if !activeWorkspacePath.isEmpty {
            loadFiles(from: activeWorkspacePath)
            loadWorkspaceTests()
        }
        documents.removeValue(forKey: testFilePath)
        loadedDocuments.remove(testFilePath)
        editedFiles.remove(testFilePath)
        if isCounterpartSplitEnabled && testFilePath == secondaryFilePath {
            loadDocument(testFilePath)
        } else {
            openFile(testFilePath)
            loadDocument(testFilePath)
        }
        appendLog("Generated table-driven test \(reply.testFuncName ?? testFuncName) in \((testFilePath as NSString).lastPathComponent)")
    }

    func invokeGenerateInterfaceMock(interfaceName: String = "", mockName: String = "") -> InterfaceMockResultDTO? {
        interfaceMockJob(interfaceName: interfaceName, mockName: mockName)?()
    }

    private func interfaceMockJob(interfaceName: String, mockName: String) -> (() -> InterfaceMockResultDTO?)? {
        let filePath = activeFilePath
        let dirPath: String
        if !filePath.isEmpty {
            dirPath = (filePath as NSString).deletingLastPathComponent
        } else {
            dirPath = activeWorkspacePath
        }
        guard !dirPath.isEmpty else { return nil }

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
                    interfaceName.withCString { cIface in
                        mockName.withCString { cMock in
                            guard let ptr = GenerateGoInterfaceMock(
                                cDir,
                                cFile,
                                Int32(line),
                                Int32(col),
                                cIface,
                                cMock
                            ) else {
                                return nil
                            }
                            defer { FreeGoCString(ptr) }
                            return String(cString: ptr)
                        }
                    }
                }
            }
            guard let replyStr else { return nil }
            return try? JSONDecoder().decode(InterfaceMockResultDTO.self, from: Data(replyStr.utf8))
        }
    }

    func presentGenerateInterfaceMockSheet() {
        guard activeFilePath.hasSuffix(".go") else {
            presentCommandFeedback("Open a Go file containing an interface declaration to generate a mock.", title: "Generate Interface Mock")
            return
        }
        if let tv = activeTextView as? GoLensTextView,
           let win = tv.window,
           win.firstResponder === tv {
            win.makeFirstResponder(nil)
        }
        activeInterfaceMockPreview = invokeGenerateInterfaceMock(interfaceName: "", mockName: "")
        showGenerateInterfaceMockSheet = true
    }

    func refreshInterfaceMockPreview(interfaceName: String, mockName: String) -> InterfaceMockResultDTO? {
        let updated = invokeGenerateInterfaceMock(interfaceName: interfaceName, mockName: mockName)
        if let updated {
            activeInterfaceMockPreview = updated
        }
        return updated
    }

    func refreshInterfaceMockPreview(
        interfaceName: String,
        mockName: String,
        completion: @escaping (InterfaceMockResultDTO?) -> Void
    ) {
        runPreviewJob(GeneratorPreviewKey.interfaceMock, interfaceMockJob(interfaceName: interfaceName, mockName: mockName)) { [weak self] updated in
            if let updated {
                self?.activeInterfaceMockPreview = updated
            }
            completion(updated)
        }
    }

    func applyGenerateInterfaceMock(interfaceName: String, mockName: String, createNewTestFile: Bool) {
        showGenerateInterfaceMockSheet = false
        let result = invokeGenerateInterfaceMock(interfaceName: interfaceName, mockName: mockName)
        guard let result,
              (result.error ?? "").isEmpty else {
            presentCommandFeedback(
                Self.formatCommandReason(result?.error, fallback: "Could not generate an interface mock for \(interfaceName)."),
                title: "Generate Interface Mock",
                tone: .failure
            )
            return
        }

        if createNewTestFile {
            let standalone = result.standaloneFileCode ?? ""
            let suggested = result.suggestedFileName ?? "mock_\(interfaceName.lowercased())_test.go"
            let dirPath: String
            if !activeFilePath.isEmpty {
                dirPath = (activeFilePath as NSString).deletingLastPathComponent
            } else {
                dirPath = activeWorkspacePath
            }
            guard !dirPath.isEmpty, !standalone.isEmpty else {
                presentCommandFeedback("Could not determine the package directory for the new mock file.", title: "Generate Interface Mock", tone: .failure)
                return
            }
            let targetPath = (dirPath as NSString).appendingPathComponent(suggested)
            do {
                try standalone.write(toFile: targetPath, atomically: true, encoding: .utf8)
            } catch {
                presentCommandFeedback("Could not write \(suggested): \(error.localizedDescription)", title: "Generate Interface Mock", tone: .failure)
                return
            }
            LSPClient.notifyWatchedFilesChanged([targetPath], changeType: 1)
            if !activeWorkspacePath.isEmpty {
                loadFiles(from: activeWorkspacePath)
                loadWorkspaceTests()
            }
            documents.removeValue(forKey: targetPath)
            loadedDocuments.remove(targetPath)
            editedFiles.remove(targetPath)
            openFile(targetPath)
            loadDocument(targetPath)
            appendLog("Generated interface mock \(result.mockName ?? mockName) in \(suggested)")
            return
        }

        let snippet = (result.generatedCode ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !snippet.isEmpty else {
            presentCommandFeedback("No mock code was generated for the selected interface.", title: "Generate Interface Mock", tone: .warning)
            return
        }
        let targetSession: DocumentSession?
        if let tv = activeTextView as? GoLensTextView, let doc = tv.document {
            targetSession = doc
        } else if !activeFilePath.isEmpty {
            targetSession = documents[activeFilePath]
        } else {
            targetSession = nil
        }
        guard let session = targetSession else {
            presentCommandFeedback("Open a Go file in the editor to insert the generated mock.", title: "Generate Interface Mock")
            return
        }

        let currentText = session.storage.string
        let updatedText = Self.insertMockSnippetIntoGoSource(currentText, snippet: snippet)
        let fullRange = NSRange(location: 0, length: session.storage.length)
        applyRanges([(fullRange, updatedText)], in: session)
        editedFiles.insert(session.path)
        documentDidEdit(session)
        if let tv = activeTextView as? GoLensTextView, tv.document === session {
            let endLoc = session.storage.length
            tv.setSelectedRange(NSRange(location: endLoc, length: 0))
            tv.scrollRangeToVisible(NSRange(location: endLoc, length: 0))
            (tv.delegate as? MacTextView.Coordinator)?.scheduleHighlight(for: tv, immediate: true)
            activeGoDeclarations = tv.filePath.hasSuffix(".go") ? findGoDeclarations(in: tv.string) : []
            tv.needsDisplay = true
        }
        appendLog("Generated interface mock \(result.mockName ?? mockName) in \((session.path as NSString).lastPathComponent)")
    }

    private static func insertMockSnippetIntoGoSource(_ source: String, snippet: String) -> String {
        var working = insertGoImportIfNeeded(source, importPath: "sync")
        while working.hasSuffix("\n") {
            working.removeLast()
        }
        return working + "\n\n" + snippet + "\n"
    }

    func inspectFuzzTest(
        funcName: String = "",
        includeEdgeSeeds: Bool = true,
        checkDeterminism: Bool = true
    ) -> FuzzTestPlanDTO? {
        guard let decoded = inspectFuzzTestJob(funcName: funcName, includeEdgeSeeds: includeEdgeSeeds, checkDeterminism: checkDeterminism)?() else { return nil }
        activeFuzzTestPlan = decoded
        return decoded
    }

    func inspectFuzzTest(
        funcName: String = "",
        includeEdgeSeeds: Bool = true,
        checkDeterminism: Bool = true,
        completion: @escaping (FuzzTestPlanDTO?) -> Void
    ) {
        runPreviewJob(GeneratorPreviewKey.fuzzTest, inspectFuzzTestJob(funcName: funcName, includeEdgeSeeds: includeEdgeSeeds, checkDeterminism: checkDeterminism)) { [weak self] decoded in
            guard let self, let decoded else {
                completion(nil)
                return
            }
            activeFuzzTestPlan = decoded
            completion(decoded)
        }
    }

    private func inspectFuzzTestJob(
        funcName: String,
        includeEdgeSeeds: Bool,
        checkDeterminism: Bool
    ) -> (() -> FuzzTestPlanDTO?)? {
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
                        funcName.withCString { cFunc in
                            guard let ptr = InspectGoFuzzTest(
                                UnsafeMutablePointer(mutating: cDir),
                                UnsafeMutablePointer(mutating: cFile),
                                UnsafeMutablePointer(mutating: cContent),
                                Int32(line),
                                Int32(col),
                                UnsafeMutablePointer(mutating: cFunc),
                                includeEdgeSeeds ? 1 : 0,
                                checkDeterminism ? 1 : 0
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
                  let decoded = try? JSONDecoder().decode(FuzzTestPlanDTO.self, from: Data(replyStr.utf8)) else {
                return nil
            }
            return decoded
        }
    }

    func openGenerateFuzzTestSheet() {
        guard activeFilePath.hasSuffix(".go") else {
            presentCommandFeedback("Open a Go file containing a function with fuzz-compatible parameters.", title: "Generate Fuzz Test")
            return
        }
        if let tv = activeTextView as? GoLensTextView,
           let win = tv.window,
           win.firstResponder === tv {
            win.makeFirstResponder(nil)
        }
        activeFuzzTestPlan = inspectFuzzTest(funcName: "", includeEdgeSeeds: true, checkDeterminism: true)
        showGenerateFuzzTestSheet = true
    }

    func presentGenerateFuzzTestSheet() {
        openGenerateFuzzTestSheet()
    }

    func applyGeneratedFuzzTest(_ plan: FuzzTestPlanDTO) {
        let targetPath: String
        if !plan.targetFile.isEmpty {
            targetPath = plan.targetFile
        } else if !activeFilePath.isEmpty {
            if activeFilePath.hasSuffix("_test.go") {
                targetPath = activeFilePath
            } else if activeFilePath.hasSuffix(".go") {
                targetPath = String(activeFilePath.dropLast(3)) + "_test.go"
            } else {
                targetPath = activeFilePath
            }
        } else {
            presentCommandFeedback("Open a Go file in the editor before generating a fuzz test.", title: "Generate Fuzz Test")
            return
        }

        guard !plan.newContent.isEmpty else {
            presentCommandFeedback(Self.formatCommandReason(plan.error, fallback: "No fuzz test code was generated."), title: "Generate Fuzz Test", tone: .warning)
            return
        }

        let fileExists = FileManager.default.fileExists(atPath: targetPath)
        if !fileExists {
            do {
                try plan.newContent.write(toFile: targetPath, atomically: true, encoding: .utf8)
            } catch {
                presentCommandFeedback("Couldn’t create “\((targetPath as NSString).lastPathComponent)”. \(Self.failureReason(error))", title: "Generate Fuzz Test", tone: .failure)
                return
            }
            LSPClient.notifyWatchedFilesChanged([targetPath], changeType: 1)
            if !activeWorkspacePath.isEmpty {
                loadFiles(from: activeWorkspacePath)
                loadWorkspaceTests()
            }
        }
        openFile(targetPath)
        if fileExists {
            applyInPlaceEdit(
                newText: plan.newContent,
                actionName: "Generate Fuzz Test",
                targetPath: targetPath
            )
        } else {
            loadDocument(targetPath)
        }
    }

    func openGenerateBenchmarkSheet() {
        guard activeFilePath.hasSuffix(".go") else {
            presentCommandFeedback("Open a Go file containing a function or method to generate a benchmark.", title: "Generate Benchmark")
            return
        }
        if let tv = activeTextView as? GoLensTextView,
           let win = tv.window,
           win.firstResponder === tv {
            win.makeFirstResponder(nil)
        }
        activeBenchmarkGenPlan = inspectBenchmarkGen(
            funcName: "",
            reportAllocs: true,
            runParallel: false,
            tableSubBench: false
        )
        showGenerateBenchmarkSheet = true
    }

    func presentGenerateBenchmarkSheet() {
        openGenerateBenchmarkSheet()
    }

    @discardableResult
    func inspectBenchmarkGen(
        funcName: String,
        reportAllocs: Bool,
        runParallel: Bool,
        tableSubBench: Bool
    ) -> BenchmarkGenPlanDTO? {
        guard let plan = inspectBenchmarkGenJob(funcName: funcName, reportAllocs: reportAllocs, runParallel: runParallel, tableSubBench: tableSubBench)?() else { return nil }
        activeBenchmarkGenPlan = plan
        return plan
    }

    func inspectBenchmarkGen(
        funcName: String,
        reportAllocs: Bool,
        runParallel: Bool,
        tableSubBench: Bool,
        completion: @escaping (BenchmarkGenPlanDTO?) -> Void
    ) {
        runPreviewJob(GeneratorPreviewKey.benchmarkGen, inspectBenchmarkGenJob(funcName: funcName, reportAllocs: reportAllocs, runParallel: runParallel, tableSubBench: tableSubBench)) { [weak self] plan in
            guard let self, let plan else {
                completion(nil)
                return
            }
            activeBenchmarkGenPlan = plan
            completion(plan)
        }
    }

    private func inspectBenchmarkGenJob(
        funcName: String,
        reportAllocs: Bool,
        runParallel: Bool,
        tableSubBench: Bool
    ) -> (() -> BenchmarkGenPlanDTO?)? {
        let filePath = activeFilePath
        guard filePath.hasSuffix(".go") else { return nil }
        let dirPath = !filePath.isEmpty
            ? (filePath as NSString).deletingLastPathComponent
            : activeWorkspacePath
        guard !dirPath.isEmpty else { return nil }

        let currentSource: String
        var line = max(1, cursorLine)
        var col = max(1, cursorCol)
        if let tv = activeTextView as? GoLensTextView, tv.filePath == filePath {
            currentSource = tv.string
            let (l, c) = tv.lineAndCol(forCharacterIndex: tv.selectedRange().location)
            line = max(1, l)
            col = max(1, c)
        } else if let session = documents[filePath] {
            currentSource = session.storage.string
        } else if let disk = try? String(contentsOfFile: filePath, encoding: .utf8) {
            currentSource = disk
        } else {
            currentSource = ""
        }

        return { [line, col] in
            let jsonStr: String? = dirPath.withCString { cDir in
                filePath.withCString { cFile in
                    currentSource.withCString { cContent in
                        funcName.withCString { cFunc in
                            guard let ptr = InspectGoBenchmarkGen(
                                cDir,
                                cFile,
                                cContent,
                                Int32(line),
                                Int32(col),
                                cFunc,
                                reportAllocs ? 1 : 0,
                                runParallel ? 1 : 0,
                                tableSubBench ? 1 : 0
                            ) else {
                                return nil
                            }
                            defer { FreeGoCString(ptr) }
                            return String(cString: ptr)
                        }
                    }
                }
            }
            guard let jsonStr,
                  let plan = try? JSONDecoder().decode(BenchmarkGenPlanDTO.self, from: Data(jsonStr.utf8)) else {
                return nil
            }
            return plan
        }
    }

    func applyGeneratedBenchmark(_ plan: BenchmarkGenPlanDTO) {
        let targetPath: String
        if !plan.targetFile.isEmpty {
            targetPath = plan.targetFile
        } else if !activeFilePath.isEmpty {
            if activeFilePath.hasSuffix("_test.go") {
                targetPath = activeFilePath
            } else if activeFilePath.hasSuffix(".go") {
                targetPath = String(activeFilePath.dropLast(3)) + "_test.go"
            } else {
                targetPath = activeFilePath
            }
        } else {
            presentCommandFeedback("Open a Go file in the editor before generating a benchmark.", title: "Generate Benchmark")
            return
        }

        guard !plan.newContent.isEmpty else {
            presentCommandFeedback(Self.formatCommandReason(plan.error, fallback: "No benchmark code was generated."), title: "Generate Benchmark", tone: .warning)
            return
        }

        let fileExists = FileManager.default.fileExists(atPath: targetPath)
        if !fileExists {
            do {
                try plan.newContent.write(toFile: targetPath, atomically: true, encoding: .utf8)
            } catch {
                presentCommandFeedback("Could not write \((targetPath as NSString).lastPathComponent): \(error.localizedDescription)", title: "Generate Benchmark", tone: .failure)
                return
            }
            LSPClient.notifyWatchedFilesChanged([targetPath], changeType: 1)
            if !activeWorkspacePath.isEmpty {
                loadFiles(from: activeWorkspacePath)
                loadWorkspaceTests()
            }
        }
        openFile(targetPath)
        if fileExists {
            applyInPlaceEdit(
                newText: plan.newContent,
                actionName: "Generate Go Benchmark",
                targetPath: targetPath
            )
        } else {
            loadDocument(targetPath)
        }
    }
}
