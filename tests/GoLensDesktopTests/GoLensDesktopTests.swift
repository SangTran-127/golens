import AppKit
import XCTest
import GoLensFoundation

final class GoLensDesktopTests: XCTestCase {
    func testDefaultCapabilitiesAreAllDisabledExceptCodeMode() {
        let caps = ActiveCommandCapabilities()
        XCTAssertFalse(caps.hasWorkspace)
        XCTAssertFalse(caps.hasActiveFile)
        XCTAssertFalse(caps.isGoFile)
        XCTAssertFalse(caps.isGoTestFile)
        XCTAssertFalse(caps.isNonTestGoFile)
        XCTAssertFalse(caps.isGoModFile)
        XCTAssertFalse(caps.isJSONFile)
        XCTAssertFalse(caps.isYAMLFile)
        XCTAssertFalse(caps.isSQLFile)
        XCTAssertFalse(caps.isDockerfile)
        XCTAssertFalse(caps.isDockerComposeFile)
        XCTAssertFalse(caps.isMarkdownFile)
        XCTAssertFalse(caps.isHTTPFile)
        XCTAssertFalse(caps.isEnvFile)
        XCTAssertFalse(caps.isProtoFile)
        XCTAssertFalse(caps.isMakefile)
        XCTAssertFalse(caps.canFormatDocument)
        XCTAssertFalse(caps.canSave)
        XCTAssertTrue(caps.isCodeMode)
        XCTAssertFalse(caps.isDiffMode)
    }

    func testDatabaseCapabilitiesNeedASQLFileAndADataSource() {
        let attached = ActiveCommandCapabilities(workspacePath: "/p", filePath: "/p/q.sql", hasDataSources: true, isAttachedConsole: true)
        XCTAssertTrue(attached.hasDataSources)
        XCTAssertTrue(attached.isAttachedConsole)
        let goFile = ActiveCommandCapabilities(workspacePath: "/p", filePath: "/p/main.go", hasDataSources: true, isAttachedConsole: true)
        XCTAssertFalse(goFile.isAttachedConsole)
        let noSources = ActiveCommandCapabilities(workspacePath: "/p", filePath: "/p/q.sql", hasDataSources: false, isAttachedConsole: true)
        XCTAssertFalse(noSources.hasDataSources)
        XCTAssertFalse(noSources.isAttachedConsole)
        XCTAssertFalse(ActiveCommandCapabilities(hasDataSources: true).hasDataSources)
    }

    func testGoToGoTabSwitchProducesIdenticalCapabilities() {
        let first = ActiveCommandCapabilities(
            workspacePath: "/Users/dev/project",
            filePath: "/Users/dev/project/internal/server/handler.go",
            canSave: true
        )
        let second = ActiveCommandCapabilities(
            workspacePath: "/Users/dev/project",
            filePath: "/Users/dev/project/pkg/auth/token.go",
            canSave: true
        )
        XCTAssertEqual(first, second)
        XCTAssertTrue(first.hasWorkspace)
        XCTAssertTrue(first.hasActiveFile)
        XCTAssertTrue(first.isGoFile)
        XCTAssertFalse(first.isGoTestFile)
        XCTAssertTrue(first.isNonTestGoFile)
        XCTAssertTrue(first.canFormatDocument)
    }

    func testGoTestToGoTestTabSwitchProducesIdenticalCapabilities() {
        let first = ActiveCommandCapabilities(
            workspacePath: "/Users/dev/project",
            filePath: "/Users/dev/project/handler_test.go",
            canSave: true
        )
        let second = ActiveCommandCapabilities(
            workspacePath: "/Users/dev/project",
            filePath: "/Users/dev/project/service_test.go",
            canSave: true
        )
        XCTAssertEqual(first, second)
        XCTAssertTrue(first.isGoFile)
        XCTAssertTrue(first.isGoTestFile)
        XCTAssertFalse(first.isNonTestGoFile)
    }

    func testGoSourceVsGoTestDistinguishesNonTestGoFile() {
        let impl = ActiveCommandCapabilities(workspacePath: "/ws", filePath: "/ws/main.go")
        let test = ActiveCommandCapabilities(workspacePath: "/ws", filePath: "/ws/main_test.go")
        XCTAssertNotEqual(impl, test)
        XCTAssertTrue(impl.isNonTestGoFile)
        XCTAssertFalse(impl.isGoTestFile)
        XCTAssertFalse(test.isNonTestGoFile)
        XCTAssertTrue(test.isGoTestFile)
    }

    func testEmptyFilePathWithOpenWorkspace() {
        let caps = ActiveCommandCapabilities(workspacePath: "/ws", filePath: "")
        XCTAssertTrue(caps.hasWorkspace)
        XCTAssertFalse(caps.hasActiveFile)
        XCTAssertFalse(caps.isGoFile)
        XCTAssertFalse(caps.canFormatDocument)
    }

    func testGoModCapabilities() {
        let caps = ActiveCommandCapabilities(workspacePath: "/ws", filePath: "/ws/go.mod")
        XCTAssertTrue(caps.isGoModFile)
        XCTAssertFalse(caps.isGoFile)
        XCTAssertFalse(caps.canFormatDocument)
    }

    func testJSONAndJSONCCapabilities() {
        let json = ActiveCommandCapabilities(workspacePath: "/ws", filePath: "/ws/config.json")
        let jsonc = ActiveCommandCapabilities(workspacePath: "/ws", filePath: "/ws/tsconfig.JSONC")
        XCTAssertEqual(json, jsonc)
        XCTAssertTrue(json.isJSONFile)
        XCTAssertTrue(json.canFormatDocument)
        XCTAssertFalse(json.isYAMLFile)
    }

    func testYAMLAndDockerComposeCapabilities() {
        let plainYaml = ActiveCommandCapabilities(workspacePath: "/ws", filePath: "/ws/.github/workflows/ci.yml")
        let composeYaml = ActiveCommandCapabilities(workspacePath: "/ws", filePath: "/ws/docker-compose.prod.yaml")
        XCTAssertTrue(plainYaml.isYAMLFile)
        XCTAssertFalse(plainYaml.isDockerComposeFile)
        XCTAssertTrue(plainYaml.canFormatDocument)
        XCTAssertTrue(composeYaml.isYAMLFile)
        XCTAssertTrue(composeYaml.isDockerComposeFile)
    }

    func testDockerfileVariantsCapabilities() {
        let standard = ActiveCommandCapabilities(workspacePath: "/ws", filePath: "/ws/Dockerfile")
        let suffixed = ActiveCommandCapabilities(workspacePath: "/ws", filePath: "/ws/Dockerfile.worker")
        let extBased = ActiveCommandCapabilities(workspacePath: "/ws", filePath: "/ws/api.dockerfile")
        XCTAssertEqual(standard, suffixed)
        XCTAssertEqual(standard, extBased)
        XCTAssertTrue(standard.isDockerfile)
        XCTAssertFalse(standard.canFormatDocument)
    }

    func testHTTPAndRestCapabilities() {
        let http = ActiveCommandCapabilities(workspacePath: "/ws", filePath: "/ws/requests/api.http")
        let rest = ActiveCommandCapabilities(workspacePath: "/ws", filePath: "/ws/requests/health.REST")
        XCTAssertEqual(http, rest)
        XCTAssertTrue(http.isHTTPFile)
        XCTAssertFalse(http.canFormatDocument)
    }

    func testEnvFileVariantsCapabilities() {
        let dotEnv = ActiveCommandCapabilities(workspacePath: "/ws", filePath: "/ws/.env")
        let dotEnvLocal = ActiveCommandCapabilities(workspacePath: "/ws", filePath: "/ws/.env.local")
        let appEnv = ActiveCommandCapabilities(workspacePath: "/ws", filePath: "/ws/service.env")
        XCTAssertEqual(dotEnv, dotEnvLocal)
        XCTAssertEqual(dotEnv, appEnv)
        XCTAssertTrue(dotEnv.isEnvFile)
        XCTAssertTrue(dotEnv.canFormatDocument)
    }

    func testMakefileVariantsCapabilities() {
        let mk1 = ActiveCommandCapabilities(workspacePath: "/ws", filePath: "/ws/Makefile")
        let mk2 = ActiveCommandCapabilities(workspacePath: "/ws", filePath: "/ws/GNUmakefile")
        let mk3 = ActiveCommandCapabilities(workspacePath: "/ws", filePath: "/ws/rules.mk")
        XCTAssertEqual(mk1, mk2)
        XCTAssertEqual(mk1, mk3)
        XCTAssertTrue(mk1.isMakefile)
        XCTAssertTrue(mk1.canFormatDocument)
    }

    func testSQLProtoAndMarkdownCapabilities() {
        let sql = ActiveCommandCapabilities(workspacePath: "/ws", filePath: "/ws/schema.sql")
        let proto = ActiveCommandCapabilities(workspacePath: "/ws", filePath: "/ws/rpc.proto")
        let md = ActiveCommandCapabilities(workspacePath: "/ws", filePath: "/ws/README.md")
        XCTAssertTrue(sql.isSQLFile)
        XCTAssertTrue(proto.isProtoFile)
        XCTAssertTrue(md.isMarkdownFile)
        XCTAssertFalse(sql.canFormatDocument)
        XCTAssertFalse(proto.canFormatDocument)
        XCTAssertFalse(md.canFormatDocument)
    }

    func testSourceControlAndEditorModeFlagsAffectEquality() {
        let clean = ActiveCommandCapabilities(workspacePath: "/ws", filePath: "/ws/main.go", canSave: true)
        let dirty = ActiveCommandCapabilities(
            workspacePath: "/ws",
            filePath: "/ws/main.go",
            canSave: true,
            canStageActiveFile: true,
            hasActiveFileGitChanges: true
        )
        let diff = ActiveCommandCapabilities(
            workspacePath: "/ws",
            filePath: "/ws/main.go",
            canSave: true,
            isCodeMode: false,
            isDiffMode: true
        )
        XCTAssertNotEqual(clean, dirty)
        XCTAssertNotEqual(clean, diff)
        XCTAssertTrue(dirty.canStageActiveFile)
        XCTAssertTrue(diff.isDiffMode)
    }

    func testUTF16LineTableASCIILinesAndOffsets() {
        let text = "package main\n\nfunc main() {\n\treturn\n}"
        let table = UTF16LineTable(text)
        XCTAssertEqual(table.lineCount, 5)
        XCTAssertEqual(table.lineEnding, "LF")
        XCTAssertEqual(table.utf16Length, text.utf16.count)
        XCTAssertEqual(table.utf8ByteLength, text.utf8.count)
        XCTAssertEqual(table.utf16Offset(line: 1, column: 1), 0)
        XCTAssertEqual(table.utf16Offset(line: 3, column: 6), 19)
        XCTAssertEqual(table.position(atUTF16Offset: 19), TextPosition(line: 3, column: 6))
        XCTAssertEqual(table.utf8Offset(forUTF16Offset: 19), 19)
    }

    func testUTF16LineTableCRLFDetection() {
        let text = "first\r\nsecond\r\nthird"
        let table = UTF16LineTable(text)
        XCTAssertEqual(table.lineEnding, "CRLF")
        XCTAssertEqual(table.lineCount, 3)
        XCTAssertEqual(table.lineStartUTF16Offset(forLine: 2), 7)
        XCTAssertEqual(table.position(atUTF16Offset: 7), TextPosition(line: 2, column: 1))
    }

    func testUTF16LineTableVietnameseAndCJKMultiByteOffsets() {
        let text = "Xin ch\u{00E0}o Ti\u{1EBF}ng Vi\u{1EC7}t\n\u{6771}\u{4EAC} Go"
        let table = UTF16LineTable(text)
        XCTAssertEqual(table.lineCount, 2)
        XCTAssertEqual(table.utf16Length, text.utf16.count)
        XCTAssertEqual(table.utf8ByteLength, text.utf8.count)

        let line2StartU16 = table.lineStartUTF16Offset(forLine: 2)!
        let line2StartU8 = table.utf8Offset(forUTF16Offset: line2StartU16)
        let expectedLine1Bytes = "Xin ch\u{00E0}o Ti\u{1EBF}ng Vi\u{1EC7}t\n".utf8.count
        XCTAssertEqual(line2StartU8, expectedLine1Bytes)
        XCTAssertEqual(table.utf16Offset(forUTF8Offset: expectedLine1Bytes), line2StartU16)

        let goColU16 = table.utf16Offset(line: 2, column: 4)!
        let goColU8 = table.utf8Offset(line: 2, column: 4)!
        XCTAssertEqual(goColU8, expectedLine1Bytes + "\u{6771}\u{4EAC} ".utf8.count)
        XCTAssertEqual(table.utf16Offset(forUTF8Offset: goColU8), goColU16)
        XCTAssertEqual(table.position(atUTF8Offset: goColU8), TextPosition(line: 2, column: 4))
    }

    func testUTF16LineTableSurrogatePairRoundTrip() {
        let mathBoldA = "\u{1D400}"
        let cjkExtB = "\u{20000}"
        XCTAssertEqual(mathBoldA.utf16.count, 2)
        XCTAssertEqual(mathBoldA.utf8.count, 4)

        let text = "a\(mathBoldA)b\n\(cjkExtB)z"
        let table = UTF16LineTable(text)
        XCTAssertEqual(table.utf16Length, 8)
        XCTAssertEqual(table.utf8ByteLength, 12)

        XCTAssertEqual(table.utf8Offset(forUTF16Offset: 0), 0)
        XCTAssertEqual(table.utf8Offset(forUTF16Offset: 1), 1)
        XCTAssertEqual(table.utf8Offset(forUTF16Offset: 3), 5)
        XCTAssertEqual(table.utf8Offset(forUTF16Offset: 5), 7)
        XCTAssertEqual(table.utf8Offset(forUTF16Offset: 7), 11)
        XCTAssertEqual(table.utf8Offset(forUTF16Offset: 8), 12)

        XCTAssertEqual(table.utf16Offset(forUTF8Offset: 5), 3)
        XCTAssertEqual(table.utf16Offset(forUTF8Offset: 7), 5)
        XCTAssertEqual(table.utf16Offset(forUTF8Offset: 11), 7)
        XCTAssertEqual(table.position(atUTF8Offset: 11), TextPosition(line: 2, column: 3))
    }

    func testUTF16LineTableOutOfBoundsClamping() {
        let table = UTF16LineTable("abc\ndef")
        XCTAssertNil(table.lineStartUTF16Offset(forLine: 0))
        XCTAssertNil(table.lineStartUTF16Offset(forLine: 3))
        XCTAssertEqual(table.utf16Offset(line: 1, column: 99), 3)
        XCTAssertEqual(table.position(atUTF16Offset: -5), TextPosition(line: 1, column: 1))
        XCTAssertEqual(table.position(atUTF16Offset: 999), TextPosition(line: 2, column: 4))
    }

    func testMessageFormattingCountSingularPluralAndCustom() {
        XCTAssertEqual(MessageFormatting.count(0, "issue"), "0 issues")
        XCTAssertEqual(MessageFormatting.count(1, "issue"), "1 issue")
        XCTAssertEqual(MessageFormatting.count(4, "issue"), "4 issues")
        XCTAssertEqual(MessageFormatting.count(1, "match", "matches"), "1 match")
        XCTAssertEqual(MessageFormatting.count(3, "match", "matches"), "3 matches")
    }

    func testMessageFormattingHumanizedIdentifiers() {
        XCTAssertEqual(MessageFormatting.humanized("extract_interface"), "Extract interface")
        XCTAssertEqual(MessageFormatting.humanized("wrap_err"), "Wrap err")
        XCTAssertEqual(MessageFormatting.humanized("Already Spaced"), "Already Spaced")
        XCTAssertEqual(MessageFormatting.humanized("PlainWord"), "PlainWord")
    }

    func testMessageFormattingFailureTemplates() {
        XCTAssertTrue(MessageFormatting.previewFailed("extract method").contains("extract method"))
        XCTAssertTrue(MessageFormatting.readFailed("struct layout").contains("struct layout"))
    }

    func testShortcutSpecParsesModifiersAndAliases() {
        let spec = ShortcutSpec("Cmd+Shift+P")
        XCTAssertNotNil(spec)
        XCTAssertEqual(spec?.command, true)
        XCTAssertEqual(spec?.shift, true)
        XCTAssertEqual(spec?.control, false)
        XCTAssertEqual(spec?.option, false)
        XCTAssertEqual(spec?.key, "p")
        XCTAssertEqual(spec?.description, "shift+cmd+p")
        XCTAssertEqual(spec?.display, "\u{21E7}\u{2318}P")
        XCTAssertEqual(spec?.spoken, "Shift-Command-P")
    }

    func testShortcutSpecHandlesPlusKeyAndFunctionKeys() {
        let cmdPlus = ShortcutSpec("cmd++")
        XCTAssertEqual(cmdPlus?.command, true)
        XCTAssertEqual(cmdPlus?.key, "+")
        XCTAssertEqual(cmdPlus?.description, "cmd++")

        let f12 = ShortcutSpec("opt+f12")
        XCTAssertEqual(f12?.option, true)
        XCTAssertEqual(f12?.isFunctionKey, true)
        XCTAssertEqual(f12?.display, "\u{2325}F12")
    }

    func testShortcutSpecHandlesNamedArrowAndEscapeAliases() {
        let esc = ShortcutSpec("esc")
        XCTAssertEqual(esc?.key, "escape")
        XCTAssertEqual(esc?.display, "\u{238B}")

        let nav = ShortcutSpec("ctrl+option+leftarrow")
        XCTAssertEqual(nav?.control, true)
        XCTAssertEqual(nav?.option, true)
        XCTAssertEqual(nav?.key, "left")
        XCTAssertEqual(nav?.spoken, "Control-Option-Left Arrow")
    }

    func testShortcutSpecRejectsMultiChordAndUnknownKeys() {
        XCTAssertNil(ShortcutSpec(""))
        XCTAssertNil(ShortcutSpec("cmd+k cmd+c"))
        XCTAssertNil(ShortcutSpec("super+a"))
        XCTAssertNil(ShortcutSpec("cmd+f25"))
        XCTAssertNil(ShortcutSpec("cmd+"))
    }

    func testShortcutSpecCodableRoundTrip() throws {
        let original = ShortcutSpec(key: "enter", control: true, shift: true, command: true)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ShortcutSpec.self, from: data)
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.description, "ctrl+shift+cmd+enter")
    }

    func testUTF16LineTableEmptyStringInvariants() {
        let table = UTF16LineTable("")
        XCTAssertEqual(table.lineCount, 1)
        XCTAssertEqual(table.utf16Length, 0)
        XCTAssertEqual(table.utf8ByteLength, 0)
        XCTAssertEqual(table.utf16Offset(line: 1, column: 1), 0)
        XCTAssertEqual(table.position(atUTF16Offset: 0), TextPosition(line: 1, column: 1))
        XCTAssertEqual(table.utf8Offset(forUTF16Offset: 0), 0)
        XCTAssertEqual(table.utf16Offset(forUTF8Offset: 0), 0)
    }

    func testUTF16LineTableTrailingNewlineCreatesEmptyLastLine() {
        let table = UTF16LineTable("line1\nline2\n")
        XCTAssertEqual(table.lineCount, 3)
        XCTAssertEqual(table.lineStartUTF16Offset(forLine: 3), 12)
        XCTAssertEqual(table.lineContentEndUTF16Offset(forLine: 3), 12)
        XCTAssertEqual(table.position(atUTF16Offset: 12), TextPosition(line: 3, column: 1))
    }

    func testActiveCommandCapabilitiesCQLAndMarkdownExtensions() {
        let cql = ActiveCommandCapabilities(workspacePath: "/ws", filePath: "/ws/queries/users.cql")
        let markdown = ActiveCommandCapabilities(workspacePath: "/ws", filePath: "/ws/docs/guide.markdown")
        XCTAssertTrue(cql.isSQLFile)
        XCTAssertTrue(markdown.isMarkdownFile)
        XCTAssertFalse(cql.isGoFile)
        XCTAssertFalse(markdown.isGoFile)
    }

    func testSignatureParameterHighlighterExplicitUTF16OffsetRanges() {
        let sig = "func Replace(s string, old string, new string, n int) string"
        let params: [SignatureParameterHighlighter.ParameterSpec] = [
            .init(label: "s string", utf16Range: 13..<21),
            .init(label: "old string", utf16Range: 23..<33),
            .init(label: "new string", utf16Range: 35..<45),
            .init(label: "n int", utf16Range: 47..<52)
        ]
        XCTAssertEqual(SignatureParameterHighlighter.activeUTF16Range(signatureLabel: sig, parameters: params, activeParameter: 0), 13..<21)
        XCTAssertEqual(SignatureParameterHighlighter.activeUTF16Range(signatureLabel: sig, parameters: params, activeParameter: 2), 35..<45)
        XCTAssertEqual(SignatureParameterHighlighter.activeUTF16Range(signatureLabel: sig, parameters: params, activeParameter: 3), 47..<52)
        XCTAssertNil(SignatureParameterHighlighter.activeUTF16Range(signatureLabel: sig, parameters: params, activeParameter: 4))
    }

    func testSignatureParameterHighlighterSubstringLabelsAvoidFunctionAndReceiverCollisions() {
        let sig = "func (s *Strings) Replace(s, old, new string, n int) string"
        let params: [SignatureParameterHighlighter.ParameterSpec] = [
            .init(label: "s"),
            .init(label: "old"),
            .init(label: "new string"),
            .init(label: "n int")
        ]

        let ns = sig as NSString
        let r0 = SignatureParameterHighlighter.activeUTF16Range(signatureLabel: sig, parameters: params, activeParameter: 0)
        XCTAssertNotNil(r0)
        XCTAssertEqual(ns.substring(with: NSRange(location: r0!.lowerBound, length: r0!.count)), "s")
        XCTAssertGreaterThan(r0!.lowerBound, ns.range(of: "Replace(").location)

        let r1 = SignatureParameterHighlighter.activeUTF16Range(signatureLabel: sig, parameters: params, activeParameter: 1)
        XCTAssertNotNil(r1)
        XCTAssertEqual(ns.substring(with: NSRange(location: r1!.lowerBound, length: r1!.count)), "old")

        let r3 = SignatureParameterHighlighter.activeUTF16Range(signatureLabel: sig, parameters: params, activeParameter: 3)
        XCTAssertNotNil(r3)
        XCTAssertEqual(ns.substring(with: NSRange(location: r3!.lowerBound, length: r3!.count)), "n int")
    }

    func testSignatureParameterHighlighterAdvancesPastIdenticalTypes() {
        let sig = "func Copy(dst []byte, src []byte) int"
        let params: [SignatureParameterHighlighter.ParameterSpec] = [
            .init(label: "[]byte"),
            .init(label: "[]byte")
        ]
        let first = SignatureParameterHighlighter.activeUTF16Range(signatureLabel: sig, parameters: params, activeParameter: 0)
        let second = SignatureParameterHighlighter.activeUTF16Range(signatureLabel: sig, parameters: params, activeParameter: 1)
        XCTAssertNotNil(first)
        XCTAssertNotNil(second)
        XCTAssertLessThan(first!.upperBound, second!.lowerBound)
    }

    func testMarkdownTaskToggleComputesIncrementalUTF16Range() {
        let md = "# Roadmap\n- [ ] Write unit tests\n- [x] Fix split headers\n- [X] Wire PopupAnchor\nPlain bullet"
        let edit0 = MarkdownTaskToggle.edit(in: md, atZeroBasedLine: 1)
        XCTAssertEqual(edit0, MarkdownTaskToggle.Edit(range: NSRange(location: 12, length: 3), replacement: "[x]"))

        let edit1 = MarkdownTaskToggle.edit(in: md, atZeroBasedLine: 2)
        XCTAssertEqual(edit1, MarkdownTaskToggle.Edit(range: NSRange(location: 35, length: 3), replacement: "[ ]"))

        let edit2 = MarkdownTaskToggle.edit(in: md, atZeroBasedLine: 3)
        XCTAssertEqual(edit2, MarkdownTaskToggle.Edit(range: NSRange(location: 59, length: 3), replacement: "[ ]"))

        XCTAssertNil(MarkdownTaskToggle.edit(in: md, atZeroBasedLine: 0))
        XCTAssertNil(MarkdownTaskToggle.edit(in: md, atZeroBasedLine: 4))
        XCTAssertNil(MarkdownTaskToggle.edit(in: md, atZeroBasedLine: 99))
    }

    func testGopilotProseCitationPreservesRepeatedInlineReferencesWithoutGrammarHoles() {
        let ev1 = GopilotProseEvidenceRef(id: "E1", path: "internal/store/store.go", startLine1Based: 42)
        let ev2 = GopilotProseEvidenceRef(id: "E2", path: "internal/store/cache.go", startLine1Based: 18)
        let evidenceByID = ["E1": ev1, "E2": ev2]

        let segments: [GopilotProseSegment] = [
            .text("The map is initialized in store.go:42 "),
            .citation(ev1),
            .text(" at line 42. Notice "),
            .citation(ev1),
            .text(" mutates entries without holding mu; see "),
            .citation(ev1),
            .text(", "),
            .citation(ev2),
            .text(" when store.go:42 races with cache eviction.")
        ]

        let linked = GopilotProseCitationEngine.linkedMarkdown("", segments: segments)
        let rendered = GopilotProseCitationEngine.linkifyReferences(in: linked, evidenceByID: evidenceByID)

        XCTAssertFalse(rendered.contains("Notice mutates"))
        XCTAssertFalse(rendered.contains("see ,"))
        XCTAssertFalse(rendered.contains("in at line"))
        XCTAssertTrue(rendered.contains("in [store.go:42](gopilot-citation://E1) at line 42."))
        XCTAssertTrue(rendered.contains("Notice [store.go:42](gopilot-citation://E1) mutates entries"))
        XCTAssertTrue(rendered.contains("see [store.go:42](gopilot-citation://E1), [cache.go:18](gopilot-citation://E2)"))
        XCTAssertTrue(rendered.contains("when [store.go:42](gopilot-file://open?path=internal/store/store.go&line=42) races"))
    }

    func testGopilotProseCitationCoalescesAdjacentDuplicateChipsWithoutDanglingComma() {
        let ev1 = GopilotProseEvidenceRef(id: "E1", path: "pkg/db/store.go", startLine1Based: 42)
        let ev2 = GopilotProseEvidenceRef(id: "E2", path: "pkg/db/store.go", startLine1Based: 42)
        let ev3 = GopilotProseEvidenceRef(id: "E3", path: "pkg/db/tx.go", startLine1Based: 90)

        let segments: [GopilotProseSegment] = [
            .text("Check "),
            .citation(ev1),
            .text(", "),
            .citation(ev2),
            .text(", "),
            .citation(ev3),
            .text(".")
        ]

        let linked = GopilotProseCitationEngine.linkedMarkdown("", segments: segments)
        let rendered = GopilotProseCitationEngine.linkifyReferences(
            in: linked,
            evidenceByID: ["E1": ev1, "E2": ev2, "E3": ev3]
        )

        XCTAssertEqual(
            rendered,
            "Check [store.go:42](gopilot-citation://E1), [tx.go:90](gopilot-citation://E3)."
        )
    }

    func testGopilotProseCitationDisambiguatesSameBasenameAcrossDirectories() {
        let ev1 = GopilotProseEvidenceRef(id: "E1", path: "internal/alpha/store.go", startLine1Based: 42)
        let ev2 = GopilotProseEvidenceRef(id: "E2", path: "internal/beta/store.go", startLine1Based: 42)
        let raw = "Compare [store.go:42](gopilot-citation://E1) with [store.go:42](gopilot-citation://E2) and revisit [store.go:42](gopilot-citation://E1)."
        let rendered = GopilotProseCitationEngine.linkifyReferences(
            in: raw,
            evidenceByID: ["E1": ev1, "E2": ev2]
        )

        XCTAssertTrue(rendered.contains("[alpha/store.go:42](gopilot-citation://E1)"))
        XCTAssertTrue(rendered.contains("[beta/store.go:42](gopilot-citation://E2)"))
        let alphaMatches = rendered.components(separatedBy: "[alpha/store.go:42](gopilot-citation://E1)").count - 1
        XCTAssertEqual(alphaMatches, 2)
    }

    func testGopilotProseCitationStripUnresolvedPreservesInlineRangedFileReference() {
        let raw = "Failure originates in [E1: store.go:42] at line 42; see [E1, E2]."
        let stripped = GopilotProseCitationEngine.stripUnresolvedTokens(raw)
        XCTAssertEqual(stripped, "Failure originates in store.go:42 at line 42; see.")
        XCTAssertEqual(GopilotProseCitationEngine.normalize("Refs [E1, E2] and E3E4"), "Refs [E1] [E2] and [E3] [E4]")
    }

    func testWorkspaceColumnLayoutMathAutoCompactsAt920AndPreservesEditorMinimum() {
        XCTAssertEqual(WorkspaceColumnLayoutMath.minWindowWidth, 920)
        XCTAssertEqual(WorkspaceColumnLayoutMath.minWindowHeight, 580)
        XCTAssertEqual(WorkspaceColumnLayoutMath.defaultWindowWidth, 1280)
        XCTAssertEqual(WorkspaceColumnLayoutMath.defaultWindowHeight, 820)
        XCTAssertEqual(WorkspaceColumnLayoutMath.sidebarMinWidth, 210)
        XCTAssertEqual(WorkspaceColumnLayoutMath.sidebarIdealWidth, 256)
        XCTAssertEqual(WorkspaceColumnLayoutMath.sidebarMaxWidth, 320)
        XCTAssertEqual(WorkspaceColumnLayoutMath.editorMinWidth, 380)
        XCTAssertEqual(WorkspaceColumnLayoutMath.gopilotMinWidth, 300)
        XCTAssertEqual(WorkspaceColumnLayoutMath.gopilotIdealWidth, 360)
        XCTAssertEqual(WorkspaceColumnLayoutMath.gopilotMaxWidth, 480)

        XCTAssertTrue(
            WorkspaceColumnLayoutMath.shouldAutoCollapseSidebarOnGopilotOpen(
                windowWidth: 920,
                detailWidth: 664,
                isSidebarVisible: true,
                gopilotChromeInset: 16
            )
        )
        XCTAssertFalse(
            WorkspaceColumnLayoutMath.shouldAutoCollapseSidebarOnGopilotOpen(
                windowWidth: 1280,
                detailWidth: 1024,
                isSidebarVisible: true,
                gopilotChromeInset: 16
            )
        )

        let compact920 = WorkspaceColumnLayoutMath.resolveDetailColumns(
            windowWidth: 920,
            detailWidth: 664,
            isSidebarVisible: true,
            isGopilotVisible: true,
            requestedGopilotWidth: 360,
            gopilotChromeInset: 16
        )
        XCTAssertTrue(compact920.shouldCollapseSidebar)
        XCTAssertEqual(compact920.clampedGopilotWidth, 360)
        XCTAssertGreaterThanOrEqual(920 - compact920.clampedGopilotWidth - 16, WorkspaceColumnLayoutMath.editorMinWidth)

        let threeColumn920 = WorkspaceColumnLayoutMath.resolveDetailColumns(
            windowWidth: 920,
            detailWidth: 920 - WorkspaceColumnLayoutMath.sidebarMinWidth,
            isSidebarVisible: true,
            isGopilotVisible: true,
            requestedGopilotWidth: 420,
            gopilotChromeInset: 16
        )
        XCTAssertFalse(threeColumn920.shouldCollapseSidebar)
        XCTAssertEqual(threeColumn920.clampedGopilotWidth, 314)
        let editorAt920 = (920 - WorkspaceColumnLayoutMath.sidebarMinWidth) - threeColumn920.clampedGopilotWidth - 16
        XCTAssertGreaterThanOrEqual(editorAt920, WorkspaceColumnLayoutMath.editorMinWidth)

        let wide1600 = WorkspaceColumnLayoutMath.resolveDetailColumns(
            windowWidth: 1600,
            detailWidth: 1344,
            isSidebarVisible: true,
            isGopilotVisible: true,
            requestedGopilotWidth: 600,
            gopilotChromeInset: 16
        )
        XCTAssertFalse(wide1600.shouldCollapseSidebar)
        XCTAssertEqual(wide1600.clampedGopilotWidth, 480)
    }

    func testDurationFormatterProducesLocaleSafeUnits() {
        XCTAssertEqual(TestDurationFormatter.format(seconds: 0.0002), "<1 ms")
        XCTAssertEqual(TestDurationFormatter.format(seconds: 0.0142), "14 ms")
        XCTAssertEqual(TestDurationFormatter.format(seconds: 1.25), "1.25 s")
        XCTAssertEqual(TestDurationFormatter.format(seconds: 12.34), "12.3 s")
        XCTAssertEqual(TestDurationFormatter.format(seconds: 62.5), "1m 2.5s")
    }

    func testMultiWindowWorkspaceSessionsIsolateStateAndSheetRouter() {
        let coordinator = WorkspaceSessionCoordinator()
        let sessionA = coordinator.registerSession(workspacePath: "/tmp/golens-proj-alpha/", makeActive: true)
        let sessionB = coordinator.registerSession(workspacePath: "/tmp/golens-proj-beta", makeActive: false)

        XCTAssertNotEqual(sessionA.id, sessionB.id)
        XCTAssertEqual(sessionA.activeWorkspacePath, "/tmp/golens-proj-alpha")
        XCTAssertEqual(sessionB.activeWorkspacePath, "/tmp/golens-proj-beta")
        XCTAssertEqual(coordinator.activeSession?.id, sessionA.id)

        sessionA.openFile("/tmp/golens-proj-alpha/cmd/server/main.go")
        sessionA.openFile("/tmp/golens-proj-alpha/internal/store/db.go")
        sessionA.editedFiles.insert("/tmp/golens-proj-alpha/internal/store/db.go")

        sessionB.openFile("/tmp/golens-proj-beta/pkg/worker/pool.go")

        XCTAssertEqual(sessionA.openFiles, [
            "/tmp/golens-proj-alpha/cmd/server/main.go",
            "/tmp/golens-proj-alpha/internal/store/db.go"
        ])
        XCTAssertEqual(sessionA.activeFilePath, "/tmp/golens-proj-alpha/internal/store/db.go")
        XCTAssertEqual(sessionB.openFiles, ["/tmp/golens-proj-beta/pkg/worker/pool.go"])
        XCTAssertEqual(sessionB.activeFilePath, "/tmp/golens-proj-beta/pkg/worker/pool.go")
        XCTAssertTrue(sessionB.editedFiles.isEmpty)

        sessionA.setSheetPresented(.goToLine, true)
        XCTAssertEqual(sessionA.activeSheetKind, .goToLine)
        XCTAssertNil(sessionB.activeSheetKind)

        sessionA.setSheetPresented(.structLayout, true)
        XCTAssertEqual(sessionA.activeSheetKind, .structLayout)
        XCTAssertFalse(sessionA.isSheetPresented(.goToLine))
        XCTAssertTrue(sessionA.isSheetPresented(.structLayout))

        sessionA.setSheetPresented(.goToLine, false)
        XCTAssertEqual(sessionA.activeSheetKind, .structLayout)

        sessionB.setSheetPresented(.runConfigurations, true)
        XCTAssertEqual(sessionA.activeSheetKind, .structLayout)
        XCTAssertEqual(sessionB.activeSheetKind, .runConfigurations)

        sessionA.setSheetPresented(.structLayout, false)
        XCTAssertNil(sessionA.activeSheetKind)
        XCTAssertEqual(sessionB.activeSheetKind, .runConfigurations)
    }

    func testWorkspaceSessionCoordinatorRoutingFocusActivationAndColdLaunch() {
        let coordinator = WorkspaceSessionCoordinator()
        let emptySession = coordinator.registerSession(workspacePath: "", makeActive: true)

        XCTAssertEqual(
            coordinator.routingDecision(forTargetPath: "/tmp/golens-one", preferredEmptySessionID: emptySession.id),
            .bindCurrentWindow(sessionID: emptySession.id)
        )

        coordinator.updateWorkspacePath("/tmp/golens-one/", for: emptySession.id)
        XCTAssertEqual(emptySession.activeWorkspacePath, "/tmp/golens-one")

        XCTAssertEqual(
            coordinator.routingDecision(forTargetPath: "/tmp/golens-one"),
            .focusExistingWindow(sessionID: emptySession.id)
        )
        XCTAssertEqual(
            coordinator.routingDecision(forTargetPath: "/tmp/golens-two/"),
            .openDedicatedWindow(canonicalPath: "/tmp/golens-two")
        )

        let secondSession = coordinator.registerSession(workspacePath: "/tmp/golens-one/services/billing", makeActive: true)
        XCTAssertEqual(coordinator.activeSession?.id, secondSession.id)

        XCTAssertEqual(
            coordinator.session(containingFilePath: "/tmp/golens-one/main.go")?.id,
            emptySession.id
        )
        XCTAssertEqual(
            coordinator.session(containingFilePath: "/tmp/golens-one/services/billing/invoice.go")?.id,
            secondSession.id
        )
        XCTAssertNil(coordinator.session(containingFilePath: "/tmp/golens-one-extra/main.go"))

        coordinator.removeSession(id: secondSession.id)
        XCTAssertEqual(coordinator.activeSession?.id, emptySession.id)

        XCTAssertEqual(
            WorkspaceSessionCoordinator.coldLaunchDecision(
                restoredWorkspacePath: "/tmp/golens-smoke/",
                restoredFilePath: "/tmp/golens-smoke/main.go"
            ),
            .claimInitialWorkspace(
                canonicalPath: "/tmp/golens-smoke",
                initialFilePath: "/tmp/golens-smoke/main.go"
            )
        )
        XCTAssertEqual(
            WorkspaceSessionCoordinator.coldLaunchDecision(restoredWorkspacePath: "   ", restoredFilePath: nil),
            .presentWelcomeAndCloseEmptyWorkspace
        )
    }

    func testOpticalLensAdaptiveDisplayResolves13InchVs21InchAndOverrides() {
        XCTAssertEqual(
            WorkspaceColumnLayoutMath.resolveOpticalLensStyle(
                mode: .automatic,
                viewportWidth: 1024,
                screenWidth: 1280
            ),
            .inline
        )
        XCTAssertEqual(
            WorkspaceColumnLayoutMath.resolveOpticalLensStyle(
                mode: .automatic,
                viewportWidth: 1184,
                screenWidth: 1440
            ),
            .inline
        )
        XCTAssertEqual(
            WorkspaceColumnLayoutMath.resolveOpticalLensStyle(
                mode: .automatic,
                viewportWidth: 1214,
                screenWidth: 1470
            ),
            .inline
        )

        XCTAssertEqual(
            WorkspaceColumnLayoutMath.resolveOpticalLensStyle(
                mode: .automatic,
                viewportWidth: 1024,
                screenWidth: 1920
            ),
            .column(width: WorkspaceColumnLayoutMath.opticalLensExpandedWidth)
        )
        XCTAssertEqual(
            WorkspaceColumnLayoutMath.resolveOpticalLensStyle(
                mode: .automatic,
                viewportWidth: 1560,
                screenWidth: 2560
            ),
            .column(width: WorkspaceColumnLayoutMath.opticalLensExpandedWidth)
        )

        XCTAssertEqual(
            WorkspaceColumnLayoutMath.resolveOpticalLensStyle(
                mode: .automatic,
                viewportWidth: 512,
                screenWidth: 1920
            ),
            .inline
        )

        XCTAssertEqual(
            WorkspaceColumnLayoutMath.resolveOpticalLensStyle(
                mode: .column,
                viewportWidth: 900,
                screenWidth: 1440
            ),
            .column(width: WorkspaceColumnLayoutMath.opticalLensExpandedWidth)
        )
        XCTAssertEqual(
            WorkspaceColumnLayoutMath.resolveOpticalLensStyle(
                mode: .column,
                viewportWidth: 520,
                screenWidth: 1440
            ),
            .inline
        )
        XCTAssertEqual(
            WorkspaceColumnLayoutMath.resolveOpticalLensStyle(
                mode: .inline,
                viewportWidth: 1600,
                screenWidth: 2560
            ),
            .inline
        )
        XCTAssertEqual(
            WorkspaceColumnLayoutMath.resolveOpticalLensStyle(
                mode: .off,
                viewportWidth: 1600,
                screenWidth: 2560
            ),
            .minimalOnly
        )
    }

    func testDiffHorizontalScrollMetricsOverflowAndClamping() {
        let fitting = DiffHorizontalScrollMetrics(contentWidth: 420, viewportWidth: 500, offset: 80)
        XCTAssertFalse(fitting.needsScrollbar)
        XCTAssertEqual(fitting.maxOffset, 0)
        XCTAssertEqual(fitting.clampedOffset, 0)
        XCTAssertEqual(fitting.knobProportion, 1.0, accuracy: 0.0001)
        XCTAssertEqual(fitting.normalizedValue, 0.0, accuracy: 0.0001)

        let overflowing = DiffHorizontalScrollMetrics(contentWidth: 1000, viewportWidth: 400, offset: 240)
        XCTAssertTrue(overflowing.needsScrollbar)
        XCTAssertEqual(overflowing.maxOffset, 600)
        XCTAssertEqual(overflowing.clampedOffset, 240)
        XCTAssertEqual(overflowing.knobProportion, 0.4, accuracy: 0.0001)
        XCTAssertEqual(overflowing.normalizedValue, 0.4, accuracy: 0.0001)
        XCTAssertEqual(DiffHorizontalScrollMetrics.offset(fromNormalized: 0.5, maxOffset: 600), 300, accuracy: 0.0001)

        let overscrolled = DiffHorizontalScrollMetrics(contentWidth: 1000, viewportWidth: 400, offset: 950)
        XCTAssertEqual(overscrolled.clampedOffset, 600)
    }

    func testDiffHorizontalScrollWheelAndScrollerStepping() {
        let trackpad = DiffHorizontalScrollMetrics.wheelAdjustedOffset(
            current: 100,
            maxOffset: 500,
            scrollingDeltaX: -48,
            scrollingDeltaY: -6,
            isPrecise: true,
            shiftHeld: false
        )
        XCTAssertNotNil(trackpad)
        XCTAssertEqual(trackpad?.newOffset ?? -1, 148, accuracy: 0.0001)
        XCTAssertEqual(trackpad?.consumedVerticalAsHorizontal, false)

        let shiftWheel = DiffHorizontalScrollMetrics.wheelAdjustedOffset(
            current: 100,
            maxOffset: 500,
            scrollingDeltaX: 0,
            scrollingDeltaY: -3,
            isPrecise: false,
            shiftHeld: true
        )
        XCTAssertNotNil(shiftWheel)
        XCTAssertEqual(shiftWheel?.newOffset ?? -1, 136, accuracy: 0.0001)
        XCTAssertEqual(shiftWheel?.consumedVerticalAsHorizontal, true)

        let pureVertical = DiffHorizontalScrollMetrics.wheelAdjustedOffset(
            current: 100,
            maxOffset: 500,
            scrollingDeltaX: 0,
            scrollingDeltaY: -24,
            isPrecise: true,
            shiftHeld: false
        )
        XCTAssertNil(pureVertical)

        XCTAssertEqual(
            DiffHorizontalScrollMetrics.steppedOffset(current: 100, maxOffset: 500, viewportWidth: 300, part: .incrementPage),
            355
        )
        XCTAssertEqual(
            DiffHorizontalScrollMetrics.steppedOffset(current: 100, maxOffset: 500, viewportWidth: 300, part: .decrementPage),
            0
        )
        XCTAssertEqual(
            DiffHorizontalScrollMetrics.steppedOffset(current: 350, maxOffset: 500, viewportWidth: 300, part: .incrementPage),
            500
        )
        XCTAssertNil(
            DiffHorizontalScrollMetrics.steppedOffset(current: 100, maxOffset: 500, viewportWidth: 300, part: .knob)
        )
    }

    func testDiffEstimatedColumnWidthAccountsForLongAndTabIndentedLines() {
        let shortWidth = DiffHorizontalScrollMetrics.estimatedColumnWidth(lines: ["package main", "func ok() {}"])
        let longLine = "\t\t\tif (!resp.total) { el.innerHTML = '<div class=\"empty\">No nodes registered</div>'; return; }"
        let longWidth = DiffHorizontalScrollMetrics.estimatedColumnWidth(lines: ["package main", longLine])
        XCTAssertGreaterThan(longWidth, shortWidth + 500)
        XCTAssertGreaterThan(longWidth, 750)
    }

    func testToolbarClusterMetricsExpandsTitleAdaptivelyWithoutCrowdingPill() {
        let minimum = ToolbarClusterMetrics.resolve(availableWidth: 360, hasIssues: true)
        XCTAssertEqual(minimum.titleMaxWidth, ToolbarClusterMetrics.titleHardMinWidth)
        XCTAssertEqual(minimum.pillWidth, ToolbarClusterMetrics.pillMinWidth)

        let compact13In = ToolbarClusterMetrics.resolve(availableWidth: 700, hasIssues: false)
        XCTAssertGreaterThanOrEqual(compact13In.titleMaxWidth, ToolbarClusterMetrics.titleCompactMinWidth)
        XCTAssertLessThanOrEqual(compact13In.titleMaxWidth + compact13In.pillWidth, compact13In.usableWidth)

        let standard13In = ToolbarClusterMetrics.resolve(availableWidth: 1040, hasIssues: false)
        XCTAssertGreaterThan(standard13In.titleMaxWidth, 300)
        XCTAssertEqual(standard13In.pillWidth, ToolbarClusterMetrics.pillMaxWidthCap)

        let wideWindow = ToolbarClusterMetrics.resolve(availableWidth: 1280, hasIssues: false)
        XCTAssertEqual(wideWindow.titleMaxWidth, ToolbarClusterMetrics.titleMaxWidthCap)
        XCTAssertEqual(wideWindow.pillWidth, ToolbarClusterMetrics.pillMaxWidthCap)
    }

    func testGitBranchSummaryParsingAndEffectiveBranchFallback() {
        let raw = "feat/s3-cluster-routing\0Sang Tran\01794470000\nmain\0Duy Le\01794400000\n"
        let parsed = GitBranchSummary.parseForEachRef(raw)
        XCTAssertEqual(parsed.count, 2)
        XCTAssertEqual(parsed[0].name, "feat/s3-cluster-routing")
        XCTAssertEqual(parsed[0].author, "Sang Tran")
        XCTAssertEqual(parsed[0].date, Date(timeIntervalSince1970: 1_794_470_000))
        XCTAssertEqual(parsed[1].name, "main")

        let seededFromCached = GitBranchSummary.resolveEffectiveBranches(
            currentBranch: "feat/s3-cluster-routing",
            loaded: [],
            cached: parsed,
            knownBranchNames: ["main"]
        )
        XCTAssertEqual(seededFromCached, parsed)

        let seededWithNewActiveBranch = GitBranchSummary.resolveEffectiveBranches(
            currentBranch: "hotfix/urgent",
            loaded: [],
            cached: parsed,
            knownBranchNames: []
        )
        XCTAssertEqual(seededWithNewActiveBranch.map(\.name), ["hotfix/urgent", "feat/s3-cluster-routing", "main"])

        let seededFromNamesOnly = GitBranchSummary.resolveEffectiveBranches(
            currentBranch: "main",
            loaded: [],
            cached: [],
            knownBranchNames: ["development", "main", "release/1.0"]
        )
        XCTAssertEqual(seededFromNamesOnly.map(\.name), ["development", "main", "release/1.0"])
    }

    func testBranchPopoverLayoutHeightAndKeyboardSelection() {
        let current = GitBranchSummary(name: "feat/s3-cluster-routing", author: "Sang Tran", date: Date())
        let others = [
            GitBranchSummary(name: "main", author: "Sang Tran", date: Date()),
            GitBranchSummary(name: "development", author: "Duy Le", date: Date()),
            GitBranchSummary(name: "release/v1.0", author: "Duy Le", date: Date())
        ]
        let fourBranchHeight = BranchPopoverLayoutMath.resolvedListHeight(
            measuredContentHeight: 0,
            currentBranch: current,
            otherBranches: others
        )
        XCTAssertGreaterThan(fourBranchHeight, 200)
        XCTAssertLessThanOrEqual(fourBranchHeight, BranchPopoverLayoutMath.maxListHeight)

        let manyOthers = (0..<20).map { idx in
            GitBranchSummary(name: "feat/branch-\(idx)", author: "Dev", date: Date())
        }
        let cappedHeight = BranchPopoverLayoutMath.resolvedListHeight(
            measuredContentHeight: 920,
            currentBranch: current,
            otherBranches: manyOthers
        )
        XCTAssertEqual(cappedHeight, BranchPopoverLayoutMath.maxListHeight)

        let names = others.map(\.name)
        XCTAssertEqual(BranchPopoverLayoutMath.moveSelection(current: nil, candidates: names, delta: 1), "main")
        XCTAssertEqual(BranchPopoverLayoutMath.moveSelection(current: "main", candidates: names, delta: 1), "development")
        XCTAssertEqual(BranchPopoverLayoutMath.moveSelection(current: "release/v1.0", candidates: names, delta: 1), "release/v1.0")
        XCTAssertEqual(BranchPopoverLayoutMath.moveSelection(current: "main", candidates: names, delta: -1), "main")
    }
}
