import SwiftUI

struct GitRevisionRow: View {
    let subject: String
    let author: String
    let date: Date?
    let relativeDateText: String?
    let shortHash: String
    var refs: [String] = []
    var renamedFrom: String? = nil
    var customAccessibilityLabel: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.hairline) {
            HStack(alignment: .top, spacing: Spacing.row) {
                Text(subject.isEmpty ? "(no message)" : subject)
                    .font(.callout)
                    .lineLimit(2)
                    .truncationMode(.tail)
                if !refs.isEmpty {
                    Spacer(minLength: Spacing.compact)
                    HStack(spacing: Spacing.compact) {
                        ForEach(refs.prefix(2), id: \.self) { ref in
                            Text(ref.replacingOccurrences(of: "HEAD -> ", with: "").replacingOccurrences(of: "tag: ", with: ""))
                                .font(.caption2.weight(.medium))
                                .lineLimit(1)
                                .padding(.horizontal, Spacing.row)
                                .padding(.vertical, Spacing.hairline)
                                .background(Color(nsColor: .quaternarySystemFill), in: Capsule())
                        }
                    }
                    .fixedSize(horizontal: true, vertical: false)
                }
            }
            HStack(spacing: Spacing.row) {
                Text(author)
                    .lineLimit(1)
                if let relativeDateText {
                    Text("·")
                    Text(relativeDateText)
                        .lineLimit(1)
                } else if let date {
                    Text(date, format: .relative(presentation: .named))
                        .lineLimit(1)
                }
                Spacer(minLength: Spacing.compact)
                Text(shortHash)
                    .font(.caption.monospaced())
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if let renamedFrom, !renamedFrom.isEmpty {
                Label("Renamed from \((renamedFrom as NSString).lastPathComponent)", systemImage: "arrow.right.doc.on.clipboard")
                    .labelStyle(.titleAndIcon)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help("Renamed from \(renamedFrom)")
            }
        }
        .padding(.vertical, Spacing.hairline)
        .help(date?.formatted(date: .abbreviated, time: .shortened) ?? "")
        .accessibilityElement(children: customAccessibilityLabel == nil ? .combine : .ignore)
        .modifier(OptionalRevisionAccessibilityLabel(label: customAccessibilityLabel))
    }
}

private struct OptionalRevisionAccessibilityLabel: ViewModifier {
    let label: String?

    func body(content: Content) -> some View {
        if let label {
            content.accessibilityLabel(label)
        } else {
            content
        }
    }
}
