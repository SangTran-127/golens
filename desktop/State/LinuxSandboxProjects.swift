import Foundation
import GoLensFoundation
import Observation

@MainActor
@Observable
final class LinuxSandboxProjects {
    static let shared = LinuxSandboxProjects()
    static let projectsKey = "GoLensLinuxSandboxProjects"

    private(set) var paths: Set<String>

    private init() {
        let defaults = UserDefaults.standard
        var stored = Set(defaults.stringArray(forKey: Self.projectsKey) ?? [])
        if defaults.string(forKey: SandboxVMManager.executionModeKey) == SandboxVMManager.ExecutionMode.linuxVM.rawValue,
           let last = defaults.string(forKey: "GoLensLastWorkspacePath"), !last.isEmpty {
            stored.insert(WorkspacePathCanonicalizer.canonical(last))
            defaults.set(Array(stored).sorted(), forKey: Self.projectsKey)
        }
        defaults.removeObject(forKey: SandboxVMManager.executionModeKey)
        paths = stored
    }

    private var modeIsForced: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["GOLENS_EXECUTION_MODE"] != nil
            || environment["GOLENS_TEST_VSOCK_PATH"] != nil
            || environment["GOLENS_VERIFY_VM_PAUSE_RESUME"] != nil
    }

    func isEnabled(for workspacePath: String) -> Bool {
        !workspacePath.isEmpty && paths.contains(WorkspacePathCanonicalizer.canonical(workspacePath))
    }

    func setEnabled(_ enabled: Bool, for workspacePath: String) {
        guard !workspacePath.isEmpty else { return }
        let canonical = WorkspacePathCanonicalizer.canonical(workspacePath)
        if enabled { paths.insert(canonical) } else { paths.remove(canonical) }
        UserDefaults.standard.set(Array(paths).sorted(), forKey: Self.projectsKey)
        applyExecutionMode()
    }

    func applyExecutionMode() {
        guard !modeIsForced else { return }
        let openProjects = WorkspaceState.allRegisteredWorkspaces().map(\.activeWorkspacePath)
        let wantsSandbox = LinuxRuntimeInstaller.shared.isInstalled && openProjects.contains { isEnabled(for: $0) }
        SandboxVMManager.shared.setExecutionMode(wantsSandbox ? .linuxVM : .host)
    }

    func runtimeRemoved() {
        guard !modeIsForced else { return }
        SandboxVMManager.shared.setExecutionMode(.host)
    }
}
