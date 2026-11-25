import Foundation
import GopilotRuntime
import GopilotPolicy

public struct ExecutionCatalogEntry: Sendable, Equatable {
    public enum Backend: String, Sendable {
        case memory
        case targets
        case runner
        case profiles
        case patch
    }

    public let name: String
    public let wave: GopilotWave
    public let backend: Backend
}

public enum ExecutionToolSet {
    static let patchArgumentBytes = ToolArgumentLimits.maxPatchArgumentBytes

    public static let catalog: [ExecutionCatalogEntry] = [
        ExecutionCatalogEntry(name: "read_memory", wave: .w4, backend: .memory),
        ExecutionCatalogEntry(name: "list_test_targets", wave: .w5, backend: .targets),
        ExecutionCatalogEntry(name: "run_tests", wave: .w5, backend: .runner),
        ExecutionCatalogEntry(name: "run_benchmark", wave: .w5, backend: .runner),
        ExecutionCatalogEntry(name: "read_run_result", wave: .w5, backend: .runner),
        ExecutionCatalogEntry(name: "list_profiles", wave: .w6, backend: .profiles),
        ExecutionCatalogEntry(name: "profile_hotspots", wave: .w6, backend: .profiles),
        ExecutionCatalogEntry(name: "profile_frame", wave: .w6, backend: .profiles),
        ExecutionCatalogEntry(name: "compare_benchmarks", wave: .w6, backend: .runner),
        ExecutionCatalogEntry(name: "propose_patch", wave: .w7, backend: .patch)
    ]

    public static func enabledNames(wave: GopilotWave, backends: ExecutionBackends? = nil) -> [String] {
        catalog.filter { entry in
            guard entry.wave <= wave else { return false }
            guard let backends else { return true }
            switch entry.backend {
            case .memory: return backends.memory != nil
            case .targets: return backends.testTargets != nil
            case .runner: return backends.canRun
            case .profiles: return backends.profiles != nil
            case .patch: return backends.patch != nil
            }
        }.map(\.name)
    }

    public static func makeTools(context: ExecutionToolContext, wave: GopilotWave) throws -> [GopilotTool] {
        let kit = ExecutionKit(context: context)
        let all: [String: ExecTool] = [
            "read_memory": kit.readMemory(),
            "list_test_targets": kit.listTestTargets(),
            "run_tests": kit.runTests(),
            "run_benchmark": kit.runBenchmark(),
            "read_run_result": kit.readRunResult(),
            "list_profiles": kit.listProfiles(),
            "profile_hotspots": kit.profileHotspots(),
            "profile_frame": kit.profileFrame(),
            "compare_benchmarks": kit.compareBenchmarks(),
            "propose_patch": kit.proposePatch()
        ]
        return try enabledNames(wave: wave, backends: context.backends).compactMap { all[$0] }.map { tool in
            try ValidatedTool(tool, maxArgumentBytes: tool.schema.name == "propose_patch" ? patchArgumentBytes : ValidatedTool.defaultMaxArgumentBytes)
        }
    }

    public static func makeAgentTools(
        context: ExecutionToolContext,
        wave: GopilotWave,
        includeMemoryWrite: Bool = true,
        includeAgentPatch: Bool = true
    ) throws -> [GopilotTool] {
        let kit = ExecutionKit(context: context)
        var extras: [ExecTool] = []
        if includeMemoryWrite, wave >= .w4, context.backends.memory != nil {
            extras.append(kit.saveMemory())
        }
        if includeAgentPatch, wave >= .w7, context.backends.patch != nil {
            extras.append(kit.writeFile())
            extras.append(kit.editFile())
            extras.append(kit.todoWrite())
            if context.backends.canRun {
                extras.append(kit.runGoCheck())
            }
        }
        return try extras.map { tool in
            let isPatchTool = tool.schema.name == "write_file" || tool.schema.name == "edit_file"
            return try ValidatedTool(tool, maxArgumentBytes: isPatchTool ? patchArgumentBytes : ValidatedTool.defaultMaxArgumentBytes)
        }
    }

    public static func makeRegistry(context: ExecutionToolContext, wave: GopilotWave) throws -> ToolRegistry {
        ToolRegistry(try makeTools(context: context, wave: wave))
    }

    public static func combinedRegistry(
        readContext: ReadToolContext,
        executionContext: ExecutionToolContext,
        wave: GopilotWave,
        projectContextEnabled: Bool = true,
        includeMemoryWrite: Bool = false,
        includeAgentPatch: Bool = false
    ) throws -> ToolRegistry {
        let reads = try ToolSet.makeTools(context: readContext, wave: wave, projectContextEnabled: projectContextEnabled)
        let executions = projectContextEnabled ? try makeTools(context: executionContext, wave: wave) : []
        let agentExtras = projectContextEnabled
            ? try makeAgentTools(context: executionContext, wave: wave, includeMemoryWrite: includeMemoryWrite, includeAgentPatch: includeAgentPatch)
            : []
        return ToolRegistry(reads + executions + agentExtras)
    }
}
