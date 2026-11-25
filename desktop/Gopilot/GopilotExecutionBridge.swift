import Foundation
import GopilotAnalysis
import GopilotPolicy
import GopilotTools
import Observation

struct GopilotPendingApproval: Identifiable {
    let id = UUID()
    let card: ExecutionApprovalCard
}

struct GopilotPendingDirty: Identifiable {
    let id = UUID()
    let paths: [String]
}

@Observable
final class GopilotInteractionCenter {
    var approval: GopilotPendingApproval?
    @ObservationIgnored var autoApprove = false
    @ObservationIgnored var gopilotEditedPaths: () -> Set<String> = { [] }
    @ObservationIgnored var approvalLog: [(String, String)] = []
    var dirty: GopilotPendingDirty?

    @ObservationIgnored private var approvalContinuation: CheckedContinuation<ApprovalDecision, Never>?
    @ObservationIgnored private var dirtyContinuation: CheckedContinuation<DirtyBufferDecision, Never>?

    @MainActor
    func requestApproval(_ card: ExecutionApprovalCard) async -> ApprovalDecision {
        if autoApprove {
            approvalLog.append((card.operation.rawValue, "allowOnce"))
            return .allowOnce
        }
        let pending = GopilotPendingApproval(card: card)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                resolveApproval(.decline)
                approval = pending
                approvalContinuation = continuation
            }
        } onCancel: {
            Task { @MainActor in
                if self.approval?.id == pending.id { self.resolveApproval(.decline) }
            }
        }
    }

    @MainActor
    func resolveApproval(_ decision: ApprovalDecision) {
        approval = nil
        approvalContinuation?.resume(returning: decision)
        approvalContinuation = nil
    }

    @MainActor
    func chooseDirtyAction(paths: [String]) async -> DirtyBufferDecision {
        if autoApprove, gopilotEditedPaths().isDisjoint(with: paths) {
            approvalLog.append(("dirtyBuffers", "runSavedVersion"))
            return .runSavedVersion
        }
        let pending = GopilotPendingDirty(paths: paths)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                resolveDirty(.cancel)
                dirty = pending
                dirtyContinuation = continuation
            }
        } onCancel: {
            Task { @MainActor in
                if self.dirty?.id == pending.id { self.resolveDirty(.cancel) }
            }
        }
    }

    @MainActor
    func resolveDirty(_ decision: DirtyBufferDecision) {
        dirty = nil
        dirtyContinuation?.resume(returning: decision)
        dirtyContinuation = nil
    }

    @MainActor
    func cancelAll() {
        resolveApproval(.decline)
        resolveDirty(.cancel)
    }
}

struct GopilotApprovalBridge: ApprovalProvider {
    let center: GopilotInteractionCenter

    func requestApproval(_ card: ExecutionApprovalCard) async -> ApprovalDecision {
        await center.requestApproval(card)
    }
}

struct GopilotDirtyBufferBridge: DirtyBufferProvider {
    let center: GopilotInteractionCenter
    let access: GopilotWorkspaceAccess
    let workspace: WorkspaceState

    func bufferStates() async -> [BufferDiskState] {
        let buffers = await MainActor.run { access.editedBuffers() }
        return buffers.compactMap { path, value in
            guard let relative = access.relative(path) else { return nil }
            let disk = (try? Data(contentsOf: URL(fileURLWithPath: path))).map { ContentHash.sha256Hex($0) } ?? ""
            return BufferDiskState(path: relative, diskContentHash: disk, bufferContentHash: ContentHash.sha256Hex(value.text), documentVersion: value.version)
        }.sorted { $0.path < $1.path }
    }

    func chooseAction(dirtyPaths: [String]) async -> DirtyBufferDecision {
        await center.chooseDirtyAction(paths: dirtyPaths)
    }

    func save(paths: [String]) async -> Bool {
        let root = access.root
        return await withCheckedContinuation { continuation in
            Task { @MainActor in
                var sessions: [DocumentSession] = []
                for relative in paths {
                    guard let session = workspace.documents[root + "/" + relative] else { continue }
                    sessions.append(session)
                }
                guard !sessions.isEmpty else {
                    continuation.resume(returning: true)
                    return
                }
                var remaining = sessions.count
                var allSaved = true
                for session in sessions {
                    workspace.save(session) { saved in
                        if !saved { allSaved = false }
                        remaining -= 1
                        if remaining == 0 { continuation.resume(returning: allSaved) }
                    }
                }
            }
        }
    }
}

struct GopilotTestTargetBackend: TestTargetBackend {
    let access: GopilotWorkspaceAccess
    let workspace: WorkspaceState

    func targets(in packageScope: String) async -> BackendOutcome<[GopilotTools.TestTarget]> {
        let root = access.root
        let scope = packageScope.trimmingCharacters(in: .whitespaces)
        return await Task.detached(priority: .utility) {
            var directories: [String: [String]] = [:]
            let enumerator = FileManager.default.enumerator(at: URL(fileURLWithPath: root), includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
            var visited = 0
            while let url = enumerator?.nextObject() as? URL, visited < 6000 {
                if GopilotWorkspaceAccess.skippedDirectories.contains(url.lastPathComponent) {
                    enumerator?.skipDescendants()
                    continue
                }
                guard url.lastPathComponent.hasSuffix("_test.go") else { continue }
                visited += 1
                directories[url.deletingLastPathComponent().resolvingSymlinksInPath().path, default: []].append(url.path)
            }
            var result: [GopilotTools.TestTarget] = []
            for directory in directories.keys.sorted() {
                let relativeDirectory = Self.relativeComponents(of: directory, from: root)?.joined(separator: "/") ?? ""
                let module = Self.moduleDirectory(forDirectory: directory, root: root)
                let package = Self.packageSelector(directory: directory, moduleDirectory: module)
                if !Self.matches(scope: scope, relativeDirectory: relativeDirectory, importPath: package) { continue }
                let moduleRelative = Self.relativeComponents(of: module, from: root)?.joined(separator: "/") ?? ""
                var tests: [String] = []
                var benchmarks: [String] = []
                for file in directories[directory, default: []].sorted() {
                    guard let text = try? String(contentsOfFile: file, encoding: .utf8) else { continue }
                    tests.append(contentsOf: Self.names(pattern: #"^func (Test[A-Za-z0-9_]*)\(t \*testing\.T\)"#, in: text))
                    benchmarks.append(contentsOf: Self.names(pattern: #"^func (Benchmark[A-Za-z0-9_]*)\(b \*testing\.B\)"#, in: text))
                }
                for name in Set(tests).sorted() {
                    result.append(GopilotTools.TestTarget(package: package, name: name, kind: .test, moduleDirectory: moduleRelative))
                }
                for name in Set(benchmarks).sorted() {
                    result.append(GopilotTools.TestTarget(package: package, name: name, kind: .benchmark, moduleDirectory: moduleRelative))
                }
            }
            return result.isEmpty ? .empty : .found(result)
        }.value
    }

    static func matches(scope: String, relativeDirectory: String, importPath: String) -> Bool {
        if scope.isEmpty || scope == "./..." || scope == "..." { return true }
        if scope == "." || scope == "./" { return relativeDirectory.isEmpty }
        let normalized = scope.hasPrefix("./") ? String(scope.dropFirst(2)) : scope
        if normalized.hasSuffix("/...") {
            let prefix = String(normalized.dropLast(4))
            return relativeDirectory == prefix || relativeDirectory.hasPrefix(prefix + "/") || importPath == prefix || importPath.hasPrefix(prefix + "/")
        }
        return normalized == relativeDirectory || normalized == importPath
    }

    static func relativeComponents(of path: String, from base: String) -> [String]? {
        let target = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let origin = URL(fileURLWithPath: base).resolvingSymlinksInPath().standardizedFileURL.pathComponents
        guard target.count >= origin.count, Array(target.prefix(origin.count)) == origin else { return nil }
        return Array(target.dropFirst(origin.count))
    }

    static func moduleDirectory(forDirectory directory: String, root: String) -> String {
        var current = URL(fileURLWithPath: directory).resolvingSymlinksInPath().standardizedFileURL.path
        let canonicalRoot = URL(fileURLWithPath: root).resolvingSymlinksInPath().standardizedFileURL.path
        while relativeComponents(of: current, from: canonicalRoot) != nil {
            if FileManager.default.fileExists(atPath: current + "/go.mod") { return current }
            if current == canonicalRoot { break }
            current = (current as NSString).deletingLastPathComponent
        }
        return canonicalRoot
    }

    static func packageSelector(directory: String, moduleDirectory: String) -> String {
        let modulePath = GopilotWorkspaceAccess.goModInfo(root: moduleDirectory).module
        let relative = relativeComponents(of: directory, from: moduleDirectory)?.joined(separator: "/") ?? ""
        guard let modulePath, !modulePath.isEmpty else { return relative.isEmpty ? "." : "./" + relative }
        return relative.isEmpty ? modulePath : modulePath + "/" + relative
    }

    static func names(pattern: String, in text: String) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { return [] }
        return expression.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length)).map {
            (text as NSString).substring(with: $0.range(at: 1))
        }
    }
}

struct GopilotFingerprintBackend: SourceFingerprintProvider {
    let access: GopilotWorkspaceAccess

    func diskHashes(moduleDirectory: String, package: String) async -> [String: String] {
        let base = moduleDirectory.isEmpty ? access.root : access.root + "/" + moduleDirectory
        return await Task.detached(priority: .utility) {
            var hashes: [String: String] = [:]
            let enumerator = FileManager.default.enumerator(at: URL(fileURLWithPath: base), includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
            var visited = 0
            while let url = enumerator?.nextObject() as? URL, visited < 3000 {
                if GopilotWorkspaceAccess.skippedDirectories.contains(url.lastPathComponent) {
                    enumerator?.skipDescendants()
                    continue
                }
                let name = url.lastPathComponent
                guard name.hasSuffix(".go") || name == "go.mod" || name == "go.sum" else { continue }
                visited += 1
                guard let data = try? Data(contentsOf: url) else { continue }
                hashes[String(url.path.dropFirst(base.count + 1))] = ContentHash.sha256Hex(data)
            }
            return hashes
        }.value
    }
}

enum GopilotTrust {
    private static let key = "GoLensGopilotTrustedProjects"

    static func isTrusted(_ path: String, defaults: UserDefaults = .standard) -> Bool {
        (defaults.stringArray(forKey: key) ?? []).contains(path)
    }

    static func set(_ trusted: Bool, path: String, defaults: UserDefaults = .standard) {
        var list = defaults.stringArray(forKey: key) ?? []
        list.removeAll { $0 == path }
        if trusted { list.append(path) }
        defaults.set(list, forKey: key)
    }

    static func removeAll(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key)
    }
}

final class GopilotProfileSampleCache: @unchecked Sendable {
    private let lock = NSLock()
    private var cache: [String: [String]] = [:]

    func types(for path: String) -> [String]? { lock.withLock { cache[path] } }
    func store(_ types: [String], for path: String) { lock.withLock { cache[path] = types } }
}

struct GopilotProfileBridge: ProfileSource {
    let paths: @Sendable () async -> [String]
    private let samples = GopilotProfileSampleCache()

    init(paths: @escaping @Sendable () async -> [String]) {
        self.paths = paths
    }

    func attachedProfiles() async -> [AttachedProfileInfo] {
        var result: [AttachedProfileInfo] = []
        for path in await paths() {
            let modified = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? Date()
            let name = (path as NSString).lastPathComponent
            let variants = await heapVariants(path)
            if variants.isEmpty {
                result.append(AttachedProfileInfo(sourceKey: path, label: name, capturedAt: modified))
            } else {
                for variant in variants {
                    result.append(AttachedProfileInfo(sourceKey: path + "|" + variant, label: "\(name) (\(variant))", capturedAt: modified))
                }
            }
        }
        return result
    }

    func payload(sourceKey: String) async -> ProfileDetailPayload? {
        let parts = sourceKey.split(separator: "|", maxSplits: 1).map(String.init)
        return await load(path: parts[0], sampleType: parts.count > 1 ? parts[1] : "")
    }

    private func heapVariants(_ path: String) async -> [String] {
        if let known = samples.types(for: path) { return known }
        guard let detail = await load(path: path, sampleType: "") else { return [] }
        let names = Set(detail.sampleTypes.map(\.type))
        let variants = ["alloc_space", "inuse_space"].filter { names.contains($0) }
        samples.store(variants.count == 2 ? variants : [], for: path)
        return variants.count == 2 ? variants : []
    }

    private func load(path: String, sampleType: String) async -> ProfileDetailPayload? {
        await Task.detached(priority: .utility) {
            let json: String? = path.withCString { cPath in
                sampleType.withCString { cSample in
                    guard let pointer = ParseGoProfileDetailed(cPath, cSample) else { return nil }
                    defer { FreeGoCString(pointer) }
                    return String(cString: pointer)
                }
            }
            guard let json, !json.hasPrefix("{\"error\""), let data = json.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(ProfileDetailPayload.self, from: data)
        }.value
    }
}
