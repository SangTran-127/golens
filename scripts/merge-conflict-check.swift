// Self-check for conflict resolution text (top-level code, so compile it as main.swift):
//   T=$(mktemp -d) && cp scripts/merge-conflict-check.swift $T/main.swift && swiftc desktop/Views/Editor/MergeConflictScanner.swift desktop/Views/Editor/MergeEditorModel.swift $T/main.swift -o $T/mcc && $T/mcc
import Foundation

var failures = 0

func expect(_ ok: Bool, _ what: String) {
    if !ok {
        print("FAIL:", what)
        failures += 1
    }
}

func resolved(_ source: String, _ resolution: MergeConflictResolution) -> String {
    let text = source as NSString
    let regions = MergeConflictScanner.scan(text)
    return MergeConflictScanner.replacement(for: regions[0], resolution: resolution, in: text)
}

expect(resolved("<<<<<<< HEAD\r\na\r\n=======\r\nb\r\n>>>>>>> x", .right) == "b", "CRLF, end marker without line break, choose right")
expect(resolved("<<<<<<< HEAD\r\na\r\n=======\r\nb\r\n>>>>>>> x\r\n", .right) == "b\r\n", "CRLF, end marker with line break keeps it")
expect(resolved("<<<<<<< HEAD\r\na\r\n=======\r\nb\r\n>>>>>>> x", .leftThenRight) == "a\r\nb", "CRLF, both, end marker without line break")
expect(resolved("<<<<<<< HEAD\na\n=======\nb\n>>>>>>> x", .leftThenRight) == "a\nb", "LF, both, end marker without line break")
expect(resolved("<<<<<<< HEAD\na\n=======\nb\n>>>>>>> x\n", .left) == "a\n", "LF, end marker with line break keeps it")
expect(MergeConflictResolution.left.tooltip(currentLabel: "", incomingLabel: "feature") == "Keep your version (HEAD)", "merge wording, left")
expect(MergeConflictResolution.left.tooltip(currentLabel: "", incomingLabel: "feature", isRebase: true) == "Keep the upstream version (HEAD)", "rebase wording, left")
expect(MergeConflictResolution.right.tooltip(currentLabel: "", incomingLabel: "feature", isRebase: true) == "Keep your commit (feature)", "rebase wording, right")

let three = "package main\n\n<<<<<<< HEAD\nfunc a() int { return 1 }\n=======\nfunc a() int { return 2 }\n>>>>>>> feature\n\nfunc mid() {}\n<<<<<<< HEAD\nvar x = 1\n||||||| base\nvar x = 0\n=======\nvar x = 2\n>>>>>>> feature\n\nfunc tail() {}\n"
var doc = MergeEditorDocument(text: three)
expect(doc.conflicts.count == 2 && doc.segments.count == 5, "merge editor splits common text and conflicts: \(doc.segments.count) segments")
expect(doc.conflicts[1].base == "var x = 0\n" && doc.conflicts[0].base == nil, "merge editor keeps the diff3 base")
expect(doc.mergedText == three, "an untouched merge keeps every marker")
doc.choose(.left, for: 0)
expect(doc.resolvedCount == 1 && !doc.isFullyResolved, "one of two resolved")
expect(doc.mergedText.contains("func a() int { return 1 }\n\nfunc mid") && doc.mergedText.contains("<<<<<<< HEAD\nvar x = 1"), "choosing left replaces only the first conflict")
doc.edit("var x = 3", for: 1)
expect(doc.isFullyResolved && doc.displayText(for: 1) == "var x = 3", "editing the result resolves the conflict")
expect(doc.mergedText == "package main\n\nfunc a() int { return 1 }\n\nfunc mid() {}\nvar x = 3\n\nfunc tail() {}\n", "merged text: \(doc.mergedText.debugDescription)")
expect(doc.replacements.count == 2 && doc.replacements[0].text == "func a() int { return 1 }\n", "replacements for the editor buffer")
doc.chooseAll(.rightThenLeft)
expect(doc.mergedText.contains("func a() int { return 2 }\nfunc a() int { return 1 }") && doc.conflicts.allSatisfy { $0.choice == .rightThenLeft }, "accept all right then left")
doc.reset(0)
expect(doc.resolvedCount == 1 && doc.mergedText.contains("<<<<<<< HEAD\nfunc a()"), "reset puts the markers back")
let crlf = MergeEditorDocument(text: "a\r\n<<<<<<< HEAD\r\nl\r\n=======\r\nr\r\n>>>>>>> x")
var crlfDoc = crlf
crlfDoc.choose(.right, for: 0)
expect(crlfDoc.mergedText == "a\r\nr", "a last conflict without a line break stays without one: \(crlfDoc.mergedText.debugDescription)")

if failures == 0 {
    print("PASS")
} else {
    exit(1)
}
