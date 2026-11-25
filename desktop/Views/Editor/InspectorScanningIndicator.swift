import SwiftUI

struct InspectorScanningIndicator: View {
    let isScanning: Bool
    var label: String = "Scanning…"

    var body: some View {
        if isScanning {
            HStack(spacing: Spacing.row) {
                ProgressView()
                    .controlSize(.small)
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .fixedSize()
            .accessibilityElement(children: .combine)
            .accessibilityLabel(label)
        }
    }
}

extension View {
    func staleWhileScanning(_ isScanning: Bool) -> some View {
        opacity(isScanning ? 0.5 : 1)
            .accessibilityHint(isScanning ? "Showing previous results while scanning" : "")
    }
}

extension BackgroundFFI {
    static func isScanning(_ key: AnyHashable) -> Bool {
        shared.isPending(key)
    }
}
