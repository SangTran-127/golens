import SwiftUI
import AppKit

struct HTTPExecutionResultDTO: Decodable {
    let statusCode: Int
    let durationMs: Int64
    let headers: [String: String]
    let body: String
}

struct HeaderFieldItem: Identifiable, Equatable {
    let id = UUID()
    var key: String
    var value: String
    var isEnabled: Bool = true
}

enum HTTPResponseTab: String, CaseIterable, Identifiable {
    case body = "Body"
    case headers = "Headers"

    var id: String { rawValue }
}

enum HTTPRequestTab: String, CaseIterable, Identifiable {
    case params = "Parameters"
    case headers = "Headers"
    case body = "Body"

    var id: String { rawValue }
}

struct HTTPRouteExerciserPopoverView: View {
    let method: String
    let routePath: String
    let pathParams: [String]
    let initialBody: String
    let onClose: () -> Void

    @State private var baseURL: String = "http://localhost:8080"
    @State private var paramValues: [String: String] = [:]
    @State private var headers: [HeaderFieldItem] = [
        HeaderFieldItem(key: "Content-Type", value: "application/json"),
        HeaderFieldItem(key: "Accept", value: "application/json")
    ]
    @State private var requestBody: String = ""
    @State private var requestTab: HTTPRequestTab = .params
    @State private var responseTab: HTTPResponseTab = .body
    @State private var isLoading: Bool = false
    @State private var responseResult: HTTPExecutionResultDTO?
    @State private var errorMessage: String?
    @State private var copiedBodyAlert: Bool = false
    @State private var timeoutSeconds: Int = 10

    init(method: String, routePath: String, pathParams: [String] = [], initialBody: String = "", onClose: @escaping () -> Void) {
        self.method = method.uppercased()
        self.routePath = routePath
        self.pathParams = pathParams
        self.initialBody = initialBody
        self.onClose = onClose

        var initialParams: [String: String] = [:]
        for p in pathParams {
            initialParams[p] = ""
        }
        _paramValues = State(initialValue: initialParams)
        _requestBody = State(initialValue: initialBody)
        if pathParams.isEmpty && !initialBody.isEmpty {
            _requestTab = State(initialValue: .body)
        } else if pathParams.isEmpty {
            _requestTab = State(initialValue: .headers)
        }
    }

    var effectiveURL: String {
        var path = routePath
        for (param, val) in paramValues {
            let trimmed = val.trimmingCharacters(in: .whitespacesAndNewlines)
            let replacement = trimmed.isEmpty ? "{\(param)}" : trimmed
            path = path.replacingOccurrences(of: "{\(param)}", with: replacement)
            path = path.replacingOccurrences(of: "{\(param)...}", with: replacement)
            path = path.replacingOccurrences(of: ":\(param)", with: replacement)
            path = path.replacingOccurrences(of: "*\(param)", with: replacement)
        }
        let base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let cleanPath = path.hasPrefix("/") ? path : "/" + path
        return base + cleanPath
    }

    var methodColor: Color {
        switch method {
        case "GET":
            return .blue
        case "POST":
            return StatusTone.success.tint
        case "PUT":
            return StatusTone.warning.tint
        case "DELETE":
            return StatusTone.failure.tint
        case "PATCH":
            return .purple
        default:
            return .secondary
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
                .padding(.horizontal, Spacing.section)
                .padding(.top, Spacing.comfortable)
                .padding(.bottom, Spacing.inset)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.comfortable) {
                    urlConfigCard

                    requestTabsSection

                    actionButtonRow

                    responseSection
                }
                .padding(Spacing.section)
            }
        }
        .sheetFrame(.httpExerciser)
    }

    private var headerBar: some View {
        HStack(spacing: Spacing.inset) {
            Text(method)
                .font(.subheadline.weight(.bold).monospaced())
                .foregroundStyle(methodColor)
                .padding(.horizontal, Spacing.row)
                .padding(.vertical, Spacing.compact)
                .background(ThemeColor.tintFill(methodColor))
                .clipShape(RoundedRectangle(cornerRadius: CornerRadius.small, style: .continuous))

            Text(routePath)
                .font(.body.weight(.semibold).monospaced())
                .foregroundStyle(Color(nsColor: .labelColor))
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            Button {
                onClose()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.body)
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
            .help("Close")
            .keyboardShortcut(.cancelAction)
        }
    }

    private var urlConfigCard: some View {
        VStack(alignment: .leading, spacing: Spacing.standard) {
            HStack(spacing: Spacing.standard) {
                Text("Base URL:")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                    .frame(width: 65, alignment: .leading)

                TextField("http://localhost:8080", text: $baseURL)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout.monospaced())
            }

            HStack(spacing: Spacing.standard) {
                Text("Target:")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                    .frame(width: 65, alignment: .leading)

                Text(effectiveURL)
                    .font(.subheadline.monospaced())
                    .foregroundStyle(Color(nsColor: .labelColor))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .padding(.horizontal, Spacing.standard)
                    .padding(.vertical, Spacing.compact)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.small, style: .continuous))

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(effectiveURL, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.subheadline)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Copy URL")
                .help("Copy effective URL to clipboard")
            }
        }
        .padding(Spacing.inset)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.panelRow, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: CornerRadius.panelRow, style: .continuous).stroke(Color(nsColor: .separatorColor), lineWidth: Stroke.hairline))
    }

    private var requestTabsSection: some View {
        VStack(alignment: .leading, spacing: Spacing.standard) {
            Picker("Section", selection: $requestTab) {
                if !pathParams.isEmpty {
                    Text("Params (\(pathParams.count))").tag(HTTPRequestTab.params)
                }
                Text("Headers (\(headers.filter { $0.isEnabled }.count))").tag(HTTPRequestTab.headers)
                Text("Body").tag(HTTPRequestTab.body)
            }
            .pickerStyle(.segmented)

            switch requestTab {
            case .params:
                paramsEditor
            case .headers:
                headersEditor
            case .body:
                bodyEditor
            }
        }
    }

    private var paramsEditor: some View {
        VStack(spacing: Spacing.row) {
            if pathParams.isEmpty {
                Text("No path parameters detected in route")
                    .font(.subheadline)
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(Spacing.standard)
            } else {
                ForEach(pathParams, id: \.self) { param in
                    HStack(spacing: Spacing.standard) {
                        Text(param)
                            .font(.subheadline.weight(.bold).monospaced())
                            .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                            .frame(width: 90, alignment: .leading)

                        TextField("value for \(param)", text: Binding(
                            get: { paramValues[param] ?? "" },
                            set: { paramValues[param] = $0 }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .font(.subheadline.monospaced())
                    }
                }
            }
        }
        .padding(Spacing.standard)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.panelRow, style: .continuous))
    }

    private var headersEditor: some View {
        VStack(alignment: .leading, spacing: Spacing.row) {
            ForEach($headers) { $item in
                HStack(spacing: Spacing.row) {
                    Toggle("", isOn: $item.isEnabled)
                        .labelsHidden()
                        .toggleStyle(.checkbox)

                    TextField("Header", text: $item.key)
                        .textFieldStyle(.roundedBorder)
                        .font(.subheadline.monospaced())
                        .frame(width: 140)

                    TextField("Value", text: $item.value)
                        .textFieldStyle(.roundedBorder)
                        .font(.subheadline.monospaced())

                    Button {
                        if let idx = headers.firstIndex(where: { $0.id == item.id }) {
                            headers.remove(at: idx)
                        }
                    } label: {
                        Image(systemName: "trash")
                            .font(.caption)
                            .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Delete Header")
                    .help("Delete Header")
                }
            }

            Button {
                headers.append(HeaderFieldItem(key: "", value: ""))
            } label: {
                Label("Add Header", systemImage: "plus")
                    .font(.subheadline)
            }
            .buttonStyle(.plain)
            .padding(.top, Spacing.compact)
        }
        .padding(Spacing.standard)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.panelRow, style: .continuous))
    }

    private var bodyEditor: some View {
        VStack(alignment: .leading, spacing: Spacing.compact) {
            HStack {
                Text("Request Payload (JSON):")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))

                Spacer()

                if !initialBody.isEmpty {
                    Button("Reset Inferred Sample") {
                        requestBody = initialBody
                    }
                    .font(.caption)
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                }
            }

            TextEditor(text: $requestBody)
                .font(.callout.monospaced())
                .frame(height: 90)
                .overlay(RoundedRectangle(cornerRadius: CornerRadius.small).stroke(Color(nsColor: .separatorColor), lineWidth: Stroke.hairline))
        }
    }

    private var actionButtonRow: some View {
        HStack {
            Spacer()

            Button {
                sendRequest()
            } label: {
                HStack(spacing: Spacing.row) {
                    if isLoading {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "paperplane.fill")
                            .font(.subheadline)
                    }
                    Text(isLoading ? "Sending…" : "Send Request (⌘⏎)")
                        .font(.callout.weight(.medium))
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isLoading)
            .keyboardShortcut(.return, modifiers: [.command])
        }
    }

    private var responseSection: some View {
        VStack(alignment: .leading, spacing: Spacing.standard) {
            Divider()

            if let error = errorMessage {
                HStack(alignment: .top, spacing: Spacing.standard) {
                    Image(systemName: StatusTone.warning.symbol)
                        .foregroundStyle(StatusTone.warning.tint)
                        .font(.body)

                    VStack(alignment: .leading, spacing: Spacing.hairline) {
                        Text("Request Failed")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(Color(nsColor: .labelColor))
                        Text(error)
                            .font(.subheadline.monospaced())
                            .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                            .textSelection(.enabled)
                    }
                }
                .padding(Spacing.inset)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(StatusTone.warning.fill)
                .clipShape(RoundedRectangle(cornerRadius: CornerRadius.panelRow, style: .continuous))
            } else if let res = responseResult {
                HStack(spacing: Spacing.standard) {
                    HStack(spacing: Spacing.compact) {
                        Text("\(res.statusCode)")
                            .font(.subheadline.weight(.bold).monospaced())
                        Text(statusText(for: res.statusCode))
                            .font(.subheadline.weight(.medium))
                    }
                    .foregroundStyle(statusColor(for: res.statusCode))
                    .padding(.horizontal, Spacing.row)
                    .padding(.vertical, Spacing.compact)
                    .background(ThemeColor.tintFill(statusColor(for: res.statusCode)))
                    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.small, style: .continuous))

                    HStack(spacing: Spacing.compact) {
                        Image(systemName: "clock")
                            .font(.caption)
                        Text("\(res.durationMs) ms")
                            .font(.subheadline.monospaced())
                    }
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                    .padding(.horizontal, Spacing.row)
                    .padding(.vertical, Spacing.compact)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.small, style: .continuous))

                    HStack(spacing: Spacing.compact) {
                        Image(systemName: "arrow.down.circle")
                            .font(.caption)
                        Text(UserMessage.byteCount(Int64(res.body.utf8.count)))
                            .font(.subheadline.monospaced())
                    }
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                    .padding(.horizontal, Spacing.row)
                    .padding(.vertical, Spacing.compact)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.small, style: .continuous))

                    Spacer()

                    Picker("", selection: $responseTab) {
                        Text("Body").tag(HTTPResponseTab.body)
                        Text("Headers (\(res.headers.count))").tag(HTTPResponseTab.headers)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 160)
                }

                switch responseTab {
                case .body:
                    VStack(alignment: .leading, spacing: Spacing.compact) {
                        HStack {
                            Spacer()
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(res.body, forType: .string)
                                copiedBodyAlert = true
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                    copiedBodyAlert = false
                                }
                            } label: {
                                HStack(spacing: Spacing.compact) {
                                    Image(systemName: copiedBodyAlert ? "checkmark" : "doc.on.doc")
                                    Text(copiedBodyAlert ? "Copied" : "Copy Body")
                                }
                                .font(.caption)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(Color.accentColor)
                            .accessibilityLabel("Copy Body")
                            .help("Copy response body to clipboard")
                        }

                        ScrollView {
                            Text(res.body.isEmpty ? "<Empty Body>" : res.body)
                                .font(.subheadline.monospaced())
                                .foregroundStyle(Color(nsColor: .labelColor))
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                                .textSelection(.enabled)
                                .padding(Spacing.standard)
                        }
                        .frame(maxHeight: 160)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.small, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: CornerRadius.small, style: .continuous).stroke(Color(nsColor: .separatorColor), lineWidth: Stroke.hairline))
                    }

                case .headers:
                    ScrollView {
                        VStack(alignment: .leading, spacing: Spacing.compact) {
                            ForEach(res.headers.sorted(by: { $0.key < $1.key }), id: \.key) { k, v in
                                HStack(alignment: .top, spacing: Spacing.standard) {
                                    Text(k + ":")
                                        .font(.caption.weight(.bold).monospaced())
                                        .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                                        .frame(width: 140, alignment: .leading)
                                    Text(v)
                                        .font(.caption.monospaced())
                                        .foregroundStyle(Color(nsColor: .labelColor))
                                        .textSelection(.enabled)
                                    Spacer()
                                }
                                Divider()
                            }
                        }
                        .padding(Spacing.standard)
                    }
                    .frame(maxHeight: 160)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.small, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: CornerRadius.small, style: .continuous).stroke(Color(nsColor: .separatorColor), lineWidth: Stroke.hairline))
                }
            } else if !isLoading {
                HStack(spacing: Spacing.standard) {
                    Image(systemName: "network")
                        .font(.body)
                        .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                    Text("Hit Send Request or press ⌘⏎ to execute route against local server.")
                        .font(.subheadline)
                        .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                }
                .padding(.vertical, Spacing.standard)
            }
        }
    }

    private func sendRequest() {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil

        let urlStr = effectiveURL
        let methodStr = method
        var headersDict: [String: String] = [:]
        for item in headers where item.isEnabled && !item.key.trimmingCharacters(in: .whitespaces).isEmpty {
            headersDict[item.key.trimmingCharacters(in: .whitespaces)] = item.value
        }
        let bodyStr = requestBody
        let timeout = timeoutSeconds

        let headersJSON: String
        if let data = try? JSONSerialization.data(withJSONObject: headersDict, options: []),
           let str = String(data: data, encoding: .utf8) {
            headersJSON = str
        } else {
            headersJSON = "{}"
        }

        DispatchQueue.global(qos: .userInitiated).async {
            guard let cURL = urlStr.cString(using: .utf8),
                  let cMethod = methodStr.cString(using: .utf8),
                  let cHeaders = headersJSON.cString(using: .utf8),
                  let cBody = bodyStr.cString(using: .utf8) else {
                DispatchQueue.main.async {
                    self.isLoading = false
                    self.errorMessage = "Couldn’t build the request. Check the body, then try again."
                }
                return
            }

            let cRes = ExecuteGoHTTPRequest(cURL, cMethod, cHeaders, cBody, Int32(timeout))
            guard let ptr = cRes else {
                DispatchQueue.main.async {
                    self.isLoading = false
                    self.errorMessage = "Internal execution error (null response)"
                }
                return
            }
            defer { FreeGoCString(ptr) }

            let jsonStr = String(cString: ptr)
            guard let data = jsonStr.data(using: .utf8) else {
                DispatchQueue.main.async {
                    self.isLoading = false
                    self.errorMessage = "Couldn’t read the response."
                }
                return
            }

            do {
                let res = try JSONDecoder().decode(HTTPExecutionResultDTO.self, from: data)
                DispatchQueue.main.async {
                    self.isLoading = false
                    if res.statusCode == 0 {
                        self.errorMessage = res.body.isEmpty ? "Connection failed" : res.body
                        self.responseResult = nil
                    } else {
                        self.responseResult = res
                        self.errorMessage = nil
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.isLoading = false
                    self.errorMessage = "Couldn’t read the response: \(error.localizedDescription)"
                }
            }
        }
    }

    private func statusColor(for code: Int) -> Color {
        switch code {
        case 200..<300:
            return StatusTone.success.tint
        case 300..<400:
            return .blue
        case 400..<500:
            return StatusTone.warning.tint
        case 500..<600:
            return StatusTone.failure.tint
        default:
            return .secondary
        }
    }

    private func statusText(for code: Int) -> String {
        switch code {
        case 200: return "OK"
        case 201: return "Created"
        case 202: return "Accepted"
        case 204: return "No Content"
        case 301: return "Moved Permanently"
        case 302: return "Found"
        case 304: return "Not Modified"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 409: return "Conflict"
        case 422: return "Unprocessable Entity"
        case 500: return "Internal Server Error"
        case 502: return "Bad Gateway"
        case 503: return "Service Unavailable"
        case 504: return "Gateway Timeout"
        default: return ""
        }
    }
}
