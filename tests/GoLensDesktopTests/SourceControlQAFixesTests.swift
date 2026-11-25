import XCTest
@testable import GoLensFoundation

final class SourceControlFixHelpersTests: XCTestCase {
    func testIssuesBadgeVoiceOverLabelUsesSingularAndPlural() {
        XCTAssertEqual(
            IssueBadgeAccessibility.label(errors: 1, warnings: 0),
            "1 error, 0 warnings. Show Issues"
        )
        XCTAssertEqual(
            IssueBadgeAccessibility.label(errors: 0, warnings: 1),
            "0 errors, 1 warning. Show Issues"
        )
        XCTAssertEqual(
            IssueBadgeAccessibility.label(errors: 1, warnings: 1),
            "1 error, 1 warning. Show Issues"
        )
        XCTAssertEqual(
            IssueBadgeAccessibility.label(errors: 2, warnings: 3),
            "2 errors, 3 warnings. Show Issues"
        )
    }

    func testUnmergedPushedBranchRequiresForceDeleteAndNeverPromisesSafeDeletion() {
        let decision = GitBranchDeleteDecision.evaluate(
            branchName: "feat-unmerged-pushed",
            targetBranchName: "main",
            upstream: "origin/feat-unmerged-pushed",
            mergedIntoHead: false,
            hasRemoteTrackingRef: true
        )

        XCTAssertEqual(decision.actionTitle, "Force Delete")
        XCTAssertFalse(decision.informativeText.contains("none are lost"))
        XCTAssertTrue(decision.informativeText.contains("aren’t merged into “main”"))
        XCTAssertTrue(decision.informativeText.contains("permanently lose"))
        XCTAssertTrue(decision.showsDeleteRemoteOption)
        XCTAssertEqual(
            decision.deleteRemoteTitle,
            "Also delete “origin/feat-unmerged-pushed” on the remote"
        )
        XCTAssertEqual(
            GitBranchDeleteDecision.branchDeleteFlag(
                mergedIntoHead: false,
                mergedIntoUpstream: true,
                deleteRemote: true
            ),
            "-D"
        )
    }

    func testPrunedUpstreamOmitsRemoteDeleteCheckbox() {
        let decision = GitBranchDeleteDecision.evaluate(
            branchName: "feat-pruned",
            targetBranchName: "main",
            upstream: "origin/feat-pruned",
            mergedIntoHead: false,
            hasRemoteTrackingRef: false
        )

        XCTAssertEqual(decision.actionTitle, "Force Delete")
        XCTAssertFalse(decision.showsDeleteRemoteOption)
        XCTAssertNil(decision.deleteRemoteTitle)
        XCTAssertFalse(decision.informativeText.contains("especially if also deleted on the remote"))
    }

    func testMergedBranchWithRemoteUsesStandardDeleteAndAllowsRemoteOption() {
        let decision = GitBranchDeleteDecision.evaluate(
            branchName: "feat-merged",
            targetBranchName: "main",
            upstream: "origin/feat-merged",
            mergedIntoHead: true,
            hasRemoteTrackingRef: true
        )

        XCTAssertEqual(decision.actionTitle, "Delete")
        XCTAssertTrue(decision.informativeText.contains("already in “main”, so none are lost"))
        XCTAssertTrue(decision.showsDeleteRemoteOption)
        XCTAssertEqual(
            GitBranchDeleteDecision.branchDeleteFlag(
                mergedIntoHead: true,
                mergedIntoUpstream: true,
                deleteRemote: false
            ),
            "-d"
        )
        XCTAssertEqual(
            GitBranchDeleteDecision.branchDeleteFlag(
                mergedIntoHead: true,
                mergedIntoUpstream: true,
                deleteRemote: true
            ),
            "-D"
        )
    }

    func testExcludesPatternParsingIgnoresCommentsAndLineIndexSkipsComments() {
        let lines = [
            "# macOS comment",
            "   # indented comment",
            "",
            "*.log\r",
            "# *.log",
            "build/",
        ]

        let parsed = GitExcludesFileHelper.patternTexts(in: lines)
        XCTAssertEqual(parsed, ["*.log", "build/"])

        XCTAssertEqual(GitExcludesFileHelper.lineIndex(of: "*.log", occurrence: 0, in: lines), 3)
        XCTAssertEqual(GitExcludesFileHelper.lineIndex(of: "build/", occurrence: 0, in: lines), 5)
        XCTAssertNil(GitExcludesFileHelper.lineIndex(of: "# macOS comment", occurrence: 0, in: lines))
    }

    func testExcludesRelativePathResolutionHandlesWorkspaceHomeAndParentDir() {
        let resolvedInWorkspace = GitExcludesFileHelper.resolvePath(
            configuredValue: "rel.ignore",
            workspacePath: "/tmp/ws",
            environment: ["HOME": "/tmp/home"],
            fallbackHomeDirectory: "/Users/fallback",
            fileExists: { $0 == "/tmp/ws/rel.ignore" }
        )
        XCTAssertEqual(resolvedInWorkspace, "/tmp/ws/rel.ignore")
        XCTAssertEqual((resolvedInWorkspace as NSString).deletingLastPathComponent, "/tmp/ws")

        let resolvedInHomeFallback = GitExcludesFileHelper.resolvePath(
            configuredValue: "rel.ignore",
            workspacePath: "/tmp/ws",
            environment: ["HOME": "/tmp/home"],
            fallbackHomeDirectory: "/Users/fallback",
            fileExists: { _ in false }
        )
        XCTAssertEqual(resolvedInHomeFallback, "/tmp/home/rel.ignore")
        XCTAssertEqual((resolvedInHomeFallback as NSString).deletingLastPathComponent, "/tmp/home")

        let expandedTilde = GitExcludesFileHelper.resolvePath(
            configuredValue: "~/.gitignore_global",
            workspacePath: "/tmp/ws",
            environment: ["HOME": "/tmp/custom_home"],
            fallbackHomeDirectory: "/Users/fallback"
        )
        XCTAssertEqual(expandedTilde, "/tmp/custom_home/.gitignore_global")
    }

    func testGitCommandFailureFormatterIncludesSubcommandExitCodeAndStderr() {
        let logFailure = GitCommandFailureFormatter.formatFailure(
            args: ["--no-optional-locks", "log", "-n", "30", "--pretty=format:%H"],
            exitCode: 128,
            stderr: "fatal: object deadbeef is empty\n",
            stdout: ""
        )
        XCTAssertEqual(
            logFailure,
            "git log failed (exit 128): fatal: object deadbeef is empty"
        )

        let combinedOutputFailure = GitCommandFailureFormatter.formatFailure(
            args: ["--no-optional-locks", "log", "-n", "30", "--pretty=format:%H"],
            exitCode: 128,
            stderr: "exit status 128",
            stdout: "fatal: object deadbeef is empty\n"
        )
        XCTAssertEqual(
            combinedOutputFailure,
            "git log failed (exit 128): fatal: object deadbeef is empty"
        )

        let stashFailure = GitCommandFailureFormatter.formatFailure(
            args: ["--no-optional-locks", "stash", "list", "-n", "50"],
            exitCode: 128,
            stderr: "exit status 128",
            stdout: "fatal: bad object refs/stash\n"
        )
        XCTAssertEqual(
            stashFailure,
            "git stash list failed (exit 128): fatal: bad object refs/stash"
        )

        let unbornLog = GitCommandFailureFormatter.formatFailure(
            args: ["--no-optional-locks", "log", "-n", "30"],
            exitCode: 128,
            stderr: "exit status 128",
            stdout: "fatal: your current branch 'main' does not have any commits yet\n"
        )
        XCTAssertNil(unbornLog)
    }

    func testWorktreePorcelainParserHandlesLinkedDetachedBareLockedAndPrunableWithoutTrailingNewline() {
        let porcelain = [
            "worktree /tmp/repo",
            "HEAD 1111111111111111111111111111111111111111",
            "branch refs/heads/main",
            "",
            "worktree /tmp/repo-feat",
            "HEAD 2222222222222222222222222222222222222222",
            "detached",
            "locked waiting for review",
            "",
            "worktree /tmp/repo-stale",
            "HEAD 3333333333333333333333333333333333333333",
            "branch refs/heads/fix/race",
            "prunable gitdir file points to non-existent location",
            "",
            "worktree /tmp/repo.git",
            "bare",
            "locked",
            "prunable",
        ].joined(separator: "\n")

        let entries = GitWorktreeParser.parsePorcelain(porcelain, canonicalize: { $0 })
        XCTAssertEqual(entries.count, 4)

        XCTAssertEqual(entries[0].path, "/tmp/repo")
        XCTAssertEqual(entries[0].folderName, "repo")
        XCTAssertEqual(entries[0].shortHash, "1111111")
        XCTAssertEqual(entries[0].branchName, "main")
        XCTAssertEqual(entries[0].displayBranch, "main")
        XCTAssertFalse(entries[0].isDetached)
        XCTAssertFalse(entries[0].isLocked)

        XCTAssertEqual(entries[1].path, "/tmp/repo-feat")
        XCTAssertNil(entries[1].branchName)
        XCTAssertTrue(entries[1].isDetached)
        XCTAssertEqual(entries[1].displayBranch, "Detached HEAD")
        XCTAssertTrue(entries[1].isLocked)
        XCTAssertEqual(entries[1].lockReason, "waiting for review")

        XCTAssertEqual(entries[2].branchName, "fix/race")
        XCTAssertEqual(entries[2].displayBranch, "fix/race")
        XCTAssertTrue(entries[2].isPrunable)
        XCTAssertEqual(entries[2].pruneReason, "gitdir file points to non-existent location")

        XCTAssertTrue(entries[3].isBare)
        XCTAssertEqual(entries[3].displayBranch, "Bare Repository")
        XCTAssertTrue(entries[3].isLocked)
        XCTAssertNil(entries[3].lockReason)
        XCTAssertTrue(entries[3].isPrunable)
        XCTAssertNil(entries[3].pruneReason)
    }

    func testWorktreeDefaultSiblingPathSanitizesSlashesAndSpaces() {
        XCTAssertEqual(
            GitWorktreeParser.defaultSiblingPath(repoPath: "/Users/dev/go/myrepo/", branchName: "feat/oauth 2"),
            "/Users/dev/go/myrepo-feat-oauth-2"
        )
        XCTAssertEqual(
            GitWorktreeParser.defaultSiblingPath(repoPath: "/Users/dev/go/myrepo", branchName: "  ///  "),
            "/Users/dev/go/myrepo-worktree"
        )
    }

    func testWorktreeCheckedOutPathExtractionAcrossGitVersions() {
        XCTAssertEqual(
            GitWorktreeParser.checkedOutWorktreePath(
                fromGitError: "fatal: 'feat/auth' is already used by worktree at '/Users/dev/myrepo-feat-auth'\n"
            ),
            "/Users/dev/myrepo-feat-auth"
        )
        XCTAssertEqual(
            GitWorktreeParser.checkedOutWorktreePath(
                fromGitError: "fatal: 'topic' is already checked out at '/Users/dev/path with spaces/repo-topic'"
            ),
            "/Users/dev/path with spaces/repo-topic"
        )
        XCTAssertEqual(
            GitWorktreeParser.checkedOutWorktreePath(
                fromGitError: "error: already used by worktree at /tmp/unquoted-wt\n"
            ),
            "/tmp/unquoted-wt"
        )
        XCTAssertNil(
            GitWorktreeParser.checkedOutWorktreePath(
                fromGitError: "error: Your local changes to the following files would be overwritten by checkout"
            )
        )
    }
}
