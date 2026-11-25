import Foundation
import JavaScriptCore

enum HTTPScriptRunner {
    private static let prelude = """
    var __currentTest = null;
    var client = {
      global: {
        set: function (name, value) {
          var text = (value !== null && typeof value === 'object') ? JSON.stringify(value) : String(value);
          __globalSet(String(name), text);
        },
        get: function (name) { var v = __globalGet(String(name)); return v === undefined ? null : v; },
        clear: function (name) { __globalClear(String(name)); },
        clearAll: function () { __globalClearAll(); },
        isEmpty: function () { return __globalIsEmpty(); }
      },
      test: function (name, fn) {
        var previous = __currentTest;
        __currentTest = String(name);
        __testBegin(__currentTest);
        try {
          fn();
          __testEnd(__currentTest, true, '');
        } catch (e) {
          __testEnd(__currentTest, false, (e && e.message !== undefined) ? String(e.message) : String(e));
        } finally {
          __currentTest = previous;
        }
      },
      assert: function (condition, message) {
        var text = message === undefined ? 'Assertion failed' : String(message);
        var passed = !!condition;
        __assertion(__currentTest === null ? '' : __currentTest, text, passed);
        if (!passed) {
          var err = new Error(text);
          err.__golensAssert = true;
          throw err;
        }
      },
      log: function () {
        var parts = [];
        for (var i = 0; i < arguments.length; i++) {
          var a = arguments[i];
          parts.push((a !== null && typeof a === 'object') ? JSON.stringify(a) : String(a));
        }
        __log(parts.join(' '));
      },
      exit: function () { var e = new Error('exit'); e.__golensExit = true; throw e; }
    };
    var response = (function () {
      var raw = JSON.parse(__responseJSON);
      var headers = raw.headers || [];
      function matches(name) {
        var key = String(name).toLowerCase();
        return headers.filter(function (h) { return h.name.toLowerCase() === key; }).map(function (h) { return h.value; });
      }
      var body = raw.body;
      if (raw.isJSON) { try { body = JSON.parse(raw.body); } catch (e) {} }
      var ct = raw.contentType || '';
      var semi = ct.indexOf(';');
      var charsetMatch = /charset=([^;]+)/i.exec(ct);
      return {
        status: raw.status,
        body: body,
        headers: {
          valueOf: function (name) { var v = matches(name); return v.length ? v[0] : null; },
          valuesOf: function (name) { return matches(name); }
        },
        contentType: {
          mimeType: (semi >= 0 ? ct.substring(0, semi) : ct).trim(),
          charset: charsetMatch ? charsetMatch[1].trim() : 'utf-8'
        }
      };
    })();
    """

    private struct ResponsePayload: Encodable {
        let status: Int
        let headers: [[String: String]]
        let body: String
        let isJSON: Bool
        let contentType: String
    }

    static func run(script: String, response: HTTPResponseDTO, globals: [String: String]) -> HTTPScriptOutcome {
        var outcome = HTTPScriptOutcome(globals: globals)
        guard let context = JSContext() else {
            outcome.error = "JavaScript is not available on this Mac."
            return outcome
        }
        var exception: JSValue?
        context.exceptionHandler = { _, value in exception = value }

        var testOrder: [String] = []
        var testAssertions: [String: [HTTPAssertionResult]] = [:]
        var testResults: [String: (Bool, String)] = [:]
        var topLevel: [HTTPTestResult] = []

        let globalSet: @convention(block) (String, String) -> Void = { name, value in outcome.globals[name] = value }
        let globalGet: @convention(block) (String) -> Any = { name in outcome.globals[name] ?? NSNull() }
        let globalClear: @convention(block) (String) -> Void = { name in outcome.globals[name] = nil }
        let globalClearAll: @convention(block) () -> Void = { outcome.globals.removeAll() }
        let globalIsEmpty: @convention(block) () -> Bool = { outcome.globals.isEmpty }
        let log: @convention(block) (String) -> Void = { line in outcome.logs.append(line) }
        let testBegin: @convention(block) (String) -> Void = { name in
            if testAssertions[name] == nil { testOrder.append(name) }
            testAssertions[name, default: []] = testAssertions[name] ?? []
        }
        let testEnd: @convention(block) (String, Bool, String) -> Void = { name, passed, message in
            testResults[name] = (passed, message)
        }
        let assertion: @convention(block) (String, String, Bool) -> Void = { test, message, passed in
            if test.isEmpty {
                topLevel.append(HTTPTestResult(name: message, passed: passed, message: passed ? "" : message, assertions: []))
            } else {
                testAssertions[test, default: []].append(HTTPAssertionResult(message: message, passed: passed))
            }
        }

        context.setObject(globalSet, forKeyedSubscript: "__globalSet" as NSString)
        context.setObject(globalGet, forKeyedSubscript: "__globalGet" as NSString)
        context.setObject(globalClear, forKeyedSubscript: "__globalClear" as NSString)
        context.setObject(globalClearAll, forKeyedSubscript: "__globalClearAll" as NSString)
        context.setObject(globalIsEmpty, forKeyedSubscript: "__globalIsEmpty" as NSString)
        context.setObject(log, forKeyedSubscript: "__log" as NSString)
        context.setObject(testBegin, forKeyedSubscript: "__testBegin" as NSString)
        context.setObject(testEnd, forKeyedSubscript: "__testEnd" as NSString)
        context.setObject(assertion, forKeyedSubscript: "__assertion" as NSString)

        let payload = ResponsePayload(
            status: response.status,
            headers: response.headers.map { ["name": $0.name, "value": $0.value] },
            body: response.body,
            isJSON: response.isJSON,
            contentType: response.contentType
        )
        let json = (try? JSONEncoder().encode(payload)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        context.setObject(json, forKeyedSubscript: "__responseJSON" as NSString)

        context.evaluateScript(prelude)
        if let preludeError = exception {
            outcome.error = "GoLens could not prepare the handler: \(preludeError.toString() ?? "unknown error")"
            return outcome
        }

        context.evaluateScript(script, withSourceURL: URL(string: "golens-handler://response.js"))
        if let thrown = exception {
            let isAssert = thrown.objectForKeyedSubscript("__golensAssert")?.toBool() == true
            let isExit = thrown.objectForKeyedSubscript("__golensExit")?.toBool() == true
            if !isAssert && !isExit {
                let name = thrown.objectForKeyedSubscript("name")?.toString() ?? "Error"
                let message = thrown.objectForKeyedSubscript("message")?.toString() ?? thrown.toString() ?? ""
                outcome.error = message.isEmpty || message == "undefined" ? (thrown.toString() ?? name) : "\(name): \(message)"
                if let line = thrown.objectForKeyedSubscript("line"), line.isNumber {
                    outcome.errorLine = Int(line.toInt32())
                }
            }
        }

        var tests: [HTTPTestResult] = []
        for name in testOrder {
            let assertions = testAssertions[name] ?? []
            let (passed, message) = testResults[name] ?? (false, "The test did not finish.")
            tests.append(HTTPTestResult(name: name, passed: passed, message: passed ? "" : message, assertions: assertions))
        }
        outcome.tests = tests + topLevel
        return outcome
    }
}
