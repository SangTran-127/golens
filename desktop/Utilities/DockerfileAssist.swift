import Foundation

enum DockerfileAssist {
    struct Item: Equatable {
        let label: String
        let insert: String
        let kind: String
        let detail: String
        let signature: String
        let doc: String
        var deprecated = false
    }

    struct Completion: Equatable {
        let anchor: Int
        let query: String
        let items: [Item]
    }

    struct Stage: Equatable {
        let name: String?
        let index: Int
        let line: Int
        let base: String
        let location: Int
    }

    struct Instruction {
        let name: String
        let detail: String
        let syntax: String
        let summary: String
    }

    struct Flag {
        let name: String
        let detail: String
        let example: String
        let doc: String
    }

    static let instructions: [Instruction] = [
        .init(name: "FROM", detail: "Start a build stage", syntax: "FROM [--platform=<platform>] <image>[:<tag>] [AS <name>]", summary: "Starts a new build stage from a base image. Name it with AS to copy from it in a later stage."),
        .init(name: "RUN", detail: "Run a command", syntax: "RUN [--mount=<mount>] [--network=<mode>] <command>", summary: "Runs a command in a new layer on top of the current image, for example to download modules or build the binary."),
        .init(name: "COPY", detail: "Copy files", syntax: "COPY [--from=<stage>] [--chown=<user>] [--chmod=<perms>] <src>... <dest>", summary: "Copies files from the build context, or from another stage with --from, into the image."),
        .init(name: "ADD", detail: "Add files, URLs or archives", syntax: "ADD [--chown=<user>] [--checksum=<digest>] <src>... <dest>", summary: "Like COPY, but also fetches URLs and Git repositories and unpacks local tar archives. Prefer COPY for plain files."),
        .init(name: "WORKDIR", detail: "Set the working directory", syntax: "WORKDIR <path>", summary: "Sets the working directory for the RUN, CMD, ENTRYPOINT, COPY and ADD instructions that follow, creating it if needed."),
        .init(name: "ENV", detail: "Set environment variables", syntax: "ENV <key>=<value> ...", summary: "Sets environment variables for the rest of the build and for containers started from the image."),
        .init(name: "ARG", detail: "Declare a build argument", syntax: "ARG <name>[=<default>]", summary: "Declares a build-time variable that can be set with docker build --build-arg. It is not kept in the final image."),
        .init(name: "EXPOSE", detail: "Document a listening port", syntax: "EXPOSE <port>[/<protocol>] ...", summary: "Documents the ports the container listens on. It does not publish them; use -p or compose ports for that."),
        .init(name: "CMD", detail: "Default command or arguments", syntax: "CMD [\"executable\", \"param\"]", summary: "Sets the default command, or the default arguments for ENTRYPOINT. Only the last CMD takes effect."),
        .init(name: "ENTRYPOINT", detail: "Container executable", syntax: "ENTRYPOINT [\"executable\", \"param\"]", summary: "Sets the executable the container runs; CMD supplies its default arguments. Use the exec form so signals reach your Go binary."),
        .init(name: "USER", detail: "Set the user", syntax: "USER <user>[:<group>]", summary: "Sets the user and group for the instructions that follow and for the running container, for example 65532:65532 (nonroot)."),
        .init(name: "VOLUME", detail: "Declare a mount point", syntax: "VOLUME [\"/data\"]", summary: "Creates a mount point for data that lives outside the container's writable layer."),
        .init(name: "LABEL", detail: "Add image metadata", syntax: "LABEL <key>=<value> ...", summary: "Adds metadata to the image, such as org.opencontainers.image.source."),
        .init(name: "HEALTHCHECK", detail: "Container health check", syntax: "HEALTHCHECK [--interval=<duration>] [--timeout=<duration>] CMD <command> | HEALTHCHECK NONE", summary: "Tells Docker how to test that the container still works. A non-zero exit marks it unhealthy."),
        .init(name: "SHELL", detail: "Set the default shell", syntax: "SHELL [\"executable\", \"param\"]", summary: "Changes the shell used by the shell form of RUN, CMD and ENTRYPOINT."),
        .init(name: "STOPSIGNAL", detail: "Set the stop signal", syntax: "STOPSIGNAL <signal>", summary: "Sets the signal sent to the container to make it exit, for example SIGTERM."),
        .init(name: "ONBUILD", detail: "Trigger for child images", syntax: "ONBUILD <INSTRUCTION>", summary: "Registers an instruction that runs later, when another image is built FROM this one."),
        .init(name: "MAINTAINER", detail: "deprecated", syntax: "MAINTAINER <name>", summary: "Deprecated. Sets the image author; use LABEL org.opencontainers.image.authors instead."),
    ]

    static let flags: [String: [Flag]] = {
        let chown = Flag(name: "--chown=", detail: "Set the owner", example: "--chown=65532:65532", doc: "Sets the user and group that own the copied files.")
        let chmod = Flag(name: "--chmod=", detail: "Set permissions", example: "--chmod=0755", doc: "Sets the permission bits of the copied files.")
        let link = Flag(name: "--link", detail: "Copy into an independent layer", example: "--link", doc: "Copies into its own layer so it can be reused even when earlier layers change.")
        return [
            "FROM": [
                Flag(name: "--platform=", detail: "Target platform", example: "--platform=$BUILDPLATFORM", doc: "Uses the image variant for this platform, for example linux/amd64. With $BUILDPLATFORM the Go compiler runs natively and cross-compiles."),
            ],
            "COPY": [
                Flag(name: "--from=", detail: "Copy from a stage or image", example: "--from=builder /out/app /app", doc: "Copies from an earlier build stage, a stage index or an image instead of the build context."),
                chown, chmod, link,
                Flag(name: "--parents", detail: "Keep parent directories", example: "--parents ./cmd/*/main.go /src/", doc: "Keeps the source's parent directories under the destination."),
                Flag(name: "--exclude=", detail: "Skip matching paths", example: "--exclude=*_test.go", doc: "Leaves out paths that match the pattern."),
            ],
            "ADD": [
                chown, chmod,
                Flag(name: "--checksum=", detail: "Verify a remote file", example: "--checksum=sha256:<digest>", doc: "Fails the build unless the remote source has this checksum."),
                Flag(name: "--keep-git-dir", detail: "Keep the .git directory", example: "--keep-git-dir", doc: "Keeps the .git directory when adding a Git repository."),
                link,
            ],
            "RUN": [
                Flag(name: "--mount=", detail: "Mount a cache, secret or bind", example: "--mount=type=cache,target=/go/pkg/mod", doc: "Mounts a cache, secret, SSH agent or files from another stage for this command only."),
                Flag(name: "--network=", detail: "Network mode", example: "--network=none", doc: "Sets the network for this command: default, none or host."),
                Flag(name: "--security=", detail: "Security mode", example: "--security=insecure", doc: "Runs the command with insecure (privileged) or sandbox security."),
            ],
            "HEALTHCHECK": [
                Flag(name: "--interval=", detail: "Time between checks", example: "--interval=30s", doc: "Time between health checks. Default 30s."),
                Flag(name: "--timeout=", detail: "Time before a check fails", example: "--timeout=3s", doc: "A check that takes longer counts as failed. Default 30s."),
                Flag(name: "--start-period=", detail: "Startup grace period", example: "--start-period=5s", doc: "Failures during this period don't count toward the retries. Default 0s."),
                Flag(name: "--start-interval=", detail: "Check interval during startup", example: "--start-interval=1s", doc: "Time between checks during the start period. Default 5s."),
                Flag(name: "--retries=", detail: "Failures before unhealthy", example: "--retries=3", doc: "Consecutive failures needed to mark the container unhealthy. Default 3."),
            ],
        ]
    }()

    static let mountPresets: [Item] = [
        .init(label: "type=cache,target=/go/pkg/mod", insert: "type=cache,target=/go/pkg/mod", kind: "snippet", detail: "Go module cache", signature: "RUN --mount=type=cache,target=/go/pkg/mod go mod download", doc: "Keeps downloaded modules between builds so go mod download only fetches what changed."),
        .init(label: "type=cache,target=/root/.cache/go-build", insert: "type=cache,target=/root/.cache/go-build", kind: "snippet", detail: "Go build cache", signature: "RUN --mount=type=cache,target=/root/.cache/go-build go build ./...", doc: "Keeps compiled packages between builds so go build only recompiles what changed."),
        .init(label: "type=secret,id=", insert: "type=secret,id=", kind: "snippet", detail: "Build secret", signature: "RUN --mount=type=secret,id=netrc,target=/root/.netrc go mod download", doc: "Mounts a secret passed with docker build --secret. It is not stored in the image."),
        .init(label: "type=ssh", insert: "type=ssh", kind: "snippet", detail: "SSH agent", signature: "RUN --mount=type=ssh go mod download", doc: "Forwards the SSH agent passed with docker build --ssh, for example to fetch private modules."),
        .init(label: "type=bind,source=,target=", insert: "type=bind,source=,target=", kind: "snippet", detail: "Bind files without copying", signature: "RUN --mount=type=bind,source=go.mod,target=go.mod go mod download", doc: "Mounts files from the build context or another stage (from=) for this command without adding a layer."),
    ]

    static func baseImages(goVersion: String?) -> [Item] {
        let v = goVersion ?? "1"
        let source = goVersion.map { "Go \($0) from go.mod" } ?? "Go toolchain"
        return [
            .init(label: "golang:\(v)-alpine AS builder", insert: "golang:\(v)-alpine AS builder", kind: "module", detail: "\(source), Alpine", signature: "FROM golang:\(v)-alpine AS builder", doc: "Small Go toolchain image for compiling. Copy the binary into a minimal final stage."),
            .init(label: "golang:\(v)", insert: "golang:\(v)", kind: "module", detail: "\(source), Debian", signature: "FROM golang:\(v)", doc: "Debian-based Go toolchain. Use it when the build needs cgo or system packages."),
            .init(label: "gcr.io/distroless/static-debian12:nonroot", insert: "gcr.io/distroless/static-debian12:nonroot", kind: "module", detail: "Final stage, static binary", signature: "FROM gcr.io/distroless/static-debian12:nonroot", doc: "No shell or libc, runs as non-root. Build with CGO_ENABLED=0."),
            .init(label: "gcr.io/distroless/base-debian12:nonroot", insert: "gcr.io/distroless/base-debian12:nonroot", kind: "module", detail: "Final stage, glibc", signature: "FROM gcr.io/distroless/base-debian12:nonroot", doc: "Includes glibc for cgo binaries, no shell, runs as non-root."),
            .init(label: "alpine:3.20", insert: "alpine:3.20", kind: "module", detail: "Final stage with a shell", signature: "FROM alpine:3.20", doc: "Small musl-based image with a shell and apk. Build with CGO_ENABLED=0 or on Alpine."),
            .init(label: "scratch", insert: "scratch", kind: "module", detail: "Empty final stage", signature: "FROM scratch", doc: "Contains only what you copy in. Needs a static binary, and CA certificates if it calls HTTPS."),
        ]
    }

    static func instructionItems() -> [Item] {
        instructions.map {
            Item(label: $0.name, insert: $0.name + " ", kind: "keyword", detail: $0.detail, signature: $0.syntax, doc: $0.summary, deprecated: $0.name == "MAINTAINER")
        }
    }

    static func stageItem(_ s: Stage) -> Item? {
        guard let name = s.name else { return nil }
        return Item(label: name, insert: name, kind: "struct", detail: "stage, line \(s.line)", signature: "FROM \(s.base) AS \(name)", doc: "Build stage defined at line \(s.line).")
    }

    static func filter(_ items: [Item], _ query: String) -> [Item] {
        guard !query.isEmpty else { return items }
        let q = query.lowercased()
        let prefix = items.filter { $0.label.lowercased().hasPrefix(q) }
        let inner = items.filter { !$0.label.lowercased().hasPrefix(q) && $0.label.lowercased().contains(q) }
        return prefix + inner
    }

    static func logicalPrefix(in text: NSString, caret: Int) -> (text: String, start: Int, continued: Bool)? {
        guard caret >= 0, caret <= text.length else { return nil }
        let lineStart = text.lineRange(for: NSRange(location: caret, length: 0)).location
        let current = text.substring(with: NSRange(location: lineStart, length: caret - lineStart))
        if current.trimmingCharacters(in: .whitespaces).hasPrefix("#") { return nil }
        var parts = [current]
        var start = lineStart
        var cursor = lineStart
        while cursor > 0 {
            let prev = text.lineRange(for: NSRange(location: cursor - 1, length: 0))
            cursor = prev.location
            let raw = text.substring(with: prev).trimmingCharacters(in: .whitespacesAndNewlines)
            if raw.hasPrefix("#") { continue }
            guard raw.hasSuffix("\\") else { break }
            parts.insert(String(raw.dropLast()), at: 0)
            start = prev.location
        }
        let joined = parts.joined(separator: " ")
        return (String(joined.drop { $0 == " " || $0 == "\t" }), start, start != lineStart)
    }

    static func completion(in text: NSString, caret: Int, explicit: Bool = false, goVersion: () -> String?) -> Completion? {
        guard let lp = logicalPrefix(in: text, caret: caret) else { return nil }
        let isBlank: (Character) -> Bool = { $0 == " " || $0 == "\t" }
        var tokens = lp.text.split(whereSeparator: isBlank).map(String.init)
        let cur = (lp.text.last.map(isBlank) ?? true) ? "" : (tokens.popLast() ?? "")
        func result(_ items: [Item], _ query: String) -> Completion? {
            let matched = filter(items, query)
            return matched.isEmpty ? nil : Completion(anchor: caret - (query as NSString).length, query: query, items: matched)
        }

        if tokens.isEmpty {
            guard !lp.continued, cur.allSatisfy({ $0.isASCII && $0.isLetter }), explicit || !cur.isEmpty else { return nil }
            return result(instructionItems(), cur)
        }
        let instruction = tokens[0].uppercased()
        guard tokens.dropFirst().allSatisfy({ $0.hasPrefix("--") }) else { return nil }
        func earlierStages() -> [Item] { stages(in: text).filter { $0.location < lp.start }.compactMap(stageItem) }

        if cur.hasPrefix("--") {
            guard let eq = cur.firstIndex(of: "=") else {
                return result((flags[instruction] ?? []).map {
                    Item(label: $0.name, insert: $0.name, kind: "property", detail: $0.detail, signature: "\(instruction) \($0.example)", doc: $0.doc)
                }, cur)
            }
            let name = cur[..<eq].lowercased()
            let value = String(cur[cur.index(after: eq)...])
            if instruction == "COPY" && name == "--from" { return result(earlierStages(), value) }
            guard instruction == "RUN" && name == "--mount" else { return nil }
            guard let comma = value.lastIndex(of: ",") else { return result(mountPresets, value) }
            let segment = value[value.index(after: comma)...]
            guard segment.lowercased().hasPrefix("from=") else { return nil }
            return result(earlierStages(), String(segment.dropFirst(5)))
        }
        guard instruction == "FROM" else { return nil }
        return result(baseImages(goVersion: goVersion()) + earlierStages(), cur)
    }

    private static let fromLine = try! NSRegularExpression(pattern: #"^\s*FROM\s+(?:--\S+\s+)*(\S+)(?:\s+AS\s+([A-Za-z0-9_.-]+))?"#, options: [.caseInsensitive])

    static func stages(in text: NSString) -> [Stage] {
        var out: [Stage] = []
        var location = 0
        var line = 0
        while location < text.length {
            let range = text.lineRange(for: NSRange(location: location, length: 0))
            line += 1
            let s = text.substring(with: range) as NSString
            if let m = fromLine.firstMatch(in: s as String, range: NSRange(location: 0, length: s.length)) {
                let name = m.range(at: 2).location == NSNotFound ? nil : s.substring(with: m.range(at: 2))
                out.append(Stage(name: name, index: out.count, line: line, base: s.substring(with: m.range(at: 1)), location: range.location))
            }
            location = NSMaxRange(range)
        }
        return out
    }

    private static func isNameChar(_ c: unichar) -> Bool {
        (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x5F || c == 0x2E || c == 0x2D
    }

    static func nameRange(in text: NSString, at index: Int) -> NSRange? {
        var i = index
        if i >= text.length || i < 0 || !isNameChar(text.character(at: i)) { i -= 1 }
        guard i >= 0, i < text.length, isNameChar(text.character(at: i)) else { return nil }
        var start = i
        while start > 0, isNameChar(text.character(at: start - 1)) { start -= 1 }
        var end = i + 1
        while end < text.length, isNameChar(text.character(at: end)) { end += 1 }
        return NSRange(location: start, length: end - start)
    }

    private static let imagePosition = try! NSRegularExpression(pattern: #"^from\s+(?:--\S+\s+)*$|^from\s+.*\s+as\s+$"#, options: [.caseInsensitive])

    static func stageReference(in text: NSString, at index: Int) -> (name: String, stage: Stage?)? {
        guard let range = nameRange(in: text, at: index),
              let lp = logicalPrefix(in: text, caret: range.location) else { return nil }
        let name = text.substring(with: range)
        let all = stages(in: text)
        let found = name.allSatisfy(\.isNumber)
            ? all.first { String($0.index) == name }
            : all.first { $0.name?.lowercased() == name.lowercased() }
        if lp.text.lowercased().hasSuffix("from=") { return (name, found) }
        let before = lp.text as NSString
        guard !lp.continued, let found, imagePosition.firstMatch(in: lp.text, range: NSRange(location: 0, length: before.length)) != nil else { return nil }
        return (name, found)
    }

    static func hoverMarkdown(in text: NSString, at index: Int) -> String? {
        if let ref = stageReference(in: text, at: index), let stage = ref.stage {
            return "Stage `\(stage.name ?? String(stage.index))` — defined at line \(stage.line) (`\(stage.base)`)"
        }
        guard let range = nameRange(in: text, at: index),
              let lp = logicalPrefix(in: text, caret: range.location), lp.text.isEmpty, !lp.continued else { return nil }
        let word = text.substring(with: range).uppercased()
        guard let ins = instructions.first(where: { $0.name == word }) else { return nil }
        return "**\(ins.name)** — \(ins.summary)\n\n```\n\(ins.syntax)\n```"
    }

    static func goVersion(goMod: String) -> String? {
        for line in goMod.components(separatedBy: .newlines) {
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count >= 2, fields[0] == "go" else { continue }
            let v = String(fields[1])
            return v.first?.isNumber == true && v.allSatisfy({ $0.isNumber || $0 == "." || ($0.isASCII && $0.isLetter) }) ? v : nil
        }
        return nil
    }

    static func goVersion(nearDockerfile path: String, openText: (String) -> String?) -> String? {
        var dir = (path as NSString).deletingLastPathComponent
        while !dir.isEmpty {
            let mod = (dir as NSString).appendingPathComponent("go.mod")
            if let text = openText(mod) ?? (try? String(contentsOfFile: mod, encoding: .utf8)) {
                return goVersion(goMod: text)
            }
            let parent = (dir as NSString).deletingLastPathComponent
            if parent == dir { break }
            dir = parent
        }
        return nil
    }
}
