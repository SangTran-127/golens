// Self-check for Dockerfile completion, hover and stage lookup (top-level code, so compile it as main.swift):
//   cp scripts/dockerfile-assist-check.swift /tmp/main.swift && swiftc -O desktop/Utilities/DockerfileAssist.swift /tmp/main.swift -o /tmp/dac && /tmp/dac
import Foundation

func expect(_ ok: Bool, _ what: String) { if !ok { print("FAIL:", what); exit(1) } }

/// `|` marks the caret.
func complete(_ marked: String, explicit: Bool = false, go: String? = "1.23.2") -> DockerfileAssist.Completion? {
    let caret = (marked as NSString).range(of: "|").location
    let text = marked.replacingOccurrences(of: "|", with: "") as NSString
    return DockerfileAssist.completion(in: text, caret: caret, explicit: explicit, goVersion: { go })
}
func labels(_ marked: String, explicit: Bool = false) -> [String] { complete(marked, explicit: explicit)?.items.map(\.label) ?? [] }

expect(labels("FR|").first == "FROM", "FR -> FROM")
expect(labels("fr|").first == "FROM", "case-insensitive")
expect(labels("COP|") == ["COPY"], "COP -> COPY")
expect(labels("r|").first == "RUN", "r -> RUN first")
expect(complete("FR|")?.items.first?.insert == "FROM ", "inserted uppercase with a space")
expect(complete("  FR|")?.anchor == 2, "anchor after indentation")
expect(labels("|").isEmpty, "blank line stays quiet while typing")
expect(labels("|", explicit: true).last == "MAINTAINER", "explicit lists all, MAINTAINER last")
expect(complete("MAI|")?.items.first?.deprecated == true, "MAINTAINER is deprecated")
expect(labels("RUN go build \\\n  FR|").isEmpty, "no instruction inside a continuation")
expect(labels("# FR|").isEmpty, "no suggestion in a comment")

let stages = "FROM golang:1.23-alpine AS builder\nFROM node:20 AS web\nFROM scratch\n"
expect(labels(stages + "COPY --from=|") == ["builder", "web"], "stages after COPY --from=")
expect(labels(stages + "COPY --from=w|") == ["web"], "stage filter")
expect(labels("FROM a AS one\nCOPY --from=|\nFROM b AS two").contains("two") == false, "only earlier stages")
expect(complete(stages + "COPY --from=bu|")?.anchor == (stages as NSString).length + 12, "stage anchor after =")
expect(labels(stages + "RUN --mount=type=bind,from=|") == ["builder", "web"], "stages after mount from=")

expect(labels("COPY --|") == ["--from=", "--chown=", "--chmod=", "--link", "--parents", "--exclude="], "flags after COPY --")
expect(labels("ADD --|").contains("--checksum="), "ADD flags")
expect(labels("FROM --|") == ["--platform="], "FROM flags")
expect(labels("HEALTHCHECK --|").count == 5, "HEALTHCHECK flags")
expect(labels("COPY --chown=1:1 --f|") == ["--from="], "flags after another flag")
expect(labels("RUN --mount=|").first == "type=cache,target=/go/pkg/mod", "mount presets")
expect(labels("RUN --mount=type=s|") == ["type=secret,id=", "type=ssh"], "mount filter")
expect(labels("RUN --mount=type=cache,target=/go/pkg/mod \\\n    --|").contains("--network="), "flags on a continuation line")

expect(labels("RUN go bu|").isEmpty, "no suggestion mid-line in a RUN shell command")
expect(labels("RUN echo --|").isEmpty, "no flags after shell words")
expect(labels("COPY . |").isEmpty, "no suggestion for COPY arguments")
expect(labels("FROM golang:1.23 AS b|").isEmpty, "no suggestion for the stage name")

let bases = labels(stages + "FROM |")
expect(bases.first == "golang:1.23.2-alpine AS builder", "go.mod version in base image")
expect(bases.contains("gcr.io/distroless/static-debian12:nonroot") && bases.contains("scratch") && bases.contains("builder"), "bases and stages after FROM")
expect(complete("FROM |", go: nil)?.items.first?.label == "golang:1-alpine AS builder", "fallback without go.mod")

let doc = "FROM golang:1.23 AS builder\nRUN go build\nFROM scratch\nCOPY --from=builder /app /app\nCOPY --from=0 /x /x\nCOPY --from=nope /y /y\n" as NSString
let ref = doc.range(of: "builder /app").location + 2
expect(DockerfileAssist.stageReference(in: doc, at: ref)?.stage?.line == 1, "--from=builder resolves to line 1")
expect(DockerfileAssist.stageReference(in: doc, at: doc.range(of: "=0").location + 1)?.stage?.line == 1, "numeric stage index")
let unknown = DockerfileAssist.stageReference(in: doc, at: doc.range(of: "nope").location)
expect(unknown != nil && unknown?.stage == nil, "unknown stage is a reference without a target")
expect(DockerfileAssist.stageReference(in: doc, at: doc.range(of: "golang").location) == nil, "base image is not a stage")
expect(DockerfileAssist.hoverMarkdown(in: doc, at: ref)?.contains("defined at line 1") == true, "stage hover")
expect(DockerfileAssist.hoverMarkdown(in: doc, at: doc.range(of: "RUN").location + 1)?.hasPrefix("**RUN**") == true, "instruction hover")
expect(DockerfileAssist.hoverMarkdown(in: doc, at: doc.range(of: "go build").location + 3) == nil, "no hover on shell words")

expect(DockerfileAssist.goVersion(goMod: "module x\n\ngo 1.22.5\n\ntoolchain go1.23.1\n") == "1.22.5", "go directive")
expect(DockerfileAssist.goVersion(goMod: "module x\n") == nil, "no go directive")
let dir = NSTemporaryDirectory() + "dac-\(getpid())/svc/deploy"
try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
try! "module x\ngo 1.21\n".write(toFile: (dir as NSString).deletingLastPathComponent + "/go.mod", atomically: true, encoding: .utf8)
expect(DockerfileAssist.goVersion(nearDockerfile: dir + "/Dockerfile", openText: { _ in nil }) == "1.21", "nearest go.mod on disk")
expect(DockerfileAssist.goVersion(nearDockerfile: dir + "/Dockerfile", openText: { $0.hasSuffix("svc/go.mod") ? "go 1.24\n" : nil }) == "1.24", "open go.mod wins")
try? FileManager.default.removeItem(atPath: NSTemporaryDirectory() + "dac-\(getpid())")

print("dockerfile-assist-check: ok")
