import SwiftUI

struct GitGraphCell: View {
    let row: GitGraphRow
    let lanes: Int

    private var visibleLanes: Int { min(max(lanes, 1), GitGraphStyle.maxVisibleLanes) }

    var body: some View {
        Canvas { context, size in
            let lanes = visibleLanes
            func x(_ column: Int) -> CGFloat { GitGraphStyle.laneWidth * (CGFloat(column) + 0.5) }
            let middle = size.height / 2
            let style = StrokeStyle(lineWidth: GitGraphStyle.lineWidth, lineCap: .round)
            for segment in row.segments where segment.fromColumn < lanes && segment.toColumn < lanes {
                let start = CGPoint(x: x(segment.fromColumn), y: segment.fromTop ? 0 : middle)
                let end = CGPoint(x: x(segment.toColumn), y: segment.toBottom ? size.height : middle)
                var path = Path()
                path.move(to: start)
                if start.x == end.x {
                    path.addLine(to: end)
                } else {
                    let bend = (start.y + end.y) / 2
                    path.addCurve(to: end, control1: CGPoint(x: start.x, y: bend), control2: CGPoint(x: end.x, y: bend))
                }
                context.stroke(path, with: .color(GitGraphStyle.laneColor(segment.color)), style: style)
            }
            guard row.column < lanes else { return }
            let diameter = GitGraphStyle.nodeDiameter
            let node = CGRect(x: x(row.column) - diameter / 2, y: middle - diameter / 2, width: diameter, height: diameter)
            let color = GitGraphStyle.laneColor(row.color)
            if row.isMerge {
                context.fill(Path(ellipseIn: node), with: .color(ThemeColor.contentSurface))
                context.stroke(Path(ellipseIn: node.insetBy(dx: GitGraphStyle.lineWidth / 2, dy: GitGraphStyle.lineWidth / 2)), with: .color(color), style: style)
            } else {
                context.fill(Path(ellipseIn: node), with: .color(color))
            }
        }
        .frame(width: GitGraphStyle.laneWidth * CGFloat(visibleLanes))
        .frame(maxHeight: .infinity)
        .accessibilityHidden(true)
    }
}
