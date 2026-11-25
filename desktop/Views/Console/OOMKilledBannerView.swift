import SwiftUI

struct OOMKilledBannerView: View {
    @Bindable var workspace: WorkspaceState
    let memoryLimit: String
    var onDismiss: (() -> Void)? = nil

    var body: some View {
        InlineBanner(
            .status(.warning),
            title: "Process Killed by Linux OOM Killer",
            message: "The program exceeded the Memory Limit of \(memoryLimit) and was terminated by the Linux kernel.",
            onClose: {
                if let onDismiss { onDismiss() } else { workspace.dismissOOMBanner() }
            }
        ) {
            Button("Increase Memory Limit…") {
                workspace.increaseMemoryLimitRecovery()
            }
            .help("Open Run Configurations to raise or remove the memory limit")
            Button("Profile Heap") {
                workspace.profileHeapRecovery()
            }
            .help("Run memory profiler to find allocating functions and objects")
        }
    }
}
