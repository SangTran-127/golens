import Foundation
import Testing
@testable import GopilotPolicy

private let canaryKey = "sk-proj-CANARY0123456789abcdefABCDEF"

@Suite("Secret filter")
struct SecretFilterTests {
    @Test func redactsCommonSecretShapesAndCountsThem() {
        let text = """
        key = \(canaryKey)
        aws AKIAIOSFODNN7EXAMPLE
        Authorization: Bearer abcdefghijklmnopqrstuvwxyz0123456789
        password = "hunter2hunter2"
        client_secret: abcdefgh1234
        GITHUB_TOKEN=ghp_abcdefghijklmnopqrstuvwxyz0123456789
        db at postgres://admin:s3cretpass@db.internal:5432/app
        -----BEGIN RSA PRIVATE KEY-----
        MIIEowIBAAKCAQEA
        -----END RSA PRIVATE KEY-----
        """
        let result = SecretFilter().redact(text)
        for leaked in [canaryKey, "AKIAIOSFODNN7EXAMPLE", "abcdefghijklmnopqrstuvwxyz0123456789", "hunter2hunter2", "abcdefgh1234", "s3cretpass", "MIIEowIBAAKCAQEA"] {
            #expect(result.text.contains(leaked) == false, "leaked \(leaked)")
        }
        #expect(result.counts["pem"] == 1)
        #expect(result.counts["api-key"] == 1)
        #expect(result.counts["aws-key-id"] == 1)
        #expect(result.counts["bearer"] == 1)
        #expect(result.counts["url-credentials"] == 1)
        #expect((result.counts["assignment"] ?? 0) >= 2)
        #expect(result.didRedact)
        #expect(result.text.contains("db.internal:5432/app"))
    }

    @Test func unterminatedPEMBlockIsRedactedToTheEnd() {
        let result = SecretFilter().redact("before\n-----BEGIN PRIVATE KEY-----\nAAAABBBB\nCCCCDDDD")
        #expect(result.text.contains("AAAABBBB") == false)
        #expect(result.text.hasPrefix("before"))
    }

    @Test func ordinaryCodeIsLeftAlone() {
        let code = """
        func (l *Lexer) Next() Token {
            token := l.scan()
            tokens = append(tokens, token)
            secret = os.Getenv("X")
            password = hashPassword(raw)
            if password == "" { return errEmpty }
            return token
        }
        """
        let result = SecretFilter().redact(code)
        #expect(result.text == code)
        #expect(result.didRedact == false)
    }

    @Test func jsonStyleAssignmentsAreRedacted() {
        let result = SecretFilter().redact(#"{"api_key": "abcd1234efgh", "name": "demo"}"#)
        #expect(result.text.contains("abcd1234efgh") == false)
        #expect(result.text.contains(#""name": "demo""#))
    }

    @Test func literalSecretsAreRedactedEvenWithoutAKnownShape() {
        let filter = SecretFilter(literalSecrets: ["plainly-secret-value-42"])
        let result = filter.redact("the value is plainly-secret-value-42 and again plainly-secret-value-42")
        #expect(result.text.contains("plainly-secret-value-42") == false)
        #expect(result.counts["known-secret"] == 2)
    }

    @Test func redactionIsIdempotent() {
        let filter = SecretFilter()
        let once = filter.redact("api_key=\(canaryKey)")
        let twice = filter.redact(once.text)
        #expect(twice.text == once.text)
        #expect(twice.didRedact == false)
    }

    @Test func highEntropyTokensAreRedactedWithoutTouchingIdentifiers() {
        let filter = SecretFilter()
        let randomToken = "9xK2vM8qP4wZ7nB1cR5tY3uJ6hG0fD8sL4aE"
        let result = filter.redact("header: \(randomToken) in func calculateTotalOrderAmount()")
        #expect(result.text.contains(randomToken) == false)
        #expect(result.counts["high-entropy"] == 1)
        #expect(result.text.contains("calculateTotalOrderAmount"))
    }

    @Test func highEntropyHexTokenIsRedacted() {
        let filter = SecretFilter()
        let hexToken = "4a8f9c1b2d3e4f5a6b7c8d9e0f1a2b3c"
        let result = filter.redact("hex_key: \(hexToken)")
        #expect(result.text.contains(hexToken) == false)
        #expect(result.counts["high-entropy"] == 1)
    }

    @Test func repetitiveOrShortTokensAreNotRedacted() {
        let filter = SecretFilter()
        let repetitive = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
        let shortToken = "short1234567890123"
        let result = filter.redact("val1: \(repetitive), val2: \(shortToken)")
        #expect(result.text.contains(repetitive))
        #expect(result.text.contains(shortToken))
        #expect(result.counts["high-entropy"] == nil)
    }
}


@Suite("Environment builder")
struct EnvironmentBuilderTests {
    private let source: [String: String] = [
        "PATH": "/usr/bin:/bin",
        "HOME": "/Users/dev",
        "GOPATH": "/Users/dev/go",
        "GOFLAGS": "-mod=mod -ldflags=-X=main.v=1 -trimpath",
        "OPENAI_API_KEY": canaryKey,
        "ANTHROPIC_API_KEY": "sk-ant-CANARYabcdefghijklmnop",
        "AWS_SECRET_ACCESS_KEY": "wJalrXUtnFEMI/K7MDENG",
        "GITHUB_TOKEN": "ghp_abcdefghijklmnopqrstuvwxyz0123456789",
        "XPC_SERVICE_NAME": "0",
        "EDITOR": "vim",
        "CUSTOM_FLAG": "on",
        "MY_API_KEY": "supersecretvalue"
    ]

    @Test func forwardsOnlyTheAllowlist() {
        let env = EnvironmentBuilder().build(from: source)
        #expect(Set(env.keys).isSubset(of: EnvironmentBuilder.defaultAllowedNames))
        #expect(env["PATH"] == "/usr/bin:/bin")
        #expect(env["HOME"] == "/Users/dev")
        #expect(env["EDITOR"] == nil)
        #expect(env["XPC_SERVICE_NAME"] == nil)
    }

    @Test func goFlagsAreLimitedAndForcedReadOnly() {
        let env = EnvironmentBuilder().build(from: source)
        #expect(env["GOFLAGS"] == "-mod=readonly -trimpath")
        #expect(env["CGO_ENABLED"] == "0")
        #expect(EnvironmentBuilder().build(from: [:])["GOFLAGS"] == "-mod=readonly")
        #expect(EnvironmentBuilder().build(from: [:])["CGO_ENABLED"] == "0")
        #expect(EnvironmentBuilder().build(from: ["GOFLAGS": "-mod=vendor"])["GOFLAGS"] == "-mod=vendor")
    }

    @Test func secretCanariesNeverReachTheEnvironment() {
        let env = EnvironmentBuilder().build(from: source, grantedNames: ["CUSTOM_FLAG", "MY_API_KEY", "OPENAI_API_KEY", "GITHUB_TOKEN"])
        #expect(env["CUSTOM_FLAG"] == "on")
        for (name, value) in env {
            #expect(value.contains("CANARY") == false, "\(name) carries a canary")
            #expect(value.contains("ghp_") == false)
            #expect(value.contains("supersecretvalue") == false)
        }
        #expect(env["OPENAI_API_KEY"] == nil)
        #expect(env["MY_API_KEY"] == nil)
        #expect(env["GITHUB_TOKEN"] == nil)
    }

    @Test func allowedNamesWithSecretValuesAreDropped() {
        let filter = SecretFilter(literalSecrets: ["literal-canary-77"])
        let env = EnvironmentBuilder(filter: filter).build(from: [
            "PATH": "/usr/bin:literal-canary-77",
            "GOPROXY": "https://user:hunter2pass@proxy.example.com",
            "HOME": "/Users/dev"
        ])
        #expect(env["PATH"] == nil)
        #expect(env["GOPROXY"] == nil)
        #expect(env["HOME"] == "/Users/dev")
    }
}
