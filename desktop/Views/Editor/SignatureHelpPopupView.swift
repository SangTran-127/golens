import SwiftUI
import GoLensFoundation

struct SignatureHelpPopupView: View {
    let helpData: SignatureHelpData
    @Environment(\.windowWorkspace) private var workspace
    
    var body: some View {
        let sig = helpData.signatures.indices.contains(helpData.activeSignature) ? helpData.signatures[helpData.activeSignature] : nil
        let doc = sig?.documentation?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let needsWrapWidth = !doc.isEmpty || (sig?.label.count ?? 0) > 45

        VStack(alignment: .leading, spacing: Spacing.compact) {
            if let sig {
                Text(formatSignature(sig, activeParam: helpData.activeParameter))
                    .font(.subheadline.monospaced())
                    .foregroundStyle(ThemeColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                
                if !doc.isEmpty {
                    Divider().padding(.vertical, Spacing.hairline)
                    let formattedDoc = doc.components(separatedBy: "\n\n")
                        .map { $0.replacingOccurrences(of: "\n", with: " ") }
                        .joined(separator: "\n\n")
                    Text((try? AttributedString(markdown: formattedDoc, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(formattedDoc))
                        .font(.subheadline)
                        .foregroundStyle(ThemeColor.textSecondary)
                        .lineLimit(6)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(width: needsWrapWidth ? 360 : nil, alignment: .leading)
        .frame(maxWidth: 380, alignment: .leading)
        .padding(Spacing.standard)
        .floatingPanelBackground(cornerRadius: CornerRadius.compactPanel)
    }
    
    private func formatSignature(_ sig: SignatureHelpData.Signature, activeParam: Int) -> AttributedString {
        var attrStr = AttributedString(sig.label)
        let specs = sig.parameters.map {
            SignatureParameterHighlighter.ParameterSpec(label: $0.label, utf16Range: $0.labelRange)
        }
        guard let utf16Range = SignatureParameterHighlighter.activeUTF16Range(
            signatureLabel: sig.label,
            parameters: specs,
            activeParameter: activeParam
        ) else {
            return attrStr
        }

        let utf16 = sig.label.utf16
        guard utf16Range.lowerBound >= 0,
              utf16Range.upperBound <= utf16.count,
              let startStrIdx = String.Index(utf16.index(utf16.startIndex, offsetBy: utf16Range.lowerBound), within: sig.label),
              let endStrIdx = String.Index(utf16.index(utf16.startIndex, offsetBy: utf16Range.upperBound), within: sig.label),
              let attrStart = AttributedString.Index(startStrIdx, within: attrStr),
              let attrEnd = AttributedString.Index(endStrIdx, within: attrStr),
              attrStart < attrEnd else {
            return attrStr
        }

        attrStr[attrStart..<attrEnd].font = .subheadline.weight(.bold).monospaced()
        attrStr[attrStart..<attrEnd].foregroundColor = ThemeColor.accent
        return attrStr
    }
}
