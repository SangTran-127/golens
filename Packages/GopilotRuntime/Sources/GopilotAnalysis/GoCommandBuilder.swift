import Foundation

public enum GoCommandError: Error, Sendable, Equatable {
    case invalidPackageSelector(String)
    case invalidTestName(String)
    case invalidTag(String)
    case invalidBenchtime(String)
    case countOutOfRange(Int)
    case timeoutOutOfRange(Int)
    case noTargets
    case forbiddenArgument(String)
    case notAGoTestCommand
    case instrumentationOnTimedRun(String)
}

public struct GoCommand: Sendable, Equatable, Codable {
    public enum Kind: String, Sendable, Codable {
        case test
        case benchmark
    }

    public let kind: Kind
    public let argv: [String]
}

public enum GoCommandBuilder {
    public static let maxCount = 100
    public static let maxTimeoutSeconds = 600

    private static let forbiddenSubcommands: Set<String> = ["get", "install", "tidy", "generate", "mod", "work", "run", "build", "clean", "env"]
    private static let forbiddenFlagPrefixes = ["-exec", "-toolexec", "-overlay", "-modfile", "-pkgdir", "-gcflags", "-ldflags", "-asmflags", "-gccgoflags", "-vettool"]
    private static let instrumentationFlagPrefixes = [
        "-race", "-msan", "-asan", "-cover", "-cpuprofile", "-memprofile", "-memprofilerate", "-blockprofile", "-blockprofilerate",
        "-mutexprofile", "-mutexprofilefraction", "-trace", "-fuzz", "-test.cpuprofile", "-test.memprofile", "-test.blockprofile",
        "-test.mutexprofile", "-test.trace", "-test.coverprofile"
    ]

    public static func test(packages: [String], tests: [String] = [], count: Int = 1, timeoutSeconds: Int = 120, json: Bool = false, tags: [String] = []) throws -> GoCommand {
        var argv = ["go", "test", "-mod=readonly"]
        argv += try tagArguments(tags)
        try appendPackageIndependentArguments(&argv, count: count, timeoutSeconds: timeoutSeconds)
        if json { argv.append("-json") }
        if !tests.isEmpty {
            argv += ["-run", try anchoredPattern(tests)]
        }
        argv += try packageArguments(packages)
        return GoCommand(kind: .test, argv: argv)
    }

    public static func benchmark(packages: [String], benchmarks: [String], count: Int = 10, benchtime: String? = nil, benchmem: Bool = true, timeoutSeconds: Int = 300, json: Bool = false, tags: [String] = []) throws -> GoCommand {
        guard !benchmarks.isEmpty else { throw GoCommandError.noTargets }
        var argv = ["go", "test", "-mod=readonly"]
        argv += try tagArguments(tags)
        try appendPackageIndependentArguments(&argv, count: count, timeoutSeconds: timeoutSeconds)
        if json { argv.append("-json") }
        argv += ["-run", "^$", "-bench", try anchoredPattern(benchmarks)]
        if benchmem { argv.append("-benchmem") }
        if let benchtime {
            guard isValidBenchtime(benchtime) else { throw GoCommandError.invalidBenchtime(benchtime) }
            argv.append("-benchtime=\(benchtime)")
        }
        argv += try packageArguments(packages)
        return GoCommand(kind: .benchmark, argv: argv)
    }

    public static func audit(argv: [String], timedComparison: Bool) throws {
        guard argv.count >= 2, argv[0] == "go" || argv[0].hasSuffix("/go"), argv[1] == "test" else {
            if argv.count >= 2, forbiddenSubcommands.contains(argv[1]) { throw GoCommandError.forbiddenArgument(argv[1]) }
            throw GoCommandError.notAGoTestCommand
        }
        for argument in argv.dropFirst(2) {
            if argument == "--" { break }
            let name = argument.split(separator: "=", maxSplits: 1).first.map(String.init) ?? argument
            if forbiddenFlagPrefixes.contains(where: { name == $0 }) { throw GoCommandError.forbiddenArgument(argument) }
            if timedComparison, instrumentationFlagPrefixes.contains(where: { name == $0 }) {
                throw GoCommandError.instrumentationOnTimedRun(argument)
            }
        }
    }

    public static func regexEscape(_ text: String) -> String {
        let special = Set("\\.+*?()|[]{}^$")
        var out = ""
        for character in text {
            if special.contains(character) { out.append("\\") }
            out.append(character)
        }
        return out
    }

    public static func validatePackageSelector(_ selector: String) throws {
        guard !selector.isEmpty, selector.count <= 256 else { throw GoCommandError.invalidPackageSelector(selector) }
        guard !selector.hasPrefix("-"), !selector.hasPrefix("/"), !selector.hasPrefix("~") else { throw GoCommandError.invalidPackageSelector(selector) }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-./+@")
        guard selector.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { throw GoCommandError.invalidPackageSelector(selector) }
        let components = selector.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        for (index, component) in components.enumerated() {
            if component == "..." {
                if index != components.count - 1 { throw GoCommandError.invalidPackageSelector(selector) }
                continue
            }
            if component.contains("..") { throw GoCommandError.invalidPackageSelector(selector) }
            if component.isEmpty { throw GoCommandError.invalidPackageSelector(selector) }
        }
    }

    private static func packageArguments(_ packages: [String]) throws -> [String] {
        guard !packages.isEmpty else { throw GoCommandError.noTargets }
        for selector in packages { try validatePackageSelector(selector) }
        return packages
    }

    private static func tagArguments(_ tags: [String]) throws -> [String] {
        guard !tags.isEmpty else { return [] }
        for tag in tags {
            guard !tag.isEmpty, tag.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_.")).contains($0) }) else {
                throw GoCommandError.invalidTag(tag)
            }
        }
        return ["-tags=\(tags.sorted().joined(separator: ","))"]
    }

    private static func appendPackageIndependentArguments(_ argv: inout [String], count: Int, timeoutSeconds: Int) throws {
        guard (1...maxCount).contains(count) else { throw GoCommandError.countOutOfRange(count) }
        guard (1...maxTimeoutSeconds).contains(timeoutSeconds) else { throw GoCommandError.timeoutOutOfRange(timeoutSeconds) }
        argv.append("-count=\(count)")
        argv.append("-timeout=\(timeoutSeconds)s")
    }

    private static func anchoredPattern(_ names: [String]) throws -> String {
        var unique: [String] = []
        for name in names {
            guard isGoIdentifier(name) else { throw GoCommandError.invalidTestName(name) }
            if !unique.contains(name) { unique.append(name) }
        }
        let escaped = unique.map(regexEscape).joined(separator: "|")
        return "^(\(escaped))$"
    }

    private static func isGoIdentifier(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, !name.isEmpty, name.count <= 256 else { return false }
        guard CharacterSet.letters.contains(first) || first == "_" else { return false }
        return name.unicodeScalars.allSatisfy { CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0) || $0 == "_" }
    }

    private static func isValidBenchtime(_ value: String) -> Bool {
        let pattern = #"^[0-9]+(\.[0-9]+)?(ns|us|ms|s|m|h)$|^[0-9]+x$"#
        return value.range(of: pattern, options: .regularExpression) != nil
    }
}
