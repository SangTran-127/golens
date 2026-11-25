import Foundation
import Testing
import GopilotRuntime
@testable import GopilotPolicy

@Suite("Path policy")
struct PathPolicyTests {
    @Test func allowsPlainAndSymlinkedInsideRoot() throws {
        let tree = try TempTree.make()
        defer { tree.remove() }
        let policy = tree.policy()
        #expect(policy.evaluate(relativePath: "main.go").resolved?.relativePath == "main.go")
        #expect(policy.evaluate(relativePath: "./pkg//a.go").resolved?.relativePath == "pkg/a.go")
        let viaLink = policy.evaluate(relativePath: "link-in/a.go").resolved
        #expect(viaLink != nil)
        #expect(viaLink?.url.lastPathComponent == "a.go")
        #expect(viaLink?.url.path.hasSuffix("/ws/pkg/a.go") == true)
    }

    @Test func rejectsLexicalEscapes() throws {
        let tree = try TempTree.make()
        defer { tree.remove() }
        let policy = tree.policy()
        #expect(policy.evaluate(relativePath: "../outside/secret.txt").denial == .traversal)
        #expect(policy.evaluate(relativePath: "pkg/../main.go").denial == .traversal)
        #expect(policy.evaluate(relativePath: "..").denial == .traversal)
        #expect(policy.evaluate(relativePath: "/etc/passwd").denial == .absolutePath)
        #expect(policy.evaluate(relativePath: "~/.ssh/config").denial == .absolutePath)
        #expect(policy.evaluate(relativePath: "C:/Windows").denial == .absolutePath)
        #expect(policy.evaluate(relativePath: "a\u{0}b").denial == .nulCharacter)
        #expect(policy.evaluate(relativePath: String(repeating: "a/", count: 600)).denial == .tooLong)
        #expect(policy.evaluate(relativePath: "").denial == .empty)
        #expect(policy.evaluate(relativePath: "./").denial == .empty)
    }

    @Test func rejectsSymlinksThatEscapeTheRoot() throws {
        let tree = try TempTree.make()
        defer { tree.remove() }
        let policy = tree.policy()
        #expect(policy.evaluate(relativePath: "link-out/secret.txt").denial == .outsideAllowedRoots)
        #expect(policy.evaluate(relativePath: "link-file").denial == .outsideAllowedRoots)
        #expect(policy.evaluate(relativePath: "link-out", allowsRoot: false).denial == .outsideAllowedRoots)
    }

    @Test func symlinkToExcludedFileInsideRootIsStillExcluded() throws {
        let tree = try TempTree.make()
        defer { tree.remove() }
        #expect(tree.policy().evaluate(relativePath: "env-link").denial == .excluded(.environmentFile))
    }

    @Test func missingFilesAreNotFound() throws {
        let tree = try TempTree.make()
        defer { tree.remove() }
        #expect(tree.policy().evaluate(relativePath: "nope.go").denial == .notFound)
    }

    @Test func allowsCreatingNewFilesInsideRootWhileBlockingSymlinkEscapes() throws {
        let tree = try TempTree.make()
        defer { tree.remove() }
        let policy = tree.policy()
        #expect(policy.evaluate(relativePath: "README.md", mustExist: false).resolved?.relativePath == "README.md")
        #expect(policy.evaluate(relativePath: "pkg/README.md", mustExist: false).resolved?.relativePath == "pkg/README.md")
        #expect(policy.evaluate(relativePath: "backend/docs/README.md", mustExist: false).resolved?.relativePath == "backend/docs/README.md")
        #expect(policy.evaluate(relativePath: "link-out/newfile.md", mustExist: false).denial == .outsideAllowedRoots)
        #expect(policy.evaluate(relativePath: "../escape.md", mustExist: false).denial == .traversal)
        #expect(policy.evaluate(relativePath: ".env", mustExist: false).denial == .excluded(.environmentFile))
    }

    @Test func defaultExclusionsApply() throws {
        let tree = try TempTree.make()
        defer { tree.remove() }
        let policy = tree.policy()
        #expect(policy.evaluate(relativePath: ".env").denial == .excluded(.environmentFile))
        #expect(policy.evaluate(relativePath: "id_rsa").denial == .excluded(.privateKeyOrCertificate))
        #expect(policy.evaluate(relativePath: ".git/config").denial == .excluded(.gitInternals))
        #expect(policy.evaluate(relativePath: "node_modules/x.js").denial == .excluded(.buildArtifact))
        #expect(policy.evaluate(relativePath: "logo.png").denial == .excluded(.binaryFile))
        #expect(policy.evaluate(relativePath: "notes.private").denial == .excluded(.userPattern("*.private")))
    }

    @Test func lexicalExclusionCoversCredentialShapes() {
        let policy = PathPolicy(workspaceRoots: [])
        let secrets = ["deploy/server.pem", "certs/client.p12", "cert.pfx", "keys/signing.key", "id_ed25519", "home/.ssh/config", ".netrc", "sub/.npmrc", ".pypirc",
                       "aws/credentials", ".aws/config", "credentials.json", "aws-credentials.json", "service-account.json", "google-serviceaccount.json",
                       "kubeconfig-prod", "kubeconfig_staging", "staging.kubeconfig", "terraform.tfvars", "production.tfstate",
                       ".env.local", ".env", "app/.env.production", ".git/HEAD", "x/.git/objects/ab"]
        for path in secrets {
            #expect(policy.lexicalExclusion(relativePath: path) != nil, "expected \(path) to be excluded")
        }
        for path in ["main.go", "README.md", "cmd/server/main.go", "id_rsa.pub", ".gitignore", ".github/workflows/ci.yml", "docs/environment.md"] {
            #expect(policy.lexicalExclusion(relativePath: path) == nil, "expected \(path) to be allowed")
        }
    }

    @Test func userGlobPatternsMatchNamesAndPaths() {
        let policy = PathPolicy(workspaceRoots: [], userExcludePatterns: ["*.secret", "internal/**", "/rootonly.txt", "testdata/"])
        #expect(policy.lexicalExclusion(relativePath: "a/b/x.secret") == .userPattern("*.secret"))
        #expect(policy.lexicalExclusion(relativePath: "internal/deep/file.go") == .userPattern("internal/**"))
        #expect(policy.lexicalExclusion(relativePath: "rootonly.txt") == .userPattern("/rootonly.txt"))
        #expect(policy.lexicalExclusion(relativePath: "sub/rootonly.txt") == nil)
        #expect(policy.lexicalExclusion(relativePath: "pkg/testdata/in.json") == .userPattern("testdata/"))
        #expect(policy.lexicalExclusion(relativePath: "pkg/ok.go") == nil)
    }

    @Test func dependencyRootsNeedApproval() throws {
        let tree = try TempTree.make()
        defer { tree.remove() }
        let denied = tree.policy().evaluate(relativePath: "example.com/x@v1/x.go", dependencyRootID: "modcache")
        #expect(denied.denial == .dependencyRootNotApproved("modcache"))

        let approved = tree.policy(approvedDependencies: [DependencyRoot(id: "modcache", path: tree.dependency.path)])
        let allowed = approved.evaluate(relativePath: "example.com/x@v1/x.go", dependencyRootID: "modcache").resolved
        #expect(allowed?.dependencyRootID == "modcache")
        #expect(approved.evaluate(relativePath: "../ws/main.go", dependencyRootID: "modcache").denial == .traversal)
        #expect(approved.evaluate(relativePath: "example.com/escape/main.go", dependencyRootID: "modcache").denial == .outsideAllowedRoots)
        #expect(approved.evaluate(relativePath: "example.com/x@v1/x.go").denial == .notFound)
        #expect(tree.policy().approvingDependencyRoot(DependencyRoot(id: "modcache", path: tree.dependency.path)).isApproved(dependencyRootID: "modcache"))
    }

    @Test func attachOverrideNeedsPreviewAndNeverCoversKeyStores() throws {
        let tree = try TempTree.make()
        defer { tree.remove() }
        let policy = tree.policy()
        if case .failure(let reason) = policy.attachOverride(relativePath: ".env", previewConfirmed: false) {
            #expect(reason == .previewRequired)
        } else {
            Issue.record("attaching without a confirmed preview must fail")
        }

        guard case .success(let attached) = policy.attachOverride(relativePath: ".env", previewConfirmed: true) else {
            Issue.record("attaching .env after preview should succeed")
            return
        }
        #expect(attached.evaluate(relativePath: ".env").resolved != nil)
        #expect(attached.evaluate(relativePath: "env-link").resolved != nil)
        #expect(policy.evaluate(relativePath: ".env").denial == .excluded(.environmentFile))

        guard case .success(let withUser) = policy.attachOverride(relativePath: "notes.private", previewConfirmed: true) else {
            Issue.record("attaching a user-ignored file after preview should succeed")
            return
        }
        #expect(withUser.evaluate(relativePath: "notes.private").resolved != nil)
        #expect(withUser.evaluate(relativePath: ".env").denial == .excluded(.environmentFile))

        for hard in ["id_rsa", ".git/config", "logo.png"] {
            if case .success = policy.attachOverride(relativePath: hard, previewConfirmed: true) {
                Issue.record("\(hard) must never be attachable")
            }
        }
        if case .success = policy.attachOverride(relativePath: "link-file", previewConfirmed: true) {
            Issue.record("a symlink escaping the root must never be attachable")
        }
    }

    @Test func binarySniffUsesContent() {
        #expect(PathPolicy.looksBinary(Data([0x41, 0x00, 0x42])))
        #expect(PathPolicy.looksBinary(Data([0xFF, 0xFE, 0xFD, 0xFC, 0x80, 0x81])))
        #expect(PathPolicy.looksBinary(Data("Ti\u{1EBF}ng Vi\u{1EC7}t \u{1F600}".utf8)) == false)
        var padded = Data(repeating: 0x61, count: 8191)
        padded.append(contentsOf: Array("\u{1EC7}".utf8))
        #expect(PathPolicy.looksBinary(padded) == false)
    }

    @Test func terraformKubeconfigAndServiceAccountFilesAreBlockedAsCredentials() throws {
        let tree = try TempTree.make()
        defer { tree.remove() }
        let policy = tree.policy()
        for blocked in [
            "prod.tfvars",
            "infra/terraform.tfstate",
            "infra/terraform.tfstate.backup",
            "kubeconfig",
            "clusters/prod.kubeconfig",
            "gcp-service-account-prod.json"
        ] {
            #expect(policy.lexicalExclusion(relativePath: blocked) == .credentialFile, "\(blocked)")
            #expect(policy.isExcluded(relativePath: blocked), "\(blocked)")
        }
    }
}

@Suite("Denied before I/O")
struct DeniedBeforeIOTests {
    private func makeReadSource(tree: TempTree, reader: CountingReader, approved: [DependencyRoot] = []) throws -> (tool: GopilotTool, store: EvidenceStore, workspace: UUID) {
        let workspace = UUID()
        let store = EvidenceStore()
        let snapshot = makeSnapshot(workspace: workspace)
        let context = ReadToolContext(
            workspaceID: workspace,
            snapshot: { snapshot },
            pathPolicy: tree.policy(approvedDependencies: approved),
            evidence: store,
            backends: ReadBackends(source: DiskSourceProvider(reader: reader))
        )
        let tools = try ToolSet.makeTools(context: context, wave: .w2)
        return (tools[0], store, workspace)
    }

    private func read(_ tool: GopilotTool, path: String, root: String? = nil) async throws -> ToolResultEnvelope {
        let escaped = path.replacingOccurrences(of: "\u{0}", with: "\\u0000")
        let rootField = root.map { #","dependencyRootID":"\#($0)""# } ?? ""
        return try await tool.execute(callID: "c1", argumentsJSON: #"{"relativePath":"\#(escaped)","startLine":1,"endLine":5\#(rootField)}"#)
    }

    @Test func traversalAbsoluteSymlinkAndUngrantedDependencyNeverReachTheReader() async throws {
        let tree = try TempTree.make()
        defer { tree.remove() }
        let reader = CountingReader()
        let (tool, store, workspace) = try makeReadSource(tree: tree, reader: reader)

        let attempts: [(String, String?)] = [
            ("../outside/secret.txt", nil), ("pkg/../main.go", nil), ("/etc/passwd", nil), ("~/.ssh/id_rsa", nil),
            ("link-out/secret.txt", nil), ("link-file", nil), (".env", nil), ("id_rsa", nil), (".git/config", nil), ("env-link", nil),
            ("example.com/x@v1/x.go", "modcache"), ("a\u{0}b", nil)
        ]
        for (path, root) in attempts {
            let result = try await read(tool, path: path, root: root)
            #expect(result.status == .error, "\(path) should fail")
            #expect(result.errorCode == .denied, "\(path) should be denied, got \(String(describing: result.errorCode))")
            #expect(result.evidenceIDs.isEmpty)
        }
        #expect(reader.reads == 0)
        #expect(await store.count(workspaceID: workspace) == 0)
    }

    @Test func allowedPathReadsExactlyOnceAndBinaryContentIsRefused() async throws {
        let tree = try TempTree.make()
        defer { tree.remove() }
        let reader = CountingReader()
        let (tool, _, _) = try makeReadSource(tree: tree, reader: reader)

        let ok = try await read(tool, path: "main.go")
        #expect(ok.status == .ok)
        #expect(reader.reads == 1)
        #expect(decodeData(ok)["text"] as? String == "package main\nfunc main() {}")

        let binary = try await read(tool, path: "data.txt")
        #expect(binary.status == .error)
        #expect(decodeData(binary)["outcome"] as? String == "unavailable")
        #expect(reader.reads == 2)
    }

    @Test func approvedDependencyRootIsReadable() async throws {
        let tree = try TempTree.make()
        defer { tree.remove() }
        let reader = CountingReader()
        let (tool, _, _) = try makeReadSource(tree: tree, reader: reader, approved: [DependencyRoot(id: "modcache", path: tree.dependency.path)])
        let result = try await read(tool, path: "example.com/x@v1/x.go", root: "modcache")
        #expect(result.status == .ok)
        #expect(reader.reads == 1)
    }
}
