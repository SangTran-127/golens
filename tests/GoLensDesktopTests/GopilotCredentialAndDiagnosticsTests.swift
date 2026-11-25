import XCTest
@testable import GoLensFoundation

private enum TestMockCredentialError: Error, CustomStringConvertible {
    case writeDenied
    case readBackDenied

    var description: String {
        switch self {
        case .writeDenied: "write denied"
        case .readBackDenied: "readback denied"
        }
    }
}

final class GopilotCredentialAndDiagnosticsTests: XCTestCase {
    private var tempDirectories: [URL] = []

    override func tearDown() {
        for dir in tempDirectories {
            _ = try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
            _ = try? FileManager.default.removeItem(at: dir)
        }
        tempDirectories.removeAll()
        super.tearDown()
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("golens-cred-policy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDirectories.append(dir)
        return dir
    }

    func testResolveModeDefaultsToKeychainWithoutSilentPlaintextFallback() {
        XCTAssertEqual(GopilotCredentialStorePolicy.resolveMode(environment: [:]), .keychain)
        XCTAssertEqual(GopilotCredentialStorePolicy.resolveMode(environment: ["GOPILOT_CREDENTIAL_STORE": ""]), .keychain)
        XCTAssertEqual(GopilotCredentialStorePolicy.resolveMode(environment: ["GOPILOT_CREDENTIAL_STORE": "keychain"]), .keychain)
        XCTAssertEqual(GopilotCredentialStorePolicy.resolveMode(environment: ["GOPILOT_CREDENTIAL_STORE": "invalid"]), .keychain)
    }

    func testResolveModeRespectsExplicitSmokeAndDevOverrides() {
        XCTAssertEqual(
            GopilotCredentialStorePolicy.resolveMode(environment: ["GOPILOT_CREDENTIAL_STORE": "file"]),
            .localFile
        )
        XCTAssertEqual(
            GopilotCredentialStorePolicy.resolveMode(environment: ["GOPILOT_DEV_SEED_CONNECTED": "1"]),
            .memory
        )
        XCTAssertEqual(
            GopilotCredentialStorePolicy.resolveMode(environment: [
                "GOPILOT_DEV_SEED_CONNECTED": "1",
                "GOPILOT_CREDENTIAL_STORE": "file"
            ]),
            .memory
        )
    }

    func testMigrateLegacyFileMovesSecretAndDeletesEmptyFile() throws {
        let dir = try makeTempDir()
        let fileURL = dir.appendingPathComponent("gopilot-credentials.json")
        let key = GopilotCredentialStorePolicy.storageKey(profileID: "default")
        let data = try JSONEncoder().encode([key: "sk-legacy-secret"])
        try data.write(to: fileURL)

        var keychainSecret: String?
        let outcome = GopilotCredentialStorePolicy.migrateLegacyFileIfPresent(
            fileURL: fileURL,
            storageKey: key,
            writeToTarget: { keychainSecret = $0 },
            readBackFromTarget: { keychainSecret ?? "" }
        )

        XCTAssertEqual(outcome, .migrated)
        XCTAssertEqual(keychainSecret, "sk-legacy-secret")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertNil(GopilotCredentialStorePolicy.migrationFailureMessage(for: outcome))
    }

    func testMigrateLegacyFileKeepsUnrelatedKeysAndPreservesLegacyOnWriteFailure() throws {
        let dir = try makeTempDir()
        let fileURL = dir.appendingPathComponent("gopilot-credentials.json")
        let key = GopilotCredentialStorePolicy.storageKey(profileID: "default")
        let payload = [key: "sk-move-me", "other:api-key": "sk-stay"]
        try JSONEncoder().encode(payload).write(to: fileURL)

        let failedOutcome = GopilotCredentialStorePolicy.migrateLegacyFileIfPresent(
            fileURL: fileURL,
            storageKey: key,
            writeToTarget: { _ in throw TestMockCredentialError.writeDenied },
            readBackFromTarget: { "" }
        )

        guard case .failed(let reason, let copied, let hadSecret) = failedOutcome else {
            return XCTFail("Expected migration failure when target write throws")
        }
        XCTAssertFalse(copied)
        XCTAssertTrue(hadSecret)
        XCTAssertTrue(reason.contains("write denied"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        let failureMessage = GopilotCredentialStorePolicy.migrationFailureMessage(for: failedOutcome)
        XCTAssertNotNil(failureMessage)
        XCTAssertTrue(failureMessage?.contains("couldn’t be moved to the Keychain") == true)

        var stored: String?
        let migratedOutcome = GopilotCredentialStorePolicy.migrateLegacyFileIfPresent(
            fileURL: fileURL,
            storageKey: key,
            writeToTarget: { stored = $0 },
            readBackFromTarget: { stored ?? "" }
        )
        XCTAssertEqual(migratedOutcome, .migrated)
        XCTAssertEqual(stored, "sk-move-me")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        let remaining = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: fileURL))
        XCTAssertEqual(remaining, ["other:api-key": "sk-stay"])
    }

    func testMigrateLegacyFileReportsDeletionFailureAfterSuccessfulTargetCopy() throws {
        let dir = try makeTempDir()
        let fileURL = dir.appendingPathComponent("gopilot-credentials.json")
        let key = GopilotCredentialStorePolicy.storageKey(profileID: "default")
        try JSONEncoder().encode([key: "sk-locked-dir"]).write(to: fileURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)

        var stored: String?
        let outcome = GopilotCredentialStorePolicy.migrateLegacyFileIfPresent(
            fileURL: fileURL,
            storageKey: key,
            writeToTarget: { stored = $0 },
            readBackFromTarget: { stored ?? "" }
        )

        XCTAssertEqual(stored, "sk-locked-dir")
        guard case .failed(_, let copiedToTarget, let hadSecret) = outcome else {
            return XCTFail("Expected cleanup failure when parent directory is read-only")
        }
        XCTAssertTrue(copiedToTarget)
        XCTAssertTrue(hadSecret)
        let message = GopilotCredentialStorePolicy.migrationFailureMessage(for: outcome)
        XCTAssertTrue(message?.contains("saved in the Keychain, but the legacy file") == true)

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        let cleanupMessage = GopilotCredentialStorePolicy.cleanupLegacyCredentialFile(fileURL: fileURL, storageKey: key)
        XCTAssertNil(cleanupMessage)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testMigrateLegacyFileRejectsReadBackMismatchWithoutDeletingSource() throws {
        let dir = try makeTempDir()
        let fileURL = dir.appendingPathComponent("gopilot-credentials.json")
        let key = GopilotCredentialStorePolicy.storageKey(profileID: "default")
        try JSONEncoder().encode([key: "sk-expected"]).write(to: fileURL)

        let outcome = GopilotCredentialStorePolicy.migrateLegacyFileIfPresent(
            fileURL: fileURL,
            storageKey: key,
            writeToTarget: { _ in },
            readBackFromTarget: { "sk-corrupted" }
        )

        guard case .failed(_, let copied, let hadSecret) = outcome else {
            return XCTFail("Expected readback mismatch failure")
        }
        XCTAssertFalse(copied)
        XCTAssertTrue(hadSecret)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testDiagnosticsRulesExcludeModerateComplexityAndIsolateTodos() {
        XCTAssertFalse(DiagnosticsCenterRules.shouldIncludeComplexityInIssues(rating: "moderate"))
        XCTAssertFalse(DiagnosticsCenterRules.shouldIncludeComplexityInIssues(rating: "good"))
        XCTAssertTrue(DiagnosticsCenterRules.shouldIncludeComplexityInIssues(rating: "high"))

        XCTAssertFalse(DiagnosticsCenterRules.matchesScope(category: .todo, severity: 2, scope: .all))
        XCTAssertFalse(DiagnosticsCenterRules.matchesScope(category: .todo, severity: 3, scope: .all))
        XCTAssertFalse(DiagnosticsCenterRules.matchesScope(category: .todo, severity: 2, scope: .warnings))
        XCTAssertFalse(DiagnosticsCenterRules.matchesScope(category: .todo, severity: 1, scope: .errors))
        XCTAssertTrue(DiagnosticsCenterRules.matchesScope(category: .todo, severity: 3, scope: .todos))

        XCTAssertFalse(DiagnosticsCenterRules.matchesScope(category: .complexity(rating: "moderate"), severity: 3, scope: .all))
        XCTAssertTrue(DiagnosticsCenterRules.matchesScope(category: .complexity(rating: "high"), severity: 2, scope: .all))
        XCTAssertTrue(DiagnosticsCenterRules.matchesScope(category: .complexity(rating: "high"), severity: 2, scope: .warnings))
        XCTAssertFalse(DiagnosticsCenterRules.matchesScope(category: .complexity(rating: "high"), severity: 2, scope: .errors))

        XCTAssertTrue(DiagnosticsCenterRules.matchesScope(category: .issue, severity: 1, scope: .errors))
        XCTAssertTrue(DiagnosticsCenterRules.matchesScope(category: .safety, severity: 2, scope: .safety))
        XCTAssertTrue(DiagnosticsCenterRules.matchesScope(category: .bookmark, severity: 4, scope: .bookmarks))
        XCTAssertFalse(DiagnosticsCenterRules.matchesScope(category: .bookmark, severity: 4, scope: .all))
    }

    func testDiagnosticsSaveCooldownThrottlesFullWorkspaceScans() {
        XCTAssertTrue(
            DiagnosticsCenterRules.shouldThrottleWorkspaceRefresh(
                activeWorkspace: "/tmp/ws",
                lastWorkspace: "/tmp/ws",
                now: 110,
                lastTimestamp: 100,
                cooldown: DiagnosticsCenterRules.saveWorkspaceCooldown
            )
        )
        XCTAssertFalse(
            DiagnosticsCenterRules.shouldThrottleWorkspaceRefresh(
                activeWorkspace: "/tmp/ws",
                lastWorkspace: "/tmp/ws",
                now: 116,
                lastTimestamp: 100,
                cooldown: DiagnosticsCenterRules.saveWorkspaceCooldown
            )
        )
        XCTAssertFalse(
            DiagnosticsCenterRules.shouldThrottleWorkspaceRefresh(
                activeWorkspace: "/tmp/ws-two",
                lastWorkspace: "/tmp/ws",
                now: 101,
                lastTimestamp: 100,
                cooldown: DiagnosticsCenterRules.saveWorkspaceCooldown
            )
        )
    }
}
