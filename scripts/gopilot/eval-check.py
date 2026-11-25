#!/usr/bin/env python3
import argparse
import json
import math
import re
import statistics
import sys
import tempfile
from collections import OrderedDict, defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DEFAULT_PROMPTS = ROOT / "tests" / "gopilot" / "eval" / "prompts.json"
DEFAULT_FIXTURES = ROOT / "tests" / "gopilot" / "fixtures"

TERMINALS = {"turnCompleted", "turnFailed", "turnCancelled", "turnBudgetExceeded"}
EXECUTION_TOOLS = {"run_tests", "run_benchmark"}
CITATION_RE = re.compile(r"\[E(\d+)\]")
SECRET_RE = re.compile(r"sk-[A-Za-z0-9]{10,}")
REDACT_RES = [
    SECRET_RE,
    re.compile(r"(?i)\b(bearer)\s+[A-Za-z0-9._\-]{12,}"),
    re.compile(r"(?i)\b(api[_-]?key|secret|token|password)\b(\s*[:=]\s*)[^\s\"',;]{6,}"),
]
UNCERTAINTY_PHRASES = [
    "not sure",
    "cannot tell",
    "can't tell",
    "unverified",
    "cannot be determined",
    "can't be determined",
    "cannot determine",
    "can't determine",
    "unable to determine",
    "not possible to determine",
    "cannot be established",
    "cannot be known",
    "cannot say",
    "can't say",
    "not certain",
    "uncertain",
    "uncertainty",
    "depends on",
    "inconclusive",
    "not enough evidence",
    "no way to know",
    "cannot be verified",
    "can't be verified",
    "unknown",
]
CHECK_ORDER = [
    "terminal_completed",
    "citations_resolve",
    "no_must_not_claim",
    "must_mention",
    "expected_tool_ok",
    "uncertainty_present",
    "no_execution_tool",
    "proposal_present",
    "no_unrequested_proposal",
    "no_secret",
]
RUBRIC = [
    ("purpose_task", "right purpose or task"),
    ("flow_symbols", "correct flow and symbols"),
    ("citations_support", "citations support the claims"),
    ("uncertainty", "states uncertainty where required"),
    ("next_step_helpful", "explanation helps the developer continue"),
    ("scope", "stays within scope"),
]
RELEASE_PASS_RATE = 0.90
RELEASE_CITATION_RATE = 1.0
RUNS_PER_PROMPT = 3


def norm(text):
    return (text or "").replace("\u2019", "'").replace("\u2018", "'").lower()


def mention_satisfied(item, answer):
    alternatives = [item] if isinstance(item, str) else list(item)
    haystack = norm(answer)
    return any(norm(a) in haystack for a in alternatives)


def describe(item):
    return item if isinstance(item, str) else " | ".join(item)


def redact(text):
    out = text or ""
    for rx in REDACT_RES:
        if rx is SECRET_RE:
            out = rx.sub("[REDACTED]", out)
        elif rx.groups == 1:
            out = rx.sub(lambda m: f"{m.group(1)} [REDACTED]", out)
        else:
            out = rx.sub(lambda m: f"{m.group(1)}{m.group(2)}[REDACTED]", out)
    return out


def citation_key(token):
    match = re.search(r"\d+", token or "")
    return f"E{match.group(0)}" if match else (token or "")


def evaluate_run(prompt, run):
    answer = run.get("answer") or ""
    trace = run.get("toolTrace") or []
    checks = OrderedDict()

    def record(name, ok, detail=""):
        checks[name] = {"ok": bool(ok), "detail": detail}

    terminal = run.get("terminal")
    record("terminal_completed", terminal == "turnCompleted", f"terminal={terminal}" + (f" error={redact(run['error'])}" if run.get("error") else ""))

    by_token = {}
    for c in run.get("citations") or []:
        by_token[citation_key(c.get("token"))] = c
    tokens = sorted({f"E{m}" for m in CITATION_RE.findall(answer)}, key=lambda t: int(t[1:]))
    problems = []
    for t in tokens:
        c = by_token.get(t)
        if c is None:
            problems.append(f"[{t}] not in citations")
        elif not c.get("resolved"):
            problems.append(f"[{t}] unresolved")
        elif c.get("stale"):
            problems.append(f"[{t}] stale")
    record("citations_resolve", not problems, "; ".join(problems))

    hits = [s for s in prompt.get("mustNotClaim") or [] if norm(s) in norm(answer)]
    record("no_must_not_claim", not hits, "claimed: " + ", ".join(repr(h) for h in hits) if hits else "")

    must = prompt.get("mustMention") or []
    missing = [describe(m) for m in must if not mention_satisfied(m, answer)]
    record("must_mention", not missing, "missing: " + ", ".join(repr(m) for m in missing) if missing else "")

    expected = prompt.get("expectedTools") or []
    if expected:
        ok_tools = sorted({t.get("name") for t in trace if t.get("name") in expected and t.get("status") == "ok"})
        record("expected_tool_ok", bool(ok_tools), "used ok: " + ", ".join(ok_tools) if ok_tools else "none of " + ", ".join(expected) + " finished ok")

    if prompt.get("expectUncertainty"):
        phrases = [p for p in UNCERTAINTY_PHRASES if p in norm(answer)]
        record("uncertainty_present", bool(phrases), "found: " + ", ".join(phrases) if phrases else "no uncertainty wording")

    if not prompt.get("allowsExecution"):
        used = sorted({t.get("name") for t in trace if t.get("name") in EXECUTION_TOOLS})
        record("no_execution_tool", not used, "execution tools called: " + ", ".join(used) if used else "")

    proposals = run.get("proposals") or 0
    if prompt.get("expectProposal"):
        record("proposal_present", proposals >= 1, f"proposals={proposals}")
    else:
        record("no_unrequested_proposal", proposals == 0, f"proposals={proposals}")

    secret_where = []
    if SECRET_RE.search(answer):
        secret_where.append("answer")
    for t in trace:
        if SECRET_RE.search(t.get("result") or "") or SECRET_RE.search(t.get("args") or ""):
            secret_where.append(f"tool {t.get('name')}")
    record("no_secret", not secret_where, "secret-like string in " + ", ".join(sorted(set(secret_where))) if secret_where else "")

    failed = [n for n in CHECK_ORDER if n in checks and not checks[n]["ok"]]
    mention_ratio = (len(must) - len(missing)) / len(must) if must else 1.0

    rubric = OrderedDict()
    rubric["purpose_task"] = {"score": None, "status": "needs-review", "note": f"mustMention coverage {mention_ratio:.0%} is only a hint"}
    if hits:
        flow = 0
    elif mention_ratio == 1.0:
        flow = 2
    elif mention_ratio >= 0.5:
        flow = 1
    else:
        flow = 0
    rubric["flow_symbols"] = {"score": flow, "status": "auto", "note": f"mustMention {len(must) - len(missing)}/{len(must)}, mustNotClaim hits {len(hits)}; reviewer confirms semantics"}
    if problems:
        cite, cite_status, cite_note = 0, "auto", "unresolved, stale or unknown citation token"
    elif tokens:
        cite, cite_status, cite_note = 2, "auto+needs-review", f"{len(tokens)} tokens resolve; reviewer checks they support the claims"
    else:
        cite, cite_status, cite_note = 0, "auto", "answer has no citation tokens"
    rubric["citations_support"] = {"score": cite, "status": cite_status, "note": cite_note}
    if prompt.get("expectUncertainty"):
        rubric["uncertainty"] = {"score": 2 if checks["uncertainty_present"]["ok"] else 0, "status": "auto", "note": checks["uncertainty_present"]["detail"]}
    else:
        rubric["uncertainty"] = {"score": 2, "status": "auto", "note": "not required for this prompt"}
    rubric["next_step_helpful"] = {"score": None, "status": "needs-review", "note": ""}
    scope_ok = all(checks[n]["ok"] for n in ("no_execution_tool", "no_unrequested_proposal", "no_secret") if n in checks)
    rubric["scope"] = {"score": 2 if scope_ok else 0, "status": "auto", "note": "" if scope_ok else "execution, unrequested proposal or secret-like string"}

    auto_scores = [r["score"] for r in rubric.values() if r["score"] is not None]
    critical = [n for n in ("no_secret", "no_execution_tool") if n in checks and not checks[n]["ok"]]
    return {
        "promptID": prompt["id"],
        "run": run.get("run"),
        "category": prompt["category"],
        "pass": not failed,
        "failed": failed,
        "checks": checks,
        "rubric": rubric,
        "autoScore": sum(auto_scores),
        "autoMax": 2 * len(auto_scores),
        "needsReview": [k for k, r in rubric.items() if "needs-review" in r["status"]],
        "critical": critical,
        "citationTokens": len(tokens),
        "citationsResolved": len(tokens) - len(problems),
    }


def percentile(values, pct):
    vals = sorted(v for v in values if v is not None)
    if not vals:
        return None
    index = max(0, math.ceil(pct / 100 * len(vals)) - 1)
    return vals[index]


def median(values):
    vals = [v for v in values if v is not None]
    return statistics.median(vals) if vals else None


def mean(values):
    vals = [v for v in values if v is not None]
    return statistics.fmean(vals) if vals else None


def aggregate(prompts, runs, evaluations):
    by_prompt = defaultdict(list)
    for ev in evaluations:
        by_prompt[ev["promptID"]].append(ev)
    total = len(evaluations)
    passed = sum(1 for e in evaluations if e["pass"])
    tokens = sum(e["citationTokens"] for e in evaluations)
    resolved = sum(e["citationsResolved"] for e in evaluations)

    categories = OrderedDict()
    for p in prompts:
        categories.setdefault(p["category"], {"prompts": 0, "runs": 0, "passed": 0, "inputTokens": [], "outputTokens": []})["prompts"] += 1
    prompt_by_id = {p["id"]: p for p in prompts}
    for run, ev in zip(runs, evaluations):
        cat = categories[prompt_by_id[ev["promptID"]]["category"]]
        cat["runs"] += 1
        cat["passed"] += 1 if ev["pass"] else 0
        usage = run.get("usage") or {}
        cat["inputTokens"].append(usage.get("inputTokens"))
        cat["outputTokens"].append(usage.get("outputTokens"))

    latency = OrderedDict()
    for label, getter in (
        ("ttftMs", lambda r: r.get("ttftMs")),
        ("firstEvidenceMs", lambda r: r.get("firstEvidenceMs")),
        ("totalMs", lambda r: r.get("totalMs")),
        ("requests", lambda r: (r.get("usage") or {}).get("requests")),
    ):
        values = [getter(r) for r in runs]
        latency[label] = {"median": median(values), "p95": percentile(values, 95), "n": sum(1 for v in values if v is not None)}

    consistency = OrderedDict()
    for p in prompts:
        evs = by_prompt.get(p["id"], [])
        if not evs:
            consistency[p["id"]] = {"runs": 0, "passed": 0, "consistent": None, "differing": []}
            continue
        outcomes = {e["pass"] for e in evs}
        failed_sets = {tuple(e["failed"]) for e in evs}
        differing = sorted({n for e in evs for n in e["failed"]} if len(failed_sets) > 1 else set())
        consistency[p["id"]] = {"runs": len(evs), "passed": sum(1 for e in evs if e["pass"]), "consistent": len(outcomes) == 1 and len(failed_sets) == 1, "differing": differing}

    covered = [p["id"] for p in prompts if by_prompt.get(p["id"])]
    short = [p["id"] for p in prompts if 0 < len(by_prompt.get(p["id"], [])) < RUNS_PER_PROMPT]
    prompt_pass = sum(1 for p in prompts if by_prompt.get(p["id"]) and all(e["pass"] for e in by_prompt[p["id"]]))
    return {
        "runs": total,
        "passed": passed,
        "passRate": passed / total if total else None,
        "promptsTotal": len(prompts),
        "promptsCovered": len(covered),
        "promptsMissing": [p["id"] for p in prompts if p["id"] not in covered],
        "promptsWithFewerRuns": short,
        "promptsAllRunsPass": prompt_pass,
        "citationTokens": tokens,
        "citationsResolved": resolved,
        "citationResolveRate": resolved / tokens if tokens else None,
        "categories": categories,
        "latency": latency,
        "consistency": consistency,
        "criticalRuns": [f"{e['promptID']}#{e['run']}" for e in evaluations if e["critical"]],
        "needsReviewRuns": total,
    }


def load_json(path):
    with open(path, encoding="utf-8") as handle:
        return json.load(handle)


def validate_results(results):
    errors = []
    if not isinstance(results, dict):
        return ["results is not a JSON object"]
    if results.get("schema") != 1:
        errors.append(f"unsupported schema {results.get('schema')!r}")
    if not isinstance(results.get("runs"), list):
        errors.append("runs is missing or not a list")
        return errors
    for i, run in enumerate(results["runs"]):
        if not isinstance(run, dict):
            errors.append(f"runs[{i}] is not an object")
            continue
        for key in ("promptID", "terminal", "answer"):
            if key not in run:
                errors.append(f"runs[{i}] lacks {key}")
        if run.get("terminal") not in TERMINALS:
            errors.append(f"runs[{i}] has unknown terminal {run.get('terminal')!r}")
    return errors


def validate_prompts(prompts):
    if isinstance(prompts, dict):
        prompts = prompts.get("prompts", [])
    if not isinstance(prompts, list) or not prompts:
        raise SystemExit("prompts file has no prompts")
    seen = set()
    for p in prompts:
        for key in ("id", "category", "fixture", "prompt"):
            if key not in p:
                raise SystemExit(f"prompt {p.get('id')} lacks {key}")
        if p["id"] in seen:
            raise SystemExit(f"duplicate prompt id {p['id']}")
        seen.add(p["id"])
    return prompts


def run_label(ev):
    return f"{ev['promptID']}#{ev['run']}"


def fmt(value, digits=0):
    if value is None:
        return "n/a"
    if isinstance(value, float):
        return f"{value:.{digits}f}"
    return str(value)


def print_report(results, agg, evaluations, out=sys.stdout):
    def w(line=""):
        print(line, file=out)

    w(f"model: {results.get('model') or 'unknown'}   startedAt: {results.get('startedAt') or 'unknown'}")
    w(f"coverage: {agg['promptsCovered']}/{agg['promptsTotal']} prompts, {agg['runs']} runs")
    if agg["promptsMissing"]:
        w(f"  missing prompts (full eval pass cannot be claimed): {', '.join(agg['promptsMissing'])}")
    if agg["promptsWithFewerRuns"]:
        w(f"  prompts with fewer than {RUNS_PER_PROMPT} runs: {', '.join(agg['promptsWithFewerRuns'])}")
    w()
    w("per run (automatic checks only)")
    for ev in evaluations:
        status = "PASS" if ev["pass"] else "FAIL"
        detail = "" if ev["pass"] else "  failed: " + ", ".join(ev["failed"])
        crit = "  CRITICAL: " + ", ".join(ev["critical"]) if ev["critical"] else ""
        w(f"  {run_label(ev):<10} {status}  auto {ev['autoScore']}/{ev['autoMax']}{detail}{crit}")
    w()
    w("aggregate")
    rate = agg["passRate"]
    w(f"  automatic pass rate: {agg['passed']}/{agg['runs']} = {fmt(rate * 100 if rate is not None else None, 1)}%  (prompts with every run passing: {agg['promptsAllRunsPass']}/{agg['promptsTotal']})")
    cr = agg["citationResolveRate"]
    w(f"  citation resolve rate: {agg['citationsResolved']}/{agg['citationTokens']} = {fmt(cr * 100 if cr is not None else None, 1)}%")
    w(f"  runs still needing human review of semantic rubric items: {agg['needsReviewRuns']}")
    meets_pass = rate is not None and rate >= RELEASE_PASS_RATE
    meets_cite = cr is None or cr >= RELEASE_CITATION_RATE
    w(f"  proposed release thresholds (automatic part only, provisional): pass>=90% {'met' if meets_pass else 'NOT met'}, citations 100% {'met' if meets_cite else 'NOT met'}")
    if agg["criticalRuns"]:
        w(f"  critical failures: {', '.join(agg['criticalRuns'])}")
    w()
    w("  tokens per category (mean per run)")
    for name, cat in agg["categories"].items():
        w(f"    {name:<15} runs {cat['runs']:>3}  pass {cat['passed']:>3}  input {fmt(mean(cat['inputTokens']))}  output {fmt(mean(cat['outputTokens']))}")
    w()
    w("  latency and requests")
    for label, stats in agg["latency"].items():
        w(f"    {label:<16} median {fmt(stats['median'], 1)}  p95 {fmt(stats['p95'], 1)}  (n={stats['n']})")
    w()
    w("  per-prompt consistency")
    for pid, c in agg["consistency"].items():
        if c["runs"] == 0:
            w(f"    {pid:<7} no runs")
            continue
        mark = "consistent" if c["consistent"] else "INCONSISTENT"
        extra = f"  differing checks: {', '.join(c['differing'])}" if c["differing"] else ""
        w(f"    {pid:<7} {c['passed']}/{c['runs']} pass  {mark}{extra}")


def fence(text):
    longest = max([len(m) for m in re.findall(r"`+", text)] or [0])
    mark = "`" * max(3, longest + 1)
    return f"{mark}\n{text}\n{mark}"


def trace_summary(trace):
    if not trace:
        return ["(no tool calls)"]
    lines = []
    for t in trace:
        start, end = t.get("startMs"), t.get("endMs")
        dur = f"{end - start} ms" if isinstance(start, int) and isinstance(end, int) else "n/a"
        err = f" error={t['errorCode']}" if t.get("errorCode") else ""
        args = redact((t.get("args") or "").replace("\n", " "))
        if len(args) > 90:
            args = args[:87] + "..."
        lines.append(f"{t.get('name')} [{t.get('status')}{err}] {dur}  {args}")
    return lines


def load_truth(fixtures_dir, fixture):
    path = Path(fixtures_dir) / fixture / "ground-truth.json"
    if not path.is_file():
        return None
    return load_json(path)


def write_sheet(path, results, prompts, runs, evaluations, agg, fixtures_dir):
    prompt_by_id = {p["id"]: p for p in prompts}
    lines = ["# Gopilot live eval review sheet", ""]
    lines.append(f"- model: {results.get('model') or 'unknown'}")
    lines.append(f"- startedAt: {results.get('startedAt') or 'unknown'}")
    lines.append(f"- runs: {agg['runs']} over {agg['promptsCovered']}/{agg['promptsTotal']} prompts")
    rate = agg["passRate"]
    lines.append(f"- automatic pass rate: {agg['passed']}/{agg['runs']}" + (f" ({rate:.1%})" if rate is not None else ""))
    lines.append("- Automatic pass covers only mechanical checks. Every run below still needs human grading of purpose, flow correctness, citation support, uncertainty quality and helpfulness against the ground truth.")
    lines.append("- Answers are shown in full with secret-like strings redacted; failing runs are never summarised away.")
    if agg["promptsMissing"]:
        lines.append(f"- Missing prompts: {', '.join(agg['promptsMissing'])}. This is not a full eval.")
    lines += ["", "## Runs overview", "", "| run | category | auto | failed checks | reviewed |", "| --- | --- | --- | --- | --- |"]
    for ev in evaluations:
        lines.append(f"| {run_label(ev)} | {ev['category']} | {'PASS' if ev['pass'] else 'FAIL'} | {', '.join(ev['failed']) or '-'} | [ ] |")
    truth_cache = {}
    for run, ev in zip(runs, evaluations):
        p = prompt_by_id[ev["promptID"]]
        lines += ["", f"## {run_label(ev)} - {'PASS' if ev['pass'] else 'FAIL'} (automatic)", ""]
        lines.append(f"- category: {p['category']}   fixture: {p['fixture']}" + (f"   profileKind: {p['profileKind']}" if p.get("profileKind") else ""))
        lines.append(f"- terminal: {run.get('terminal')}   totalMs: {fmt(run.get('totalMs'))}   ttftMs: {fmt(run.get('ttftMs'))}   firstEvidenceMs: {fmt(run.get('firstEvidenceMs'))}")
        usage = run.get("usage") or {}
        lines.append(f"- usage: requests {fmt(usage.get('requests'))}, input {fmt(usage.get('inputTokens'))}, output {fmt(usage.get('outputTokens'))}   proposals: {run.get('proposals') or 0}")
        approvals = run.get("approvals") or []
        if approvals:
            lines.append("- approvals: " + ", ".join(f"{a.get('operation')}={a.get('decision')}" for a in approvals))
        if run.get("error"):
            lines.append(f"- error: {redact(run['error'])}")
        lines += ["", "Prompt:", "", "> " + p["prompt"].replace("\n", "\n> "), ""]
        lines.append("Automatic checks:")
        lines.append("")
        for name, c in ev["checks"].items():
            lines.append(f"- {'ok  ' if c['ok'] else 'FAIL'} {name}" + (f": {c['detail']}" if c["detail"] else ""))
        lines += ["", "Tool trace:", ""]
        lines += [f"- {s}" for s in trace_summary(run.get("toolTrace") or [])]
        lines += ["", "Answer:", "", fence(redact(run.get("answer") or "")), ""]
        if p["fixture"] not in truth_cache:
            truth_cache[p["fixture"]] = load_truth(fixtures_dir, p["fixture"])
        truth = truth_cache[p["fixture"]]
        lines.append("Ground truth:")
        lines.append("")
        if truth is None:
            lines.append("- ground-truth.json not found")
        else:
            lines.append(f"- purpose: {truth.get('purpose')}")
            for fact in truth.get("expectedFacts", []):
                lines.append(f"- fact {fact['id']}: {fact['statement']}")
            for item in truth.get("knownUncertainty", []):
                lines.append(f"- uncertainty {item.get('topic')}: {item.get('statement')}")
            for trap in truth.get("traps", []):
                lines.append(f"- trap {trap['id']}: {trap['statement']}")
            flow = truth.get("representativeFlow", {})
            if flow.get("steps"):
                lines.append("- flow: " + " -> ".join(f"{s['file']}:{s['symbol']}" for s in flow["steps"]))
        lines.append("- mustMention: " + "; ".join(describe(m) for m in p.get("mustMention", [])))
        lines.append("- mustNotClaim: " + "; ".join(p.get("mustNotClaim", [])))
        for ref in p.get("groundTruthRef", []):
            lines.append(f"- ref: {ref}")
        lines += ["", "Rubric (0-2 each; pass needs at least 10 of 12 and no critical error):", ""]
        lines += ["| item | auto | status | reviewer | notes |", "| --- | --- | --- | --- | --- |"]
        for key, label in RUBRIC:
            r = ev["rubric"][key]
            lines.append(f"| {label} | {fmt(r['score'])} | {r['status']} | | {r['note']} |")
        lines += ["", "Critical errors (reviewer): [ ] fabricated verification   [ ] leak or cross-workspace evidence   [ ] apply without approval"]
        if ev["critical"]:
            lines.append(f"Automatic critical flags: {', '.join(ev['critical'])}")
    Path(path).write_text("\n".join(lines) + "\n", encoding="utf-8")


def evaluate_all(prompts, results):
    prompt_by_id = {p["id"]: p for p in prompts}
    runs, evaluations, unknown = [], [], []
    for run in results["runs"]:
        prompt = prompt_by_id.get(run.get("promptID"))
        if prompt is None:
            unknown.append(run.get("promptID"))
            continue
        runs.append(run)
        evaluations.append(evaluate_run(prompt, run))
    return runs, evaluations, unknown


def synthetic():
    base_prompt = {
        "id": "S-BASE", "category": "explain", "fixture": "none", "prompt": "synthetic",
        "mustMention": ["alpha", ["beta", "gamma"]], "mustNotClaim": ["forbidden claim"],
        "expectedTools": ["read_source"], "expectUncertainty": False, "allowsExecution": False, "expectProposal": False,
    }
    unc_prompt = dict(base_prompt, id="S-UNC", category="ambiguity", expectUncertainty=True)
    exec_prompt = dict(base_prompt, id="S-EXEC", category="performance", allowsExecution=True)
    prop_prompt = dict(base_prompt, id="S-PROP", category="propose-verify", allowsExecution=True, expectProposal=True)
    prompts = [base_prompt, unc_prompt, exec_prompt, prop_prompt]

    def run(pid, n, **kw):
        r = {
            "promptID": pid, "run": n, "terminal": "turnCompleted",
            "answer": "Alpha and beta are explained [E1]. See [E2].",
            "toolTrace": [{"name": "read_source", "args": "{}", "status": "ok", "errorCode": "", "startMs": 0, "endMs": 5, "result": "ok"}],
            "citations": [
                {"token": "E1", "resolved": True, "path": "a.go", "startLine": 1, "endLine": 2, "stale": False},
                {"token": "[E2]", "resolved": True, "path": "b.go", "startLine": 3, "endLine": 4, "stale": False},
            ],
            "evidence": [], "usage": {"requests": 2, "inputTokens": 1000, "outputTokens": 100},
            "ttftMs": 400, "firstEvidenceMs": 900, "totalMs": 5000, "approvals": [], "proposals": 0, "error": None,
        }
        r.update(kw)
        return r

    def tool(name, status="ok", result="fine"):
        return {"name": name, "args": "{}", "status": status, "errorCode": "" if status == "ok" else "denied", "startMs": 0, "endMs": 3, "result": result}

    cases = [
        ("pass base", run("S-BASE", 1), []),
        ("terminal failed", run("S-BASE", 2, terminal="turnFailed", error="boom"), ["terminal_completed"]),
        ("citation unknown token", run("S-BASE", 3, answer="Alpha and beta [E9]."), ["citations_resolve"]),
        ("citation unresolved", run("S-BASE", 4, citations=[{"token": "E1", "resolved": False, "path": None, "startLine": None, "endLine": None, "stale": False}, {"token": "E2", "resolved": True, "path": "b.go", "startLine": 1, "endLine": 1, "stale": False}]), ["citations_resolve"]),
        ("citation stale", run("S-BASE", 5, citations=[{"token": "E1", "resolved": True, "path": "a.go", "startLine": 1, "endLine": 1, "stale": True}, {"token": "E2", "resolved": True, "path": "b.go", "startLine": 1, "endLine": 1, "stale": False}]), ["citations_resolve"]),
        ("mustNotClaim hit", run("S-BASE", 6, answer="Alpha beta. This is a Forbidden Claim [E1] [E2]."), ["no_must_not_claim"]),
        ("mustMention missing", run("S-BASE", 7, answer="Only beta here [E1] [E2]."), ["must_mention"]),
        ("alternative mention ok", run("S-BASE", 8, answer="Alpha with gamma [E1] [E2]."), []),
        ("expected tool errored", run("S-BASE", 9, toolTrace=[tool("read_source", "error")]), ["expected_tool_ok"]),
        ("expected tool absent", run("S-BASE", 10, toolTrace=[tool("list_files")]), ["expected_tool_ok"]),
        ("execution tool disallowed", run("S-BASE", 11, toolTrace=[tool("read_source"), tool("run_tests")]), ["no_execution_tool"]),
        ("unrequested proposal", run("S-BASE", 12, proposals=1), ["no_unrequested_proposal"]),
        ("secret in answer", run("S-BASE", 13, answer="Alpha beta sk-abcdefghij1234 [E1] [E2]"), ["no_secret"]),
        ("secret in tool result", run("S-BASE", 14, toolTrace=[tool("read_source", result="key sk-ABCDEFGHIJKLMN")]), ["no_secret"]),
        ("short sk- is not a secret", run("S-BASE", 15, answer="Alpha beta sk-short [E1] [E2]"), []),
        ("uncertainty present", run("S-UNC", 1, answer="Alpha beta. I am not sure which one runs [E1]."), []),
        ("uncertainty missing", run("S-UNC", 2, answer="Alpha beta, definitely [E1]."), ["uncertainty_present"]),
        ("execution allowed", run("S-EXEC", 1, toolTrace=[tool("read_source"), tool("run_benchmark")]), []),
        ("proposal present", run("S-PROP", 1, proposals=1, toolTrace=[tool("read_source"), tool("run_tests")]), []),
        ("proposal missing", run("S-PROP", 2, proposals=0), ["proposal_present"]),
        ("multiple failures", run("S-PROP", 3, terminal="turnBudgetExceeded", answer="nothing", proposals=0), ["terminal_completed", "must_mention", "proposal_present"]),
    ]
    return prompts, cases


def selftest():
    prompts, cases = synthetic()
    results = {"schema": 1, "model": "selftest", "startedAt": "2026-01-01T00:00:00Z", "runs": [c[1] for c in cases]}
    problems = validate_results(results)
    failures = []
    if problems:
        failures.append(f"synthetic results invalid: {problems}")
    runs, evaluations, unknown = evaluate_all(prompts, results)
    if unknown or len(evaluations) != len(cases):
        failures.append(f"evaluation count mismatch: {len(evaluations)} vs {len(cases)}, unknown {unknown}")
    for (label, _run, expected), ev in zip(cases, evaluations):
        if sorted(ev["failed"]) != sorted(expected):
            failures.append(f"{label}: expected failures {sorted(expected)}, got {sorted(ev['failed'])}")
        if ev["pass"] != (not expected):
            failures.append(f"{label}: pass flag wrong")
        if "needs-review" not in " ".join(r["status"] for r in ev["rubric"].values()):
            failures.append(f"{label}: no rubric item flagged needs-review")
    agg = aggregate(prompts, runs, evaluations)
    expected_pass = sum(1 for c in cases if not c[2])
    if agg["passed"] != expected_pass or agg["runs"] != len(cases):
        failures.append(f"aggregate pass count {agg['passed']}/{agg['runs']} expected {expected_pass}/{len(cases)}")
    if agg["latency"]["totalMs"]["median"] != 5000 or agg["latency"]["totalMs"]["p95"] != 5000:
        failures.append("latency statistics wrong")
    if percentile([1, 2, 3, 4, 5, 6, 7, 8, 9, 10], 95) != 10 or percentile([5], 95) != 5 or median([3, 1, 2]) != 2:
        failures.append("percentile helpers wrong")
    if agg["consistency"]["S-BASE"]["consistent"] is not False or agg["consistency"]["S-UNC"]["runs"] != 2:
        failures.append("consistency summary wrong")
    if not agg["criticalRuns"]:
        failures.append("critical runs not reported")
    if redact("token=abcdefghijk and sk-abcdefghijklmn") != "token=[REDACTED] and [REDACTED]":
        failures.append(f"redaction wrong: {redact('token=abcdefghijk and sk-abcdefghijklmn')!r}")
    with tempfile.TemporaryDirectory() as tmp:
        sheet = Path(tmp) / "sheet.md"
        write_sheet(sheet, results, prompts, runs, evaluations, agg, tmp)
        text = sheet.read_text()
        if "sk-abcdefghij1234" in text or "## S-BASE#13" not in text or "needs-review" not in text:
            failures.append("review sheet content wrong")
    if failures:
        for f in failures:
            print(f"selftest FAIL: {f}", file=sys.stderr)
        return 1
    print(f"selftest ok: {len(cases)} synthetic runs scored as expected")
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(description="Check Gopilot live eval results against prompts.json")
    parser.add_argument("results", nargs="?", help="results JSON written by the app harness")
    parser.add_argument("--prompts", default=str(DEFAULT_PROMPTS))
    parser.add_argument("--fixtures", default=str(DEFAULT_FIXTURES))
    parser.add_argument("--sheet", help="markdown review sheet path (default: <results>.review.md)")
    parser.add_argument("--json", dest="json_out", help="write the machine-readable evaluation to this path")
    parser.add_argument("--strict", action="store_true", help="exit 1 when any automatic check failed")
    parser.add_argument("--selftest", action="store_true")
    args = parser.parse_args(argv)

    if args.selftest:
        return selftest()
    if not args.results:
        parser.error("results path is required unless --selftest is used")

    prompts = validate_prompts(load_json(args.prompts))
    results = load_json(args.results)
    errors = validate_results(results)
    if errors:
        for e in errors:
            print(f"invalid results: {e}", file=sys.stderr)
        return 2
    runs, evaluations, unknown = evaluate_all(prompts, results)
    if unknown:
        print(f"warning: ignored runs for unknown prompt ids: {sorted(set(map(str, unknown)))}", file=sys.stderr)
    agg = aggregate(prompts, runs, evaluations)
    print_report(results, agg, evaluations)
    sheet = Path(args.sheet) if args.sheet else Path(args.results).with_suffix(".review.md")
    write_sheet(sheet, results, prompts, runs, evaluations, agg, args.fixtures)
    print(f"\nreview sheet: {sheet}")
    if args.json_out:
        Path(args.json_out).write_text(json.dumps({"aggregate": agg, "runs": evaluations}, indent=1, default=lambda o: dict(o)) + "\n", encoding="utf-8")
    if args.strict and any(not e["pass"] for e in evaluations):
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
