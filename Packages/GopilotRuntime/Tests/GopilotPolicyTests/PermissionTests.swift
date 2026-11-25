import Foundation
import Testing
@testable import GopilotPolicy
@testable import GopilotRuntime

private let now = Date(timeIntervalSince1970: 2_000_000)

private func grant(workspace: UUID, operation: PolicyOperation = .runTests, selector: String = "./pkg/orders", target: String = "T1", env: Set<String> = ["GOMAXPROCS"], timeout: Int = 120, maxRuns: Int = 2, expires: Date = now.addingTimeInterval(3600)) -> ExecutionGrant {
    ExecutionGrant(workspaceID: workspace, operation: operation, selector: selector, targetConfigHash: target, envNames: env, timeoutSeconds: timeout, maxRuns: maxRuns, expiresAt: expires, ownerActionID: "ui-action-1")
}

private func request(workspace: UUID, operation: PolicyOperation = .runTests, selector: String = "./pkg/orders", target: String = "T1", env: Set<String> = ["GOMAXPROCS"], timeout: Int = 60, runs: Int = 1) -> PermissionRequest {
    PermissionRequest(workspaceID: workspace, operation: operation, selector: selector, targetConfigHash: target, envNames: env, timeoutSeconds: timeout, runCount: runs)
}

private func mismatches(_ decision: PermissionDecision) -> [GrantMismatch] {
    if case .needsApproval(let card) = decision { return card.mismatches }
    return []
}

@Suite("Permission policy")
struct PermissionPolicyTests {
    private let workspace = UUID()
    private var policy: PermissionPolicy { PermissionPolicy(trustedWorkspaces: [workspace]) }

    @Test func readNeverNeedsAGrantAndWritesAreNeverModelOperations() {
        #expect(policy.decide(PermissionRequest(workspaceID: workspace, operation: .read), grants: [], now: now) == .allow(grantID: nil))
        for operation in [PolicyOperation.writeFile, .applyPatch, .shell] {
            let decision = policy.decide(PermissionRequest(workspaceID: workspace, operation: operation), grants: [grant(workspace: workspace)], now: now)
            #expect(decision == .deny(.notAModelOperation))
        }
    }

    @Test func executionWithoutAGrantAsksWithAConcreteCard() {
        let decision = policy.decide(request(workspace: workspace), grants: [], now: now)
        guard case .needsApproval(let card) = decision else {
            Issue.record("expected needsApproval, got \(decision)")
            return
        }
        #expect(card.mismatches == [.noGrant])
        #expect(card.selector == "./pkg/orders")
        #expect(card.executesRepositoryCode)
        #expect(card.explanation.contains("executes code from this repository"))
    }

    @Test func exactGrantAllows() {
        let granted = grant(workspace: workspace)
        #expect(policy.decide(request(workspace: workspace), grants: [granted], now: now) == .allow(grantID: granted.id))
        #expect(policy.decide(request(workspace: workspace, env: []), grants: [granted], now: now) == .allow(grantID: granted.id))
    }

    @Test func everyGrantFieldMismatchNeedsApproval() {
        let g = grant(workspace: workspace)
        func check(_ r: PermissionRequest, _ expected: (GrantMismatch) -> Bool, _ label: String, grants: [ExecutionGrant]? = nil) {
            let found = mismatches(policy.decide(r, grants: grants ?? [g], now: now))
            let matched = found.contains(where: expected)
            #expect(matched, "\(label): got \(found)")
        }
        check(request(workspace: workspace, selector: "./pkg/payments"), { if case .selector = $0 { return true } else { return false } }, "selector")
        check(request(workspace: workspace, target: "T2"), { $0 == .targetConfig }, "target")
        check(request(workspace: workspace, env: ["GOMAXPROCS", "GODEBUG"]), { $0 == .environment(extraNames: ["GODEBUG"]) }, "env")
        check(request(workspace: workspace, timeout: 121), { $0 == .timeout(granted: 120, requested: 121) }, "timeout")
        check(request(workspace: workspace, runs: 3), { $0 == .runCount(remaining: 2, requested: 3) }, "count")
        check(request(workspace: workspace, operation: .runBenchmark), { $0 == .operation }, "operation")

        let gWithHash = ExecutionGrant(workspaceID: workspace, operation: .runTests, selector: "./pkg/orders", targetConfigHash: "T1", workspaceSnapshotHash: "hash-A", envNames: ["GOMAXPROCS"], timeoutSeconds: 120, maxRuns: 2, expiresAt: now.addingTimeInterval(3600), ownerActionID: "ui-action-1")
        let rWithHash = PermissionRequest(workspaceID: workspace, operation: .runTests, selector: "./pkg/orders", targetConfigHash: "T1", workspaceSnapshotHash: "hash-B", envNames: ["GOMAXPROCS"], timeoutSeconds: 60, runCount: 1)
        check(rWithHash, { if case .workspaceSnapshot(let granted, let current) = $0 { return granted == "hash-A" && current == "hash-B" } else { return false } }, "workspaceSnapshot", grants: [gWithHash])

        let expired = grant(workspace: workspace, expires: now.addingTimeInterval(-1))
        check(request(workspace: workspace), { $0 == .expired }, "expiry", grants: [expired])
        let atBoundary = grant(workspace: workspace, expires: now)
        check(request(workspace: workspace), { $0 == .expired }, "expiry boundary", grants: [atBoundary])

        let other = UUID()
        let policyBoth = PermissionPolicy(trustedWorkspaces: [workspace, other])
        let foreign = mismatches(policyBoth.decide(request(workspace: other), grants: [g], now: now))
        #expect(foreign.contains(.workspace))
    }

    @Test func selectorsAreExactNeverWildcards() {
        let wildcard = grant(workspace: workspace, selector: "./...")
        #expect(mismatches(policy.decide(request(workspace: workspace, selector: "./pkg/orders"), grants: [wildcard], now: now)).isEmpty == false)
        let prefix = grant(workspace: workspace, selector: "./pkg")
        #expect(mismatches(policy.decide(request(workspace: workspace, selector: "./pkg/orders"), grants: [prefix], now: now)).isEmpty == false)
        let single = grant(workspace: workspace, selector: "./pkg/orders#TestCreate")
        #expect(mismatches(policy.decide(request(workspace: workspace, selector: "./pkg/orders#TestCreate2"), grants: [single], now: now)).isEmpty == false)
        #expect(mismatches(policy.decide(request(workspace: workspace, selector: "./pkg/orders#*"), grants: [single], now: now)).isEmpty == false)
        let exact = policy.decide(request(workspace: workspace, selector: "./pkg/orders#TestCreate"), grants: [single], now: now)
        #expect(exact == .allow(grantID: single.id))
    }

    @Test func canonicalSelectorSortsAndDeduplicatesTests() {
        #expect(PermissionPolicy.canonicalSelector(package: "./pkg/orders", tests: ["TestB", "TestA", "TestB"]) == "./pkg/orders#TestA,TestB")
        #expect(PermissionPolicy.canonicalSelector(package: "./pkg/orders") == "./pkg/orders")
    }

    @Test func denyBeatsAllowAndAsk() {
        let granted = grant(workspace: workspace)
        let denying = PermissionPolicy(denyRules: [PolicyDenyRule(operation: .runTests, selector: "./pkg/orders")], trustedWorkspaces: [workspace])
        #expect(denying.decide(request(workspace: workspace), grants: [granted], now: now) == .deny(.denyRule))
        #expect(denying.decide(request(workspace: workspace), grants: [], now: now) == .deny(.denyRule))
        #expect(denying.decide(request(workspace: workspace, selector: "./pkg/other"), grants: [], now: now) != .deny(.denyRule))

        let readDeny = PermissionPolicy(denyRules: [PolicyDenyRule(operation: .read)])
        #expect(readDeny.decide(PermissionRequest(workspaceID: workspace, operation: .read), grants: [], now: now) == .deny(.denyRule))
    }

    @Test func untrustedWorkspacesCannotExecuteEvenWithAGrant() {
        let granted = grant(workspace: workspace)
        let untrusted = PermissionPolicy()
        #expect(untrusted.decide(request(workspace: workspace), grants: [granted], now: now) == .deny(.workspaceNotTrusted))
    }

    @Test func invalidRequestsAreDenied() {
        let granted = grant(workspace: workspace)
        #expect(policy.decide(request(workspace: workspace, selector: ""), grants: [granted], now: now) == .deny(.invalidRequest("selector is empty")))
        #expect(policy.decide(request(workspace: workspace, timeout: 601), grants: [granted], now: now) == .deny(.timeoutAboveLimit(600)))
        #expect(policy.decide(request(workspace: workspace, runs: 0), grants: [granted], now: now) == .deny(.invalidRequest("run count must be at least 1")))
        #expect(policy.decide(request(workspace: workspace, env: ["OPENAI_API_KEY"]), grants: [granted], now: now) == .deny(.secretEnvironmentName("OPENAI_API_KEY")))
    }

    @Test func approvalCardPrefersTheClosestGrantInTheSameWorkspace() {
        let other = UUID()
        let foreign = grant(workspace: other)
        let near = grant(workspace: workspace, selector: "./pkg/payments")
        let policyBoth = PermissionPolicy(trustedWorkspaces: [workspace, other])
        let found = mismatches(policyBoth.decide(request(workspace: workspace), grants: [foreign, near], now: now))
        #expect(found.count == 1)
        if case .selector(let granted, let requested)? = found.first {
            #expect(granted == "./pkg/payments")
            #expect(requested == "./pkg/orders")
        } else {
            Issue.record("expected a selector mismatch")
        }
    }
}

@Suite("Grant store")
struct GrantStoreTests {
    private let workspace = UUID()

    @Test func maxRunsIsDecrementedAtomicallyUnderConcurrency() async throws {
        let store = GrantStore(policy: PermissionPolicy(trustedWorkspaces: [workspace]))
        try await store.add(grant(workspace: workspace, maxRuns: 3, expires: Date().addingTimeInterval(3600)))
        let results = await withTaskGroup(of: PermissionDecision.self) { group in
            for _ in 0..<12 {
                group.addTask { await store.authorize(request(workspace: workspace)) }
            }
            var collected: [PermissionDecision] = []
            for await decision in group { collected.append(decision) }
            return collected
        }
        let allowed = results.filter { if case .allow = $0 { return true } else { return false } }
        let asked = results.filter { if case .needsApproval = $0 { return true } else { return false } }
        #expect(allowed.count == 3)
        #expect(asked.count == 9)
        #expect(await store.activeGrants(workspaceID: workspace).first?.runsRemaining == 0)
    }

    @Test func multiRunRequestsConsumeTheirFullCount() async throws {
        let store = GrantStore(policy: PermissionPolicy(trustedWorkspaces: [workspace]))
        try await store.add(grant(workspace: workspace, maxRuns: 5, expires: Date().addingTimeInterval(3600)))
        #expect(await store.authorize(request(workspace: workspace, runs: 4)) != .deny(.denyRule))
        let remaining = await store.activeGrants(workspaceID: workspace).first?.runsRemaining
        #expect(remaining == 1)
        let next = await store.authorize(request(workspace: workspace, runs: 2))
        #expect(mismatches(next).contains(.runCount(remaining: 1, requested: 2)))
        #expect(await store.activeGrants(workspaceID: workspace).first?.runsRemaining == 1)
    }

    @Test func workspaceChangeRevokesOtherWorkspacesGrantsWholesale() async throws {
        let other = UUID()
        let store = GrantStore(policy: PermissionPolicy(trustedWorkspaces: [workspace, other]))
        try await store.add(grant(workspace: workspace, expires: Date().addingTimeInterval(3600)))
        try await store.add(grant(workspace: workspace, selector: "./pkg/payments", expires: Date().addingTimeInterval(3600)))
        try await store.add(grant(workspace: other, expires: Date().addingTimeInterval(3600)))

        await store.workspaceChanged(activeWorkspaceID: other)
        #expect(await store.activeGrants(workspaceID: workspace).isEmpty)
        #expect(await store.activeGrants(workspaceID: other).count == 1)
        let afterSwitch = await store.authorize(request(workspace: workspace))
        #expect(mismatches(afterSwitch) == [.workspace])
        #expect(await store.authorize(request(workspace: other)) != .deny(.denyRule))

        await store.workspaceChanged(activeWorkspaceID: nil)
        #expect(await store.activeGrants(workspaceID: other).isEmpty)
    }

    @Test func closingAWorkspaceRevokesItsGrantsOnly() async throws {
        let other = UUID()
        let store = GrantStore(policy: PermissionPolicy(trustedWorkspaces: [workspace, other]))
        try await store.add(grant(workspace: workspace, expires: Date().addingTimeInterval(3600)))
        try await store.add(grant(workspace: other, expires: Date().addingTimeInterval(3600)))
        await store.revokeAll(workspaceID: workspace)
        #expect(await store.activeGrants(workspaceID: workspace).isEmpty)
        #expect(await store.activeGrants(workspaceID: other).count == 1)
    }

    @Test func grantFromAIsNotUsableUnderB() async throws {
        let b = UUID()
        let store = GrantStore(policy: PermissionPolicy(trustedWorkspaces: [workspace, b]))
        try await store.add(grant(workspace: workspace, expires: Date().addingTimeInterval(3600)))
        let decision = await store.authorize(request(workspace: b))
        guard case .needsApproval(let card) = decision else {
            Issue.record("a grant from another workspace must not allow, got \(decision)")
            return
        }
        #expect(card.workspaceID == b)
        #expect(card.mismatches.contains(.workspace))
        #expect(await store.activeGrants(workspaceID: workspace).first?.runsUsed == 0)
    }

    @Test func invalidGrantsAreRejected() async {
        let store = GrantStore()
        await #expect(throws: GrantError.self) { try await store.add(grant(workspace: workspace, operation: .read)) }
        await #expect(throws: GrantError.self) { try await store.add(grant(workspace: workspace, selector: "")) }
        await #expect(throws: GrantError.self) { try await store.add(grant(workspace: workspace, maxRuns: 0)) }
        await #expect(throws: GrantError.self) { try await store.add(grant(workspace: workspace, timeout: 601)) }
    }

    @Test func trustCanBeToggledAtRuntime() async throws {
        let store = GrantStore()
        try await store.add(grant(workspace: workspace, expires: Date().addingTimeInterval(3600)))
        #expect(await store.authorize(request(workspace: workspace)) == .deny(.workspaceNotTrusted))
        await store.setTrusted(true, workspaceID: workspace)
        if case .allow = await store.authorize(request(workspace: workspace)) {} else { Issue.record("trusted workspace with a matching grant should be allowed") }
        await store.setTrusted(false, workspaceID: workspace)
        #expect(await store.authorize(request(workspace: workspace)) == .deny(.workspaceNotTrusted))
    }
}

@Suite("Outbound host consent")
struct OutboundHostConsentTests {
    @Test func normalizesHostsAndPortsIncludingIPv6() {
        #expect(OutboundHostConsent.normalizedHost(forBaseURL: "https://API.EXAMPLE.COM/v1") == "api.example.com")
        #expect(OutboundHostConsent.normalizedHost(forBaseURL: "https://api.example.com:8443/v1") == "api.example.com:8443")
        #expect(OutboundHostConsent.normalizedHost(forBaseURL: "http://[::1]:11434/v1") == "[::1]:11434")
        #expect(OutboundHostConsent.normalizedHost(forBaseURL: "http://localhost./v1") == "localhost")
    }

    @Test func identifiesLoopbackVariantsWhileRejectingRemoteHosts() {
        #expect(OutboundHostConsent.isLoopback(host: "localhost"))
        #expect(OutboundHostConsent.isLoopback(host: "localhost:11434"))
        #expect(OutboundHostConsent.isLoopback(host: "localhost."))
        #expect(OutboundHostConsent.isLoopback(host: "127.0.0.1:8080"))
        #expect(OutboundHostConsent.isLoopback(host: "::1"))
        #expect(OutboundHostConsent.isLoopback(host: "[::1]:11434"))
        #expect(!OutboundHostConsent.isLoopback(host: "api.example.com"))
        #expect(!OutboundHostConsent.isLoopback(host: "api.localhost.evil.com"))
        #expect(!OutboundHostConsent.isLoopback(host: "192.168.1.10"))
    }
}
