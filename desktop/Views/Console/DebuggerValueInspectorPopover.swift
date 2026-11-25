import SwiftUI
import AppKit

struct VariablePayloadInspectionData: Decodable {
    let type: String
    let length: Int
    let text: String
    let json: String?
    let hexDump: String
    let truncated: Bool
}

func inspectVariablePayload(type: String, value: String) -> VariablePayloadInspectionData {
    guard let cType = type.cString(using: .utf8),
          let cVal = value.cString(using: .utf8) else {
        return VariablePayloadInspectionData(type: type, length: 0, text: value, json: nil, hexDump: "", truncated: false)
    }
    guard let ptr = InspectRawVariablePayload(cType, cVal) else {
        return VariablePayloadInspectionData(type: type, length: 0, text: value, json: nil, hexDump: "", truncated: false)
    }
    defer { FreeGoCString(ptr) }
    let jsonStr = String(cString: ptr)
    let data = Data(jsonStr.utf8)
    if let parsed = try? JSONDecoder().decode(VariablePayloadInspectionData.self, from: data) {
        return parsed
    }
    return VariablePayloadInspectionData(type: type, length: 0, text: value, json: nil, hexDump: "", truncated: false)
}

struct DebuggerValueInspectorPopover: View {
    let varName: String
    let varType: String
    let varValue: String
    let onClose: () -> Void

    enum Tab: String, CaseIterable {
        case formattedJSON = "Formatted JSON"
        case utf8Text = "UTF-8 Text"
        case hexDump = "Hex Dump"
    }

    @State private var selectedTab: Tab = .formattedJSON
    @State private var inspection: VariablePayloadInspectionData?
    @State private var copied: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Spacing.standard) {
                VStack(alignment: .leading, spacing: Spacing.hairline) {
                    HStack(spacing: Spacing.row) {
                        Text(varName)
                            .font(.body.weight(.semibold).monospaced())
                            .foregroundStyle(Color.primary)

                        Text(varType.isEmpty ? "unknown" : varType)
                            .font(.subheadline.monospaced())
                            .foregroundStyle(Color.secondary)

                        if let insp = inspection {
                            Text("\(insp.length) bytes")
                                .font(.caption.weight(.medium))
                                .padding(.horizontal, Spacing.row)
                                .padding(.vertical, Spacing.hairline)
                                .background(
                                    Capsule()
                                        .fill(Color.secondary.opacity(0.15))
                                )
                                .foregroundStyle(Color.secondary)
                        }
                    }
                }

                Spacer()

                Button {
                    copyCurrentContent()
                } label: {
                    HStack(spacing: Spacing.compact) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        Text(copied ? "Copied" : "Copy")
                    }
                    .font(.subheadline)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.body)
                        .foregroundStyle(Color.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close inspector")
                .help("Close inspector")
            }
            .padding(.horizontal, Spacing.comfortable)
            .padding(.top, Spacing.comfortable)
            .padding(.bottom, Spacing.standard)

            Picker("", selection: $selectedTab) {
                ForEach(availableTabs, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, Spacing.comfortable)
            .padding(.bottom, Spacing.standard)

            Divider()

            ScrollView([.horizontal, .vertical]) {
                Text(currentDisplayText)
                    .font(.callout.monospaced())
                    .foregroundStyle(Color.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(Spacing.comfortable)
            }
            .sheetFrame(.valueInspectorContent)
            .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
        }
        .sheetFrame(.valueInspector)
        .onAppear {
            let res = inspectVariablePayload(type: varType, value: varValue)
            inspection = res
            if res.json == nil || res.json?.isEmpty == true {
                selectedTab = .utf8Text
            }
        }
    }

    private var availableTabs: [Tab] {
        if let json = inspection?.json, !json.isEmpty {
            return Tab.allCases
        }
        return [.utf8Text, .hexDump]
    }

    private var currentDisplayText: String {
        guard let insp = inspection else { return varValue }
        switch selectedTab {
        case .formattedJSON:
            return insp.json ?? insp.text
        case .utf8Text:
            return insp.text.isEmpty ? "(empty string)" : insp.text
        case .hexDump:
            return insp.hexDump.isEmpty ? "(empty)" : insp.hexDump
        }
    }

    private func copyCurrentContent() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(currentDisplayText, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            copied = false
        }
    }
}
