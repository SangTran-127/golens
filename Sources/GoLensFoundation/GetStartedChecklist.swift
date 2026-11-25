import Foundation

public enum GetStartedStep: String, CaseIterable, Identifiable, Sendable {
    case openProject, goToDefinition, runTestFromGutter, stopAtBreakpoint, commandPalette

    public var id: String { rawValue }
}

public struct GetStartedChecklist: Equatable, Sendable {
    public private(set) var completed: Set<GetStartedStep>
    public var isHidden: Bool

    public init(storedCompleted: [String], isHidden: Bool) {
        completed = Set(storedCompleted.compactMap(GetStartedStep.init(rawValue:)))
        self.isHidden = isHidden
    }

    public var storedCompleted: [String] {
        GetStartedStep.allCases.filter(completed.contains).map(\.rawValue)
    }

    public func isDone(_ step: GetStartedStep) -> Bool {
        completed.contains(step)
    }

    @discardableResult
    public mutating func complete(_ step: GetStartedStep) -> Bool {
        completed.insert(step).inserted
    }

    public var isFinished: Bool {
        completed.count == GetStartedStep.allCases.count
    }

    public var progressText: String {
        isFinished ? "All done" : "\(completed.count) of \(GetStartedStep.allCases.count) done"
    }
}
