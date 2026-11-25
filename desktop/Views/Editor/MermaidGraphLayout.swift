import CoreGraphics
import Foundation

struct PositionedMermaidNode {
    let node: MermaidNode
    let rect: CGRect
}

struct MermaidGraphLayout {
    let nodes: [String: PositionedMermaidNode]
    let orderedNodes: [PositionedMermaidNode]
    let edges: [MermaidEdge]
    let direction: MermaidGraphDirection
    let canvasSize: CGSize

    static func compute(for diagram: MermaidGraphDiagram) -> MermaidGraphLayout {
        guard !diagram.nodes.isEmpty else {
            return MermaidGraphLayout(
                nodes: [:],
                orderedNodes: [],
                edges: [],
                direction: diagram.direction,
                canvasSize: CGSize(width: 320, height: 120)
            )
        }

        var nodeSizes: [String: CGSize] = [:]
        for node in diagram.nodes {
            if node.shape == .startEnd {
                nodeSizes[node.id] = CGSize(width: 28, height: 28)
            } else {
                let titleWidth = CGFloat(node.label.count) * 7.4 + 34
                let maxDetailChars = node.details.map(\.count).max() ?? 0
                let detailWidth = CGFloat(maxDetailChars) * 6.6 + 28
                let width = min(280, max(108, max(titleWidth, detailWidth)))
                let extraDetailHeight = node.details.isEmpty ? 0 : (CGFloat(min(5, node.details.count)) * 16 + 10)
                let baseHeight: CGFloat = node.shape == .diamond ? 54 : 40
                nodeSizes[node.id] = CGSize(width: width, height: baseHeight + extraDetailHeight)
            }
        }

        var incomingCount: [String: Int] = [:]
        var outgoing: [String: [String]] = [:]
        for node in diagram.nodes {
            incomingCount[node.id] = 0
            outgoing[node.id] = []
        }
        for edge in diagram.edges where edge.from != edge.to {
            outgoing[edge.from, default: []].append(edge.to)
            incomingCount[edge.to, default: 0] += 1
        }

        var ranks: [String: Int] = [:]
        var queue: [String] = diagram.nodes.filter { (incomingCount[$0.id] ?? 0) == 0 }.map(\.id)
        if queue.isEmpty, let firstID = diagram.nodes.first?.id {
            queue.append(firstID)
        }

        var visited = Set<String>()
        for id in queue {
            ranks[id] = 0
            visited.insert(id)
        }

        var head = 0
        let maxRankCap = max(1, diagram.nodes.count)
        while head < queue.count {
            let current = queue[head]
            head += 1
            let currentRank = ranks[current] ?? 0
            for next in outgoing[current] ?? [] {
                let candidateRank = min(maxRankCap, currentRank + 1)
                if candidateRank > (ranks[next] ?? -1) {
                    ranks[next] = candidateRank
                }
                if !visited.contains(next) {
                    visited.insert(next)
                    queue.append(next)
                }
            }
        }

        for node in diagram.nodes where ranks[node.id] == nil {
            ranks[node.id] = 0
        }

        let maxRank = ranks.values.max() ?? 0
        var layers: [[MermaidNode]] = Array(repeating: [], count: maxRank + 1)
        for node in diagram.nodes {
            let r = ranks[node.id] ?? 0
            let effectiveRank: Int
            if diagram.direction == .bottomUp || diagram.direction == .rightLeft {
                effectiveRank = maxRank - r
            } else {
                effectiveRank = r
            }
            layers[effectiveRank].append(node)
        }
        layers.removeAll { $0.isEmpty }

        let padX: CGFloat = 32
        let padY: CGFloat = 28
        let hSpacing: CGFloat = diagram.direction.isHorizontal ? 76 : 36
        let vSpacing: CGFloat = diagram.direction.isHorizontal ? 28 : 64

        var positioned: [String: PositionedMermaidNode] = [:]
        var ordered: [PositionedMermaidNode] = []

        if diagram.direction.isHorizontal {
            var colWidths: [CGFloat] = []
            var colHeights: [CGFloat] = []
            for layer in layers {
                let w = layer.compactMap { nodeSizes[$0.id]?.width }.max() ?? 120
                let h = layer.enumerated().reduce(CGFloat(0)) { acc, pair in
                    acc + (nodeSizes[pair.element.id]?.height ?? 40) + (pair.offset > 0 ? vSpacing : 0)
                }
                colWidths.append(w)
                colHeights.append(h)
            }
            let maxColHeight = colHeights.max() ?? 100
            var currentX = padX
            for (layerIdx, layer) in layers.enumerated() {
                let colW = colWidths[layerIdx]
                let colH = colHeights[layerIdx]
                var currentY = padY + (maxColHeight - colH) / 2
                for node in layer {
                    let size = nodeSizes[node.id] ?? CGSize(width: 120, height: 40)
                    let rect = CGRect(
                        x: currentX + (colW - size.width) / 2,
                        y: currentY,
                        width: size.width,
                        height: size.height
                    )
                    let item = PositionedMermaidNode(node: node, rect: rect)
                    positioned[node.id] = item
                    ordered.append(item)
                    currentY += size.height + vSpacing
                }
                currentX += colW + hSpacing
            }
            let totalWidth = max(320, currentX - hSpacing + padX)
            let totalHeight = max(140, maxColHeight + padY * 2)
            return MermaidGraphLayout(
                nodes: positioned,
                orderedNodes: ordered,
                edges: diagram.edges,
                direction: diagram.direction,
                canvasSize: CGSize(width: totalWidth, height: totalHeight)
            )
        } else {
            var rowWidths: [CGFloat] = []
            var rowHeights: [CGFloat] = []
            for layer in layers {
                let w = layer.enumerated().reduce(CGFloat(0)) { acc, pair in
                    acc + (nodeSizes[pair.element.id]?.width ?? 120) + (pair.offset > 0 ? hSpacing : 0)
                }
                let h = layer.compactMap { nodeSizes[$0.id]?.height }.max() ?? 40
                rowWidths.append(w)
                rowHeights.append(h)
            }
            let maxRowWidth = rowWidths.max() ?? 240
            var currentY = padY
            for (layerIdx, layer) in layers.enumerated() {
                let rowW = rowWidths[layerIdx]
                let rowH = rowHeights[layerIdx]
                var currentX = padX + (maxRowWidth - rowW) / 2
                for node in layer {
                    let size = nodeSizes[node.id] ?? CGSize(width: 120, height: 40)
                    let rect = CGRect(
                        x: currentX,
                        y: currentY + (rowH - size.height) / 2,
                        width: size.width,
                        height: size.height
                    )
                    let item = PositionedMermaidNode(node: node, rect: rect)
                    positioned[node.id] = item
                    ordered.append(item)
                    currentX += size.width + hSpacing
                }
                currentY += rowH + vSpacing
            }
            let totalWidth = max(320, maxRowWidth + padX * 2)
            let totalHeight = max(140, currentY - vSpacing + padY)
            return MermaidGraphLayout(
                nodes: positioned,
                orderedNodes: ordered,
                edges: diagram.edges,
                direction: diagram.direction,
                canvasSize: CGSize(width: totalWidth, height: totalHeight)
            )
        }
    }
}
