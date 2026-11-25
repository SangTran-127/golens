import Foundation
import Testing
@testable import GopilotAnalysis

@Suite("Go command builder")
struct GoCommandBuilderTests {
    @Test func testRunIsAnchoredEscapedArgv() throws {
        let command = try GoCommandBuilder.test(packages: ["./pkg/slug"], tests: ["TestA", "TestB"], count: 1, timeoutSeconds: 30)
        #expect(command.argv == ["go", "test", "-mod=readonly", "-count=1", "-timeout=30s", "-run", "^(TestA|TestB)$", "./pkg/slug"])
        #expect(!command.argv.contains("sh"))
        #expect(!command.argv.contains("-c"))
    }

    @Test func benchmarkOnlyDisablesTests() throws {
        let command = try GoCommandBuilder.benchmark(packages: ["./..."], benchmarks: ["BenchmarkMake"], count: 10, benchtime: "200ms")
        #expect(command.kind == .benchmark)
        let argv = command.argv
        let runIndex = try #require(argv.firstIndex(of: "-run"))
        #expect(argv[runIndex + 1] == "^$")
        let benchIndex = try #require(argv.firstIndex(of: "-bench"))
        #expect(argv[benchIndex + 1] == "^(BenchmarkMake)$")
        #expect(argv.contains("-benchmem"))
        #expect(argv.contains("-count=10"))
        #expect(argv.contains("-benchtime=200ms"))
        #expect(argv.contains("-mod=readonly"))
        #expect(argv.last == "./...")
    }

    @Test func benchmarkNeverCarriesInstrumentation() throws {
        let command = try GoCommandBuilder.benchmark(packages: ["."], benchmarks: ["BenchmarkX"])
        try GoCommandBuilder.audit(argv: command.argv, timedComparison: true)
        for flag in ["-race", "-cpuprofile", "-memprofile", "-blockprofile", "-mutexprofile", "-trace", "-cover"] {
            #expect(!command.argv.contains { $0.hasPrefix(flag) })
        }
    }

    @Test(arguments: ["../outside", "./a/../b", "a;rm -rf /", "$(whoami)", "`id`", "a b", "pkg|cat", "-exec=evil", "/etc/passwd", "~/x", "", "./a/.../b", "pkg&&ls", "pkg\nls", "a>b", "a'b", "a\"b", "a*b"])
    func rejectsUnsafeSelectors(_ selector: String) {
        #expect(throws: GoCommandError.self) {
            try GoCommandBuilder.test(packages: [selector])
        }
    }

    @Test(arguments: ["./...", ".", "./cmd/app", "example.test/slug", "./internal/a_b-c", "./pkg/..."])
    func acceptsSafeSelectors(_ selector: String) throws {
        let command = try GoCommandBuilder.test(packages: [selector])
        #expect(command.argv.last == selector)
    }

    @Test(arguments: ["Test A", "TestA|TestB", "Test.*", "TestA$", "Test/Sub", "", "1Test", "Test;ls", "-run"])
    func rejectsUnsafeTestNames(_ name: String) {
        #expect(throws: GoCommandError.self) {
            try GoCommandBuilder.test(packages: ["."], tests: [name])
        }
    }

    @Test func regexEscapeNeutralisesMetacharacters() {
        #expect(GoCommandBuilder.regexEscape("a.b*c(d)|e[f]{g}^$+?\\") == "a\\.b\\*c\\(d\\)\\|e\\[f\\]\\{g\\}\\^\\$\\+\\?\\\\")
    }

    @Test func duplicateNamesCollapse() throws {
        let command = try GoCommandBuilder.test(packages: ["."], tests: ["TestA", "TestA"])
        #expect(command.argv.contains("^(TestA)$"))
    }

    @Test func rejectsBadNumericAndTagInputs() {
        #expect(throws: GoCommandError.countOutOfRange(0)) { try GoCommandBuilder.test(packages: ["."], count: 0) }
        #expect(throws: GoCommandError.countOutOfRange(101)) { try GoCommandBuilder.benchmark(packages: ["."], benchmarks: ["BenchmarkX"], count: 101) }
        #expect(throws: GoCommandError.timeoutOutOfRange(601)) { try GoCommandBuilder.test(packages: ["."], timeoutSeconds: 601) }
        #expect(throws: GoCommandError.invalidBenchtime("1s; ls")) { try GoCommandBuilder.benchmark(packages: ["."], benchmarks: ["BenchmarkX"], benchtime: "1s; ls") }
        #expect(throws: GoCommandError.invalidTag("a b")) { try GoCommandBuilder.test(packages: ["."], tags: ["a b"]) }
        #expect(throws: GoCommandError.noTargets) { try GoCommandBuilder.benchmark(packages: ["."], benchmarks: []) }
        #expect(throws: GoCommandError.noTargets) { try GoCommandBuilder.test(packages: []) }
    }

    @Test func tagsAreSortedAndJoined() throws {
        let command = try GoCommandBuilder.test(packages: ["."], tags: ["integration", "linux"])
        #expect(command.argv.contains("-tags=integration,linux"))
    }

    @Test(arguments: [
        ["go", "get", "example.com/x"],
        ["go", "mod", "tidy"],
        ["go", "generate", "./..."],
        ["go", "install", "x"],
        ["go", "test", "-exec", "evil", "./..."],
        ["go", "test", "-toolexec=evil", "./..."],
        ["go", "test", "-ldflags=-X=a.b=c", "./..."],
        ["sh", "-c", "go test"],
        ["go"]
    ])
    func auditRefusesForbiddenCommands(_ argv: [String]) {
        #expect(throws: GoCommandError.self) { try GoCommandBuilder.audit(argv: argv, timedComparison: false) }
    }

    @Test(arguments: ["-race", "-cpuprofile=cpu.out", "-memprofile", "-blockprofile=b.out", "-mutexprofile=m.out", "-trace=t.out", "-cover"])
    func auditRefusesInstrumentationOnTimedRuns(_ flag: String) throws {
        let argv = ["go", "test", "-bench", ".", flag, "./..."]
        #expect(throws: GoCommandError.instrumentationOnTimedRun(flag)) { try GoCommandBuilder.audit(argv: argv, timedComparison: true) }
        try GoCommandBuilder.audit(argv: argv, timedComparison: false)
    }
}
