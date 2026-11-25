import SwiftUI

enum CellValuePopoverMetrics {
    static let width: CGFloat = 540
    static let height: CGFloat = 380
}

struct CellValuePopover: View {
    let cache: ResultPageCache
    let cell: DataGridCellRef
    var pending: DBPendingValue? = nil
    @Environment(\.dataGridDismissDetail) private var dismiss

    private enum Phase {
        case loading
        case value(DBCellValueResponse)
        case failed(DBError)
    }

    @State private var phase: Phase = .loading

    private var column: DBColumn? {
        cache.columns.indices.contains(cell.column) ? cache.columns[cell.column] : nil
    }

    var body: some View {
        content
            .task(id: cell) { load() }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            UnifiedEmptyState.loading(message: "Reading the value…")
                .frame(width: CellValuePopoverMetrics.width, height: CellValuePopoverMetrics.height)
        case .failed(let error):
            UnifiedEmptyState.failed(title: "Couldn’t Read the Value", message: error.message, onRetry: load)
                .frame(width: CellValuePopoverMetrics.width, height: CellValuePopoverMetrics.height)
        case .value(let value) where value.isNull:
            UnifiedEmptyState.empty(
                symbol: "circle.slash",
                title: "NULL",
                message: "“\(column?.name ?? "This column")” has no value in row \(UserMessage.integer(cell.row + 1))."
            )
            .frame(width: CellValuePopoverMetrics.width, height: CellValuePopoverMetrics.height)
        case .value(let value):
            VStack(spacing: 0) {
                if value.truncated {
                    InlineBanner(
                        .symbol("info.circle"),
                        title: "Showing the First \(UserMessage.byteCount(Int64(ResultPageCache.viewerMaxBytes)))",
                        message: "The value is \(UserMessage.byteCount(value.byteCount)). Copy Value copies all of it."
                    )
                }
                DebuggerValueInspectorPopover(
                    varName: column?.name ?? "",
                    varType: column?.dbType ?? value.kind,
                    varValue: Self.inspectorPayload(value),
                    onClose: { dismiss() }
                )
            }
        }
    }

    private func load() {
        if let pending {
            phase = .value(DBCellValueResponse(isNull: pending.isNull, kind: column?.kind ?? "text", text: pending.text, encoding: "", byteCount: Int64(pending.text.utf8.count), truncated: false, error: nil))
            return
        }
        phase = .loading
        cache.cellValue(row: cell.row, column: cell.column) { result in
            switch result {
            case .success(let value): phase = .value(value)
            case .failure(let error): phase = .failed(error)
            }
        }
    }

    static func inspectorPayload(_ value: DBCellValueResponse) -> String {
        if value.isHex {
            var bytes: [String] = []
            bytes.reserveCapacity(value.text.utf8.count / 2)
            var high: UInt8?
            for unit in value.text.utf8 {
                guard let nibble = hexNibble(unit) else { continue }
                if let h = high {
                    bytes.append(String(h << 4 | nibble))
                    high = nil
                } else {
                    high = nibble
                }
            }
            return "[" + bytes.joined(separator: ",") + "]"
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard let data = try? encoder.encode(value.text) else { return value.text }
        return String(decoding: data, as: UTF8.self)
    }

    private static func hexNibble(_ unit: UInt8) -> UInt8? {
        switch unit {
        case 0x30...0x39: unit - 0x30
        case 0x61...0x66: unit - 0x61 + 10
        case 0x41...0x46: unit - 0x41 + 10
        default: nil
        }
    }
}
