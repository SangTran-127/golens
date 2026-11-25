import Foundation

func response(_ status: Int, _ body: String, json: Bool = true) -> HTTPResponseDTO {
    let data = """
    {"status":\(status),"statusText":"OK","protocol":"HTTP/1.1","headers":[{"name":"Content-Type","value":"application/json; charset=utf-8"},{"name":"Set-Cookie","value":"a=1"},{"name":"Set-Cookie","value":"b=2"}],"body":\(String(data: try! JSONEncoder().encode(body), encoding: .utf8)!),"contentType":"application/json; charset=utf-8","isJSON":\(json),"size":\(body.utf8.count),"truncated":false,"timing":{"dnsMs":0,"connectMs":0,"tlsMs":0,"firstByteMs":1,"totalMs":2}}
    """
    return try! JSONDecoder().decode(HTTPResponseDTO.self, from: Data(data.utf8))
}

var failures = 0
func check(_ cond: Bool, _ msg: String) {
    if !cond { failures += 1; print("FAIL:", msg) } else { print("ok:", msg) }
}

let script1 = """
client.global.set("token", response.body.token);
client.global.set("user", response.body.user);
client.test("status is 200", function () {
  client.assert(response.status === 200, "status 200");
  client.assert(response.headers.valueOf("content-type").indexOf("json") > 0, "json content type");
});
client.test("has id", function () {
  client.assert(response.body.user.id === 7, "id is 7");
  client.assert(response.body.user.id === 8, "id is 8");
});
client.log("cookies", response.headers.valuesOf("set-cookie"));
client.log(response.contentType.mimeType, response.contentType.charset, client.global.get("missing"));
"""
let o1 = HTTPScriptRunner.run(script: script1, response: response(200, #"{"token":"abc","user":{"id":7}}"#), globals: ["keep": "1"])
check(o1.error == nil, "no script error: \(o1.error ?? "")")
check(o1.globals["token"] == "abc", "token stored")
check(o1.globals["user"] == #"{"id":7}"#, "object stored as JSON")
check(o1.globals["keep"] == "1", "existing global kept")
check(o1.tests.count == 2, "two tests")
check(o1.tests[0].passed && o1.tests[0].assertions.count == 2, "first test passed with 2 assertions")
check(!o1.tests[1].passed && o1.tests[1].message == "id is 8" && o1.tests[1].assertions.map(\.passed) == [true, false], "second test failed on id is 8")
check(o1.logs == [#"cookies ["a=1","b=2"]"#, "application/json utf-8 null"], "logs: \(o1.logs)")

let o2 = HTTPScriptRunner.run(script: "client.assert(response.status === 201, 'created');\nclient.global.set('after', 'x');", response: response(200, "plain", json: false), globals: [:])
check(o2.error == nil, "top-level assert is not a script error")
check(o2.tests.count == 1 && !o2.tests[0].passed && o2.tests[0].name == "created", "top-level assert recorded as failed")
check(o2.globals["after"] == nil, "script stops after failed top-level assert")

let o3 = HTTPScriptRunner.run(script: "var x = 1;\nundefinedThing.call();", response: response(200, "{}"), globals: [:])
check(o3.error?.contains("ReferenceError") == true, "reference error reported: \(o3.error ?? "nil")")
check(o3.errorLine == 2, "error line 2: \(String(describing: o3.errorLine))")

let o4 = HTTPScriptRunner.run(script: "if (response.body === 'plain') client.global.set('s', response.body); client.global.clear('gone'); client.global.set('n', 5);", response: response(200, "plain", json: false), globals: ["gone": "1"])
check(o4.globals["s"] == "plain" && o4.globals["gone"] == nil && o4.globals["n"] == "5", "string body, clear, number coerced")

let o5 = HTTPScriptRunner.run(script: "client.test('throws', function () { throw new Error('boom') });", response: response(500, "{}"), globals: [:])
check(o5.tests.first?.passed == false && o5.tests.first?.message == "boom", "exception inside test fails that test")

print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
