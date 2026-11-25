import SwiftUI
import AppKit

struct MermaidDiagramBlockView: View {
    let code: String
    let isDark: Bool
    @Bindable var workspace: WorkspaceState

    @State private var showSource = false
    @State private var zoomScale: CGFloat = 1.0
    @State private var didCopy = false

    var body: some View {
        let parsed = MermaidParser.parse(code)

        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Spacing.standard) {
                HStack(spacing: Spacing.compact) {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .font(.caption)
                        .foregroundStyle(Color.accentColor)
                        .accessibilityHidden(true)
                    Text("Mermaid Diagram")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.primary)

                    Text(parsed.kindTitle)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(Color.secondary)
                        .padding(.horizontal, Spacing.row)
                        .padding(.vertical, Spacing.hairline)
                        .background(
                            Capsule()
                                .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.6))
                        )
                }

                Spacer()

                if !showSource {
                    HStack(spacing: Spacing.hairline) {
                        Button {
                            zoomScale = max(0.5, zoomScale - 0.15)
                        } label: {
                            Image(systemName: "minus.magnifyingglass")
                                .font(.caption)
                                .foregroundStyle(Color.secondary)
                                .frame(width: 22, height: 20)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Zoom Out")
                        .help("Zoom out Mermaid diagram")

                        Button {
                            zoomScale = 1.0
                        } label: {
                            Text("\(Int(round(zoomScale * 100)))%")
                                .font(.caption2.monospacedDigit().weight(.medium))
                                .foregroundStyle(Color.secondary)
                                .padding(.horizontal, Spacing.compact)
                                .frame(height: 20)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Reset Zoom to 100 percent")
                        .help("Reset zoom to 100%")

                        Button {
                            zoomScale = min(2.0, zoomScale + 0.15)
                        } label: {
                            Image(systemName: "plus.magnifyingglass")
                                .font(.caption)
                                .foregroundStyle(Color.secondary)
                                .frame(width: 22, height: 20)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Zoom In")
                        .help("Zoom in Mermaid diagram")
                    }
                    .padding(.horizontal, Spacing.compact)
                    .background(
                        RoundedRectangle(cornerRadius: CornerRadius.control, style: .continuous)
                            .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.35))
                    )
                }

                HStack(spacing: Spacing.hairline) {
                    Button {
                        showSource = false
                    } label: {
                        Text("Diagram")
                            .font(.caption2.weight(!showSource ? .semibold : .regular))
                            .foregroundStyle(!showSource ? Color.primary : Color.secondary)
                            .padding(.horizontal, Spacing.row)
                            .padding(.vertical, Spacing.hairline)
                            .background(
                                RoundedRectangle(cornerRadius: CornerRadius.small, style: .continuous)
                                    .fill(!showSource ? Color(nsColor: .controlBackgroundColor) : Color.clear)
                            )
                    }
                    .buttonStyle(.plain)
                    .help("Show rendered Mermaid diagram")

                    Button {
                        showSource = true
                    } label: {
                        Text("Source")
                            .font(.caption2.weight(showSource ? .semibold : .regular))
                            .foregroundStyle(showSource ? Color.primary : Color.secondary)
                            .padding(.horizontal, Spacing.row)
                            .padding(.vertical, Spacing.hairline)
                            .background(
                                RoundedRectangle(cornerRadius: CornerRadius.small, style: .continuous)
                                    .fill(showSource ? Color(nsColor: .controlBackgroundColor) : Color.clear)
                            )
                    }
                    .buttonStyle(.plain)
                    .help("Show raw Mermaid source")
                }
                .padding(Spacing.hairline)
                .background(
                    RoundedRectangle(cornerRadius: CornerRadius.control, style: .continuous)
                        .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.4))
                )

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    didCopy = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        didCopy = false
                    }
                } label: {
                    HStack(spacing: Spacing.compact) {
                        Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                            .font(.caption2)
                            .accessibilityHidden(true)
                        Text(didCopy ? "Copied" : "Copy")
                            .font(.caption2.weight(.medium))
                    }
                    .foregroundStyle(didCopy ? StatusTone.success.tint : Color.secondary)
                    .padding(.horizontal, Spacing.row)
                    .padding(.vertical, Spacing.hairline)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(didCopy ? "Copied Mermaid source" : "Copy Mermaid source")
                .help("Copy Mermaid source to clipboard")
            }
            .padding(.horizontal, Spacing.comfortable)
            .padding(.vertical, Spacing.row)
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            if showSource {
                ScrollView(.horizontal, showsIndicators: true) {
                    Text(code)
                        .font(.callout.monospaced())
                        .foregroundStyle(Color.primary)
                        .textSelection(.enabled)
                        .padding(Spacing.comfortable)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(ThemeColor.panelSurface.opacity(0.55))
            } else {
                ScrollView([.horizontal, .vertical], showsIndicators: true) {
                    Group {
                        switch parsed {
                        case .sequence(let diagram):
                            MermaidSequenceCanvasView(diagram: diagram, isDark: isDark, zoomScale: zoomScale)
                        case .graph(let diagram):
                            MermaidGraphCanvasView(diagram: diagram, isDark: isDark, zoomScale: zoomScale)
                        }
                    }
                    .padding(Spacing.section)
                    .frame(maxWidth: .infinity, alignment: .center)
                }
                .frame(minHeight: 140, maxHeight: 540)
                .background(ThemeColor.panelSurface.opacity(0.45))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.compactPanel, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: CornerRadius.compactPanel, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: Stroke.standard)
        )
    }
}

private struct MermaidGraphCanvasView: View {
    let diagram: MermaidGraphDiagram
    let isDark: Bool
    let zoomScale: CGFloat

    var body: some View {
        let layout = MermaidGraphLayout.compute(for: diagram)
        let scaledWidth = layout.canvasSize.width * zoomScale
        let scaledHeight = layout.canvasSize.height * zoomScale

        Canvas { context, _ in
            context.scaleBy(x: zoomScale, y: zoomScale)

            let strokeColor = Color(nsColor: .secondaryLabelColor)
            let accentColor = Color.accentColor
            let nodeFill = Color(nsColor: .controlBackgroundColor)
            let nodeBorder = Color(nsColor: .separatorColor)
            let textColor = Color(nsColor: .labelColor)
            let secondaryTextColor = Color(nsColor: .secondaryLabelColor)
            let nodeStroke = Stroke.standard * 1.4
            let capStroke = Stroke.standard * 1.2

            let groupedSubgraphs = Dictionary(
                grouping: layout.orderedNodes.filter { $0.node.subgraphTitle != nil },
                by: { $0.node.subgraphTitle ?? "" }
            )
            for (title, members) in groupedSubgraphs where !title.isEmpty && !members.isEmpty {
                let minX = (members.map { $0.rect.minX }.min() ?? 0) - 14
                let minY = (members.map { $0.rect.minY }.min() ?? 0) - 24
                let maxX = (members.map { $0.rect.maxX }.max() ?? 0) + 14
                let maxY = (members.map { $0.rect.maxY }.max() ?? 0) + 14
                let groupRect = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
                let groupPath = Path(roundedRect: groupRect, cornerRadius: CornerRadius.compactPanel)
                context.fill(groupPath, with: .color(accentColor.opacity(isDark ? 0.06 : 0.04)))
                context.stroke(
                    groupPath,
                    with: .color(nodeBorder),
                    style: StrokeStyle(lineWidth: Stroke.standard, dash: [5, 4])
                )
                let headerText = Text(title).font(.caption2.weight(.semibold)).foregroundStyle(secondaryTextColor)
                context.draw(
                    headerText,
                    at: CGPoint(x: groupRect.minX + 10, y: groupRect.minY + 10),
                    anchor: .leading
                )
            }

            for edge in layout.edges {
                guard let fromItem = layout.nodes[edge.from],
                      let toItem = layout.nodes[edge.to] else { continue }

                let endpoints = Self.computeEdgeEndpoints(
                    from: fromItem.rect,
                    to: toItem.rect,
                    isHorizontal: layout.direction.isHorizontal
                )

                var curvePath = Path()
                curvePath.move(to: endpoints.start)
                curvePath.addCurve(
                    to: endpoints.end,
                    control1: endpoints.control1,
                    control2: endpoints.control2
                )

                let edgeWidth: CGFloat = edge.style == .thick ? Stroke.standard * 2.4 : Stroke.standard * 1.5
                let strokeStyle: StrokeStyle
                if edge.style == .dashed {
                    strokeStyle = StrokeStyle(lineWidth: edgeWidth, lineCap: .round, dash: [5, 4])
                } else {
                    strokeStyle = StrokeStyle(lineWidth: edgeWidth, lineCap: .round)
                }
                context.stroke(curvePath, with: .color(strokeColor), style: strokeStyle)

                if edge.hasArrow {
                    let arrowPath = Self.makeArrowhead(at: endpoints.end, from: endpoints.control2)
                    context.fill(arrowPath, with: .color(strokeColor))
                }

                if !edge.label.isEmpty {
                    let mid = Self.cubicBezierPoint(
                        t: 0.5,
                        p0: endpoints.start,
                        p1: endpoints.control1,
                        p2: endpoints.control2,
                        p3: endpoints.end
                    )
                    let pillWidth = CGFloat(edge.label.count) * 6.4 + 14
                    let pillRect = CGRect(
                        x: mid.x - pillWidth / 2,
                        y: mid.y - 10,
                        width: pillWidth,
                        height: 20
                    )
                    let pillPath = Path(roundedRect: pillRect, cornerRadius: pillRect.height / 2)
                    context.fill(pillPath, with: .color(nodeFill))
                    context.stroke(pillPath, with: .color(nodeBorder), lineWidth: Stroke.standard)

                    let labelText = Text(edge.label)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(textColor)
                    context.draw(labelText, at: mid, anchor: .center)
                }
            }

            for item in layout.orderedNodes {
                let rect = item.rect
                let shapePath = Self.makeNodeShapePath(shape: item.node.shape, rect: rect)

                if item.node.shape == .startEnd {
                    context.fill(shapePath, with: .color(accentColor))
                    continue
                }

                context.fill(shapePath, with: .color(nodeFill))
                context.stroke(shapePath, with: .color(accentColor.opacity(0.65)), lineWidth: nodeStroke)

                if item.node.shape == .cylinder {
                    let topCap = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: 10)
                    context.stroke(Path(ellipseIn: topCap), with: .color(accentColor.opacity(0.65)), lineWidth: capStroke)
                }

                if item.node.details.isEmpty {
                    let nodeText = Text(item.node.label)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(textColor)
                    context.draw(nodeText, at: CGPoint(x: rect.midX, y: rect.midY), anchor: .center)
                } else {
                    let titleY = rect.minY + 16
                    let titleText = Text(item.node.label)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(textColor)
                    context.draw(titleText, at: CGPoint(x: rect.midX, y: titleY), anchor: .center)

                    var divPath = Path()
                    divPath.move(to: CGPoint(x: rect.minX + 6, y: rect.minY + 28))
                    divPath.addLine(to: CGPoint(x: rect.maxX - 6, y: rect.minY + 28))
                    context.stroke(divPath, with: .color(nodeBorder), lineWidth: Stroke.standard)

                    for (idx, detail) in item.node.details.prefix(5).enumerated() {
                        let detailY = rect.minY + 39 + CGFloat(idx) * 15
                        let detailText = Text(detail)
                            .font(.caption2.monospaced())
                            .foregroundStyle(secondaryTextColor)
                        context.draw(
                            detailText,
                            at: CGPoint(x: rect.minX + 10, y: detailY),
                            anchor: .leading
                        )
                    }
                }
            }
        }
        .frame(width: scaledWidth, height: scaledHeight)
    }

    private static func makeNodeShapePath(shape: MermaidNodeShape, rect: CGRect) -> Path {
        switch shape {
        case .rect:
            return Path(roundedRect: rect, cornerRadius: CornerRadius.small)
        case .rounded:
            return Path(roundedRect: rect, cornerRadius: CornerRadius.compactPanel)
        case .stadium:
            return Path(roundedRect: rect, cornerRadius: rect.height / 2)
        case .circle, .startEnd:
            return Path(ellipseIn: rect)
        case .cylinder:
            return Path(roundedRect: rect, cornerRadius: CornerRadius.compactPanel)
        case .diamond:
            var path = Path()
            path.move(to: CGPoint(x: rect.midX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
            path.closeSubpath()
            return path
        }
    }

    private static func computeEdgeEndpoints(
        from source: CGRect,
        to target: CGRect,
        isHorizontal: Bool
    ) -> (start: CGPoint, control1: CGPoint, control2: CGPoint, end: CGPoint) {
        if source.equalTo(target) {
            let start = CGPoint(x: source.maxX, y: source.midY - 6)
            let end = CGPoint(x: source.maxX, y: source.midY + 6)
            let c1 = CGPoint(x: source.maxX + 36, y: source.midY - 24)
            let c2 = CGPoint(x: source.maxX + 36, y: source.midY + 24)
            return (start, c1, c2, end)
        }

        if isHorizontal {
            if target.minX >= source.maxX - 4 {
                let start = CGPoint(x: source.maxX, y: source.midY)
                let end = CGPoint(x: target.minX, y: target.midY)
                let midX = (start.x + end.x) / 2
                return (start, CGPoint(x: midX, y: start.y), CGPoint(x: midX, y: end.y), end)
            } else {
                let start = CGPoint(x: source.minX, y: source.midY)
                let end = CGPoint(x: target.maxX, y: target.midY)
                let midX = (start.x + end.x) / 2
                return (start, CGPoint(x: midX, y: start.y), CGPoint(x: midX, y: end.y), end)
            }
        } else {
            if target.minY >= source.maxY - 4 {
                let start = CGPoint(x: source.midX, y: source.maxY)
                let end = CGPoint(x: target.midX, y: target.minY)
                let midY = (start.y + end.y) / 2
                return (start, CGPoint(x: start.x, y: midY), CGPoint(x: end.x, y: midY), end)
            } else if target.maxY <= source.minY + 4 {
                let start = CGPoint(x: source.midX, y: source.minY)
                let end = CGPoint(x: target.midX, y: target.maxY)
                let midY = (start.y + end.y) / 2
                return (start, CGPoint(x: start.x, y: midY), CGPoint(x: end.x, y: midY), end)
            } else {
                let start = CGPoint(x: source.maxX, y: source.midY)
                let end = CGPoint(x: target.minX, y: target.midY)
                let midX = (start.x + end.x) / 2
                return (start, CGPoint(x: midX, y: start.y), CGPoint(x: midX, y: end.y), end)
            }
        }
    }

    private static func cubicBezierPoint(
        t: CGFloat,
        p0: CGPoint,
        p1: CGPoint,
        p2: CGPoint,
        p3: CGPoint
    ) -> CGPoint {
        let u = 1 - t
        let tt = t * t
        let uu = u * u
        let uuu = uu * u
        let ttt = tt * t

        let x = uuu * p0.x + 3 * uu * t * p1.x + 3 * u * tt * p2.x + ttt * p3.x
        let y = uuu * p0.y + 3 * uu * t * p1.y + 3 * u * tt * p2.y + ttt * p3.y
        return CGPoint(x: x, y: y)
    }

    private static func makeArrowhead(at tip: CGPoint, from control: CGPoint) -> Path {
        let dx = tip.x - control.x
        let dy = tip.y - control.y
        let angle = atan2(dy, dx)
        let arrowLength: CGFloat = 8.5
        let arrowAngle: CGFloat = .pi / 6

        let p1 = CGPoint(
            x: tip.x - arrowLength * cos(angle - arrowAngle),
            y: tip.y - arrowLength * sin(angle - arrowAngle)
        )
        let p2 = CGPoint(
            x: tip.x - arrowLength * cos(angle + arrowAngle),
            y: tip.y - arrowLength * sin(angle + arrowAngle)
        )

        var path = Path()
        path.move(to: tip)
        path.addLine(to: p1)
        path.addLine(to: p2)
        path.closeSubpath()
        return path
    }
}

private struct MermaidSequenceCanvasView: View {
    let diagram: MermaidSequenceDiagram
    let isDark: Bool
    let zoomScale: CGFloat

    var body: some View {
        let colSpacing: CGFloat = 160
        let boxWidth: CGFloat = 116
        let boxHeight: CGFloat = 36
        let padX: CGFloat = 36
        let padY: CGFloat = 24
        let stepHeight: CGFloat = 48

        let participantCount = max(1, diagram.participants.count)
        let baseWidth = max(320, padX * 2 + CGFloat(participantCount - 1) * colSpacing + boxWidth)
        let baseHeight = max(160, padY * 2 + boxHeight * 2 + CGFloat(max(1, diagram.steps.count)) * stepHeight + 28)

        let scaledWidth = baseWidth * zoomScale
        let scaledHeight = baseHeight * zoomScale

        Canvas { context, _ in
            context.scaleBy(x: zoomScale, y: zoomScale)

            let accentColor = Color.accentColor
            let boxFill = Color(nsColor: .controlBackgroundColor)
            let borderColor = Color(nsColor: .separatorColor)
            let lineColor = Color(nsColor: .secondaryLabelColor)
            let textColor = Color(nsColor: .labelColor)
            let lifelineStroke = Stroke.standard * 1.2
            let boxStroke = Stroke.standard * 1.4
            let messageStroke = Stroke.standard * 1.5

            var centerXs: [String: CGFloat] = [:]
            for (idx, p) in diagram.participants.enumerated() {
                let cx = padX + boxWidth / 2 + CGFloat(idx) * colSpacing
                centerXs[p.id] = cx
            }

            let topBoxMaxY = padY + boxHeight
            let bottomBoxMinY = baseHeight - padY - boxHeight

            for p in diagram.participants {
                guard let cx = centerXs[p.id] else { continue }
                var lifeline = Path()
                lifeline.move(to: CGPoint(x: cx, y: topBoxMaxY))
                lifeline.addLine(to: CGPoint(x: cx, y: bottomBoxMinY))
                context.stroke(
                    lifeline,
                    with: .color(borderColor),
                    style: StrokeStyle(lineWidth: lifelineStroke, dash: [4, 4])
                )
            }

            for p in diagram.participants {
                guard let cx = centerXs[p.id] else { continue }
                for boxMinY in [padY, bottomBoxMinY] {
                    let rect = CGRect(x: cx - boxWidth / 2, y: boxMinY, width: boxWidth, height: boxHeight)
                    let path = Path(roundedRect: rect, cornerRadius: CornerRadius.compactPanel)
                    context.fill(path, with: .color(boxFill))
                    context.stroke(path, with: .color(accentColor.opacity(0.65)), lineWidth: boxStroke)

                    let displayTitle = p.label
                    let label = Text(displayTitle)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(textColor)
                    context.draw(label, at: CGPoint(x: rect.midX, y: rect.midY), anchor: .center)
                }
            }

            for (stepIdx, step) in diagram.steps.enumerated() {
                let y = topBoxMaxY + 30 + CGFloat(stepIdx) * stepHeight
                switch step {
                case .message(_, let from, let to, let text, let isDashed):
                    guard let fromX = centerXs[from], let toX = centerXs[to] else { continue }
                    let strokeStyle = isDashed
                        ? StrokeStyle(lineWidth: messageStroke, lineCap: .round, dash: [5, 4])
                        : StrokeStyle(lineWidth: messageStroke, lineCap: .round)

                    if from == to {
                        var loopPath = Path()
                        loopPath.move(to: CGPoint(x: fromX, y: y - 6))
                        loopPath.addLine(to: CGPoint(x: fromX + 36, y: y - 6))
                        loopPath.addLine(to: CGPoint(x: fromX + 36, y: y + 10))
                        loopPath.addLine(to: CGPoint(x: fromX, y: y + 10))
                        context.stroke(loopPath, with: .color(lineColor), style: strokeStyle)

                        let arrow = Self.makeSequenceArrow(at: CGPoint(x: fromX, y: y + 10), pointingRight: false)
                        context.fill(arrow, with: .color(lineColor))

                        if !text.isEmpty {
                            let msgLabel = Text(text).font(.caption2.weight(.medium)).foregroundStyle(textColor)
                            context.draw(msgLabel, at: CGPoint(x: fromX + 42, y: y + 2), anchor: .leading)
                        }
                    } else {
                        var msgPath = Path()
                        msgPath.move(to: CGPoint(x: fromX, y: y))
                        msgPath.addLine(to: CGPoint(x: toX, y: y))
                        context.stroke(msgPath, with: .color(lineColor), style: strokeStyle)

                        let pointingRight = toX > fromX
                        let arrow = Self.makeSequenceArrow(at: CGPoint(x: toX, y: y), pointingRight: pointingRight)
                        context.fill(arrow, with: .color(lineColor))

                        if !text.isEmpty {
                            let midX = (fromX + toX) / 2
                            let msgLabel = Text(text).font(.caption2.weight(.medium)).foregroundStyle(textColor)
                            context.draw(msgLabel, at: CGPoint(x: midX, y: y - 10), anchor: .center)
                        }
                    }

                case .note(_, let pIDs, let text):
                    let xs = pIDs.compactMap { centerXs[$0] }
                    let minX = (xs.min() ?? (baseWidth / 2)) - 58
                    let maxX = (xs.max() ?? (baseWidth / 2)) + 58
                    let noteRect = CGRect(x: minX, y: y - 14, width: max(116, maxX - minX), height: 28)
                    let notePath = Path(roundedRect: noteRect, cornerRadius: CornerRadius.control)
                    context.fill(notePath, with: .color(StatusTone.warning.fill))
                    context.stroke(notePath, with: .color(StatusTone.warning.tint.opacity(0.45)), lineWidth: Stroke.standard)

                    let noteLabel = Text(text).font(.caption2.weight(.medium)).foregroundStyle(textColor)
                    context.draw(noteLabel, at: CGPoint(x: noteRect.midX, y: noteRect.midY), anchor: .center)
                }
            }
        }
        .frame(width: scaledWidth, height: scaledHeight)
    }

    private static func makeSequenceArrow(at tip: CGPoint, pointingRight: Bool) -> Path {
        let dir: CGFloat = pointingRight ? -1 : 1
        var path = Path()
        path.move(to: tip)
        path.addLine(to: CGPoint(x: tip.x + dir * 8, y: tip.y - 4.5))
        path.addLine(to: CGPoint(x: tip.x + dir * 8, y: tip.y + 4.5))
        path.closeSubpath()
        return path
    }
}
