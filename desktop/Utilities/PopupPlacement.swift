import CoreGraphics

struct PopupPlacement: Equatable {
    enum Edge: Equatable {
        case below
        case above
    }

    let edge: Edge
    let edgeY: CGFloat
    let availableHeight: CGFloat

    static let gap: CGFloat = 8
    static let margin: CGFloat = 8
    static let minimumHeight: CGFloat = 160

    static func resolve(anchor: CGRect, bounds: CGRect, naturalHeight: CGFloat) -> PopupPlacement {
        let spaceBelow = bounds.maxY - margin - (anchor.maxY + gap)
        let spaceAbove = (anchor.minY - gap) - (bounds.minY + margin)
        if naturalHeight > spaceBelow, spaceAbove > spaceBelow {
            return PopupPlacement(edge: .above, edgeY: anchor.minY - gap, availableHeight: max(minimumHeight, spaceAbove))
        }
        return PopupPlacement(edge: .below, edgeY: anchor.maxY + gap, availableHeight: max(minimumHeight, spaceBelow))
    }
}
