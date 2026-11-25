// Self-check for SnippetSession edit tracking (no Swift test target in this package):
//   swiftc desktop/State/SnippetSession.swift scripts/snippet-session-check/main.swift -o /tmp/snippet-check && /tmp/snippet-check
import Foundation

func stop(_ i: Int, _ s: Int, _ l: Int) -> SnippetStop {
    try! JSONDecoder().decode(SnippetStop.self, from: Data("{\"index\":\(i),\"start\":\(s),\"length\":\(l)}".utf8))
}
func check(_ ok: Bool, _ what: String, line: Int = #line) {
    if !ok { print("FAIL line \(line): \(what)"); exit(1) }
}

// Nested ${1:foo(${2:bar})}: replacing $1 removes the $2 inside it.
var nested = SnippetSession(base: 0, stops: [stop(1, 0, 8), stop(2, 4, 3)], final: -1)!
check(nested.apply(edit: NSRange(location: 0, length: 8), newLength: 1), "replace $1")
check(nested.currentRange == NSRange(location: 0, length: 1) && nested.next() == nil, "nested $2 dropped")

// Typing inside the nested $2 grows the enclosing $1 too.
var inner = SnippetSession(base: 0, stops: [stop(1, 0, 8), stop(2, 4, 3)], final: -1)!
_ = inner.next()
check(inner.apply(edit: NSRange(location: 4, length: 3), newLength: 5), "type in $2")
check(inner.currentRange == NSRange(location: 4, length: 5), "$2 grew")
check(inner.previous() == NSRange(location: 0, length: 10), "$1 grew with $2")

// Handle(${1:c string}, ${2:line string}): type over $1, accept a completion, an import lands above.
var call = SnippetSession(base: 0, stops: [stop(1, 7, 8), stop(2, 17, 11)], final: 29)!
check(call.apply(edit: NSRange(location: 7, length: 8), newLength: 3), "type ann")
check(call.apply(edit: NSRange(location: 7, length: 3), newLength: 8), "accept announce")
check(call.apply(edit: NSRange(location: 0, length: 0), newLength: 10), "import above")
check(call.currentRange == NSRange(location: 17, length: 8), "$1 after edits")

// The accepted completion brings its own placeholder: announce(${1:msg}) nests inside $1.
check(call.apply(edit: NSRange(location: 17, length: 8), newLength: 13), "expand announce(msg)")
let own = SnippetSession(base: 17, stops: [stop(1, 9, 3)], final: -1)!
check(call.nest(own) && call.currentRange == NSRange(location: 26, length: 3), "nested placeholder current")
check(call.apply(edit: NSRange(location: 26, length: 3), newLength: 1), "type over msg")
check(call.next() == NSRange(location: 30, length: 11), "Tab reaches line string, intact")
check(call.exitCaret == 42, "final caret tracked")

// An edit that cuts into a stop from outside ends the session.
var cut = SnippetSession(base: 0, stops: [stop(1, 7, 8), stop(2, 17, 11)], final: -1)!
check(!cut.apply(edit: NSRange(location: 15, length: 4), newLength: 0), "cut into $2")
print("snippet-session-check: ok")
