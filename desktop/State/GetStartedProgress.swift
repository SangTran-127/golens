import Foundation
import GoLensFoundation

@Observable
final class GetStartedProgress {
    static let shared = GetStartedProgress()
    static let completedKey = "GoLensGetStartedCompleted"
    static let hiddenKey = "GoLensGetStartedHidden"

    private(set) var checklist: GetStartedChecklist

    private init() {
        let defaults = UserDefaults.standard
        checklist = GetStartedChecklist(
            storedCompleted: defaults.stringArray(forKey: Self.completedKey) ?? [],
            isHidden: defaults.bool(forKey: Self.hiddenKey)
        )
    }

    func complete(_ step: GetStartedStep) {
        guard !checklist.isDone(step) else { return }
        checklist.complete(step)
        UserDefaults.standard.set(checklist.storedCompleted, forKey: Self.completedKey)
    }

    func setHidden(_ hidden: Bool) {
        guard checklist.isHidden != hidden else { return }
        checklist.isHidden = hidden
        UserDefaults.standard.set(hidden, forKey: Self.hiddenKey)
    }
}
