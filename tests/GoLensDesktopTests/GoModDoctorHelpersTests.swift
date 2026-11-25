import XCTest
@testable import GoLensFoundation

final class GoModDoctorHelpersTests: XCTestCase {
    func testDetectsSingleLineAndBlockLocalReplacesIgnoringRemoteForks() {
        let goMod = """
        module example.com/app

        go 1.24.0

        require example.com/lib v1.0.0

        replace example.com/local => ../local

        replace (
        \texample.com/sub v1.2.0 => ./sub // keep trailing comment check
        \texample.com/fork v1.0.0 => example.com/fork-fix v1.0.1
        )
        """

        let locals = GoModDoctorHelpers.localReplaces(in: goMod)
        XCTAssertEqual(locals.count, 2)
        XCTAssertEqual(locals[0].line, 7)
        XCTAssertEqual(locals[0].oldModule, "example.com/local")
        XCTAssertEqual(locals[0].target, "../local")
        XCTAssertEqual(locals[1].line, 10)
        XCTAssertEqual(locals[1].oldModule, "example.com/sub")
        XCTAssertEqual(locals[1].target, "./sub")

        let all = GoModDoctorHelpers.allReplaces(in: goMod)
        XCTAssertEqual(all.count, 3)
        XCTAssertFalse(all[2].isLocal)
    }

    func testRemovingLocalReplacesPreservesRemoteReplaceInsideBlock() {
        let goMod = """
        module example.com/app

        go 1.24.0

        replace example.com/local => ../local

        replace (
        \texample.com/sub v1.2.0 => ./sub
        \texample.com/fork v1.0.0 => example.com/fork-fix v1.0.1
        )
        """

        let cleaned = GoModDoctorHelpers.removingLocalReplaces(in: goMod)
        XCTAssertFalse(cleaned.contains("../local"))
        XCTAssertFalse(cleaned.contains("./sub"))
        XCTAssertTrue(cleaned.contains("example.com/fork v1.0.0 => example.com/fork-fix v1.0.1"))
        XCTAssertTrue(cleaned.contains("replace ("))
        XCTAssertTrue(GoModDoctorHelpers.localReplaces(in: cleaned).isEmpty)
    }

    func testRemovingAllReplacesInBlockCollapsesEntireBlock() {
        let goMod = "module example.com/app\n\ngo 1.24.0\n\nreplace (\n\texample.com/a => ../a\n\texample.com/b => ./b\n)\n"
        let cleaned = GoModDoctorHelpers.removingLocalReplaces(in: goMod)
        XCTAssertEqual(cleaned, "module example.com/app\n\ngo 1.24.0\n")
    }

    func testRemovingSingleReplaceByLineLeavesOtherReplacesIntact() {
        let goMod = "module example.com/app\n\nreplace example.com/a => ../a\nreplace example.com/b => ../b\n"
        let cleaned = GoModDoctorHelpers.removingLocalReplaces(in: goMod, matchingLines: [3])
        XCTAssertFalse(cleaned.contains("../a"))
        XCTAssertTrue(cleaned.contains("replace example.com/b => ../b"))
    }

    func testGoWorkUpdatesGoVersionAndAddsAndRemovesModules() {
        let initial = "go 1.24.0\n\nuse ./api\n"
        let updatedVer = GoModDoctorHelpers.updatingGoWorkVersion(in: initial, to: "1.26.2")
        XCTAssertTrue(updatedVer.hasPrefix("go 1.26.2\n"))

        let withCli = GoModDoctorHelpers.addingUseModule(in: updatedVer, relPath: "cli")
        XCTAssertTrue(withCli.contains("use (\n\t./api\n\t./cli\n)"))

        let deduplicated = GoModDoctorHelpers.addingUseModule(in: withCli, relPath: "./cli")
        XCTAssertEqual(deduplicated, withCli)

        let removedApi = GoModDoctorHelpers.removingUseModule(in: withCli, rawEntry: "./api")
        XCTAssertFalse(removedApi.contains("./api"))
        XCTAssertTrue(removedApi.contains("./cli"))
    }

    func testFormatGoModWhyMarkdownForNeededAndUnusedAndError() {
        let needed = GoModWhyReplyDTO(
            module: "golang.org/x/sync",
            needed: true,
            summary: "example.com/app -> golang.org/x/sync/errgroup",
            stanzas: [
                GoModWhyStanzaDTO(
                    header: "golang.org/x/sync/errgroup",
                    chain: ["example.com/app", "golang.org/x/sync/errgroup"]
                )
            ]
        )
        let mdNeeded = GoModDoctorHelpers.formatGoModWhyMarkdown(module: "golang.org/x/sync", reply: needed)
        XCTAssertTrue(mdNeeded.contains("```go\nmodule golang.org/x/sync\n```"))
        XCTAssertTrue(mdNeeded.contains("### Dependency Chain"))
        XCTAssertTrue(mdNeeded.contains("`example.com/app` -> `golang.org/x/sync/errgroup`"))

        let unused = GoModWhyReplyDTO(
            module: "example.com/unused",
            needed: false,
            summary: "main module does not need module example.com/unused"
        )
        let mdUnused = GoModDoctorHelpers.formatGoModWhyMarkdown(module: "example.com/unused", reply: unused)
        XCTAssertTrue(mdUnused.contains("### Not Used in Build Graph"))
        XCTAssertTrue(mdUnused.contains("Run go mod tidy"))
        XCTAssertFalse(mdUnused.hasPrefix("### Info"))

        let failed = GoModWhyReplyDTO(module: "example.com/bad", needed: false, summary: "", error: "go: no module")
        let mdError = GoModDoctorHelpers.formatGoModWhyMarkdown(module: "example.com/bad", reply: failed)
        XCTAssertTrue(mdError.contains("### Unable to Trace Dependency"))
        XCTAssertTrue(mdError.contains("go: no module"))
        XCTAssertFalse(mdError.hasPrefix("### Error"))
    }

    func testModuleDoctorDiagnosticBucketSurvivesStartupResetAndLintClear() {
        var bucket = ModuleDoctorDiagnosticBucket<String>()
        let wsA = "/tmp/workspace-a"
        let wsB = "/tmp/workspace-b"
        let modCanon = "/tmp/workspace-a/go.mod"

        bucket.set(["err1", "warn1"], forPath: modCanon, activeWorkspace: wsA)
        XCTAssertEqual(bucket.entriesByPath[modCanon], ["err1", "warn1"])

        bucket.syncWorkspaceOnNonDoctorReset(activeWorkspace: wsA)
        XCTAssertEqual(bucket.entriesByPath[modCanon], ["err1", "warn1"])

        XCTAssertTrue(bucket.release(path: "/var/tmp/../tmp/workspace-a/go.mod", canonicalPath: modCanon))
        XCTAssertNil(bucket.entriesByPath[modCanon])

        bucket.set(["warn-after-reopen"], forPath: modCanon, activeWorkspace: wsA)
        bucket.set([], forPath: modCanon, activeWorkspace: wsA)
        XCTAssertNil(bucket.entriesByPath[modCanon])

        bucket.set(["err1"], forPath: modCanon, activeWorkspace: wsA)
        bucket.syncWorkspaceOnNonDoctorReset(activeWorkspace: wsB)
        XCTAssertTrue(bucket.entriesByPath.isEmpty)
        XCTAssertEqual(bucket.workspace, wsB)
    }

    func testGoModInspectDTODecodesUpdateErrorAndRequires() throws {
        let json = """
        {
          "modulePath": "example.com/app",
          "moduleLine": 1,
          "goVersion": "1.24.0",
          "requires": [
            {"line": 5, "module": "example.com/dep", "version": "v1.0.0", "indirect": false}
          ],
          "updateError": "go: module lookup failed"
        }
        """
        let dto = try JSONDecoder().decode(GoModInspectDTO.self, from: Data(json.utf8))
        XCTAssertEqual(dto.updateError, "go: module lookup failed")
        XCTAssertEqual(dto.requires?.first?.line, 5)
        XCTAssertEqual(dto.requires?.first?.module, "example.com/dep")
    }
}
