import Foundation

struct GitGraphSegment: Hashable {
    let fromColumn: Int
    let fromTop: Bool
    let toColumn: Int
    let toBottom: Bool
    let color: Int
}

struct GitGraphRow: Hashable {
    let column: Int
    let color: Int
    let width: Int
    let isMerge: Bool
    let segments: [GitGraphSegment]
}

enum GitGraphLayout {
    private struct Lane: Equatable {
        let hash: String
        let color: Int
    }

    static func rows(for commits: [GitHistoryCommit]) -> [GitGraphRow] {
        var lanes: [Lane?] = []
        var nextColor = 0
        var rows: [GitGraphRow] = []
        rows.reserveCapacity(commits.count)

        func freeSlot() -> Int {
            if let index = lanes.firstIndex(where: { $0 == nil }) { return index }
            lanes.append(nil)
            return lanes.count - 1
        }

        for commit in commits {
            let before = lanes
            let column: Int
            if let existing = lanes.firstIndex(where: { $0?.hash == commit.hash }) {
                column = existing
            } else {
                column = freeSlot()
                lanes[column] = Lane(hash: commit.hash, color: nextColor)
                nextColor += 1
            }
            let color = lanes[column]?.color ?? 0
            for index in lanes.indices where index != column && lanes[index]?.hash == commit.hash {
                lanes[index] = nil
            }

            var fromNode: [Int] = []
            lanes[column] = nil
            for (offset, parent) in commit.parents.enumerated() {
                if let existing = lanes.firstIndex(where: { $0?.hash == parent }) {
                    fromNode.append(existing)
                } else if offset == 0 {
                    lanes[column] = Lane(hash: parent, color: color)
                    fromNode.append(column)
                } else {
                    let slot = freeSlot()
                    lanes[slot] = Lane(hash: parent, color: nextColor)
                    nextColor += 1
                    fromNode.append(slot)
                }
            }
            while let last = lanes.last, last == nil { lanes.removeLast() }

            var segments: [GitGraphSegment] = []
            for (index, lane) in before.enumerated() {
                guard let lane else { continue }
                if lane.hash == commit.hash {
                    segments.append(GitGraphSegment(fromColumn: index, fromTop: true, toColumn: column, toBottom: false, color: lane.color))
                } else {
                    segments.append(GitGraphSegment(fromColumn: index, fromTop: true, toColumn: index, toBottom: false, color: lane.color))
                }
            }
            for (index, lane) in lanes.enumerated() {
                guard let lane else { continue }
                let continues = index != column && before.indices.contains(index) && before[index] == lane
                if fromNode.contains(index) {
                    segments.append(GitGraphSegment(fromColumn: column, fromTop: false, toColumn: index, toBottom: true, color: lane.color))
                }
                if continues || !fromNode.contains(index) {
                    segments.append(GitGraphSegment(fromColumn: index, fromTop: false, toColumn: index, toBottom: true, color: lane.color))
                }
            }

            rows.append(GitGraphRow(
                column: column,
                color: color,
                width: max(before.count, lanes.count, column + 1),
                isMerge: commit.parents.count > 1,
                segments: segments
            ))
        }
        return rows
    }
}
