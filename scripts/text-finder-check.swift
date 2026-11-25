// Self-check for the find bar matcher (top-level code, so compile it as main.swift):
//   cp scripts/text-finder-check.swift /tmp/main.swift && swiftc -O desktop/Utilities/TextFinder.swift /tmp/main.swift -o /tmp/tfc && /tmp/tfc [big-file]
import Foundation

func expect(_ ok: Bool, _ what: String) { if !ok { print("FAIL:", what); exit(1) } }
func find(_ q: String, _ o: TextFinder.Options = .init(), in s: String) -> [NSRange] { try! ((try! TextFinder(query: q, options: o))!.matches(in: s as NSString)) }

let s = "Foo foo food (x) a.b"
expect(find("foo", in: s).count == 3, "case-insensitive plain")
expect(find("foo", .init(matchCase: true), in: s).count == 2, "match case")
expect(find("foo", .init(wholeWords: true), in: s).count == 2, "whole words")
expect(find("(x)", in: s) == [NSRange(location: 13, length: 3)], "plain text is literal")
expect(find("a.b", in: "axb a.b") == [NSRange(location: 4, length: 3)], "dot is literal without regex")
expect(find("f\\w+", .init(regex: true), in: s).count == 3, "regex")
expect(find("x*", .init(regex: true), in: "ab").isEmpty, "empty matches skipped")
expect((try? TextFinder(query: "(", options: .init(regex: true))) == nil, "invalid regex throws")
expect((try! TextFinder(query: "", options: .init())) == nil, "empty query")
let f = (try! TextFinder(query: "foo", options: .init()))!
expect(try! f.next(in: s as NSString, from: 5) == NSRange(location: 8, length: 3), "next from caret")
expect(try! f.next(in: s as NSString, from: 15) == NSRange(location: 0, length: 3), "next wraps")
let r = (try! TextFinder(query: "(\\w)=(\\w)", options: .init(regex: true)))!
expect(try! r.replacements(in: "a=b c=d", template: "$2=$1").map(\.text) == ["b=a", "d=c"], "regex template")
expect(try! f.replacements(in: "foo", template: "$1\\").map(\.text) == ["$1\\"], "plain template is literal")
expect(try! f.matches(in: "foo foo foo", limit: 2).count == 2, "limit")

let slow = (try! TextFinder(query: "^(a+)+$", options: .init(regex: true)))!
let evil = (String(repeating: "a", count: 40) + "!") as NSString
let started = Date()
expect((try? slow.matches(in: evil)) == nil, "catastrophic regex times out")
expect(Date().timeIntervalSince(started) < TextFinder.timeLimit + 0.5, "timeout is prompt")
expect((try? slow.next(in: evil, from: 0)) == nil, "next times out")
expect((try? slow.replacements(in: evil, template: "")) == nil, "replace all times out")
expect((try? f.matches(in: "foo", isCancelled: { true })) == nil, "cancelled search stops")
expect(try! r.replacement(for: NSRange(location: 4, length: 3), in: "a=b c=d", template: "$2=$1") == "d=c", "single replacement")

if CommandLine.arguments.count > 1, let big = try? String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8) {
    let t0 = Date()
    let n = try! (try! TextFinder(query: "e", options: .init()))!.matches(in: big as NSString, limit: TextFinder.maxMatches + 1).count
    let t1 = Date()
    let all = try! (try! TextFinder(query: "e", options: .init()))!.matches(in: big as NSString).count
    print("perf: capped \(n) in \(Int(t1.timeIntervalSince(t0) * 1000)) ms; all \(all) in \(Int(Date().timeIntervalSince(t1) * 1000)) ms")
}
print("ok")
