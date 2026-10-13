### 11.1 The writer's re-derivations, W2–W12

Each script verbatim, then its output as run on 2026-09-25 (W11's long commands are cut by the script itself).

`w2_floor_offpicture.py`:

```python
# W2: the floor tier's reach, success, hidden verification and green, on and off the picture tasks, v13 and v11.
# Usage: python3 w2_floor_offpicture.py   (paths absolute; reads the six records.jsonl only)
import json
RUNS = "/Users/jasl/Workspaces/cybros-ai.alt2/e2e/evals/runs/{}/records.jsonl"
PICTURE = {"compose-background-suite", "compose-grep-then-edit", "compose-race", "compose-race-anon", "compose-review-angles",
           "compose-three-stage-pairing", "compose-two-source-fan-in", "workflow-barrier-free-pipeline"}
FLOOR = ("deepseek/deepseek-flash", "openrouter/z-ai/glm-5.3-flash")


def records(version):
    out = []
    for fam in ("task", "compose", "workflow"):
        for line in open(RUNS.format(f"{version}-{fam}"), encoding="utf-8"):
            out.append(json.loads(line))
    return out


def tally(rows):
    v = [r["verdict"] for r in rows]
    verified = [x for x in v if x["task_pass"] is not None]
    return {"runs": len(rows), "reach": sum(bool(x["reached"]) for x in v), "succ": sum(bool(x["succeeded"]) for x in v),
            "pass": f"{sum(x['task_pass'] for x in verified)}/{len(verified)}", "green": sum(x["class"] is None for x in v)}


for version in ("2026-09-25-v13", "2026-09-24-v11"):
    floor = [r for r in records(version) if r["model"] in FLOOR]
    off = [r for r in floor if r["task"] not in PICTURE]
    print(version, "floor all:", tally(floor))
    print(version, "floor off-picture:", tally(off))
    print(version, "floor on-picture:", tally([r for r in floor if r["task"] in PICTURE]))
    fails = [f"{r['task']} {r['model'].split('/')[-1]} #{r['run']} ({'picture' if r['task'] in PICTURE else 'off-picture'})"
             for r in floor if r["verdict"]["task_pass"] is False]
    print(version, "floor verification fails:", fails)
```

Output:

```text
2026-09-25-v13 floor all: {'runs': 120, 'reach': 106, 'succ': 103, 'pass': '35/36', 'green': 95}
2026-09-25-v13 floor off-picture: {'runs': 72, 'reach': 63, 'succ': 60, 'pass': '24/24', 'green': 55}
2026-09-25-v13 floor on-picture: {'runs': 48, 'reach': 43, 'succ': 43, 'pass': '11/12', 'green': 40}
2026-09-25-v13 floor verification fails: ['compose-grep-then-edit glm-5.3-flash #1 (picture)']
2026-09-24-v11 floor all: {'runs': 114, 'reach': 95, 'succ': 89, 'pass': '34/36', 'green': 78}
2026-09-24-v11 floor off-picture: {'runs': 72, 'reach': 57, 'succ': 51, 'pass': '22/24', 'green': 41}
2026-09-24-v11 floor on-picture: {'runs': 42, 'reach': 38, 'succ': 38, 'pass': '12/12', 'green': 37}
2026-09-24-v11 floor verification fails: ['workflow-adversarial-verify glm-5.3-flash #1 (off-picture)', 'workflow-loop-until-dry glm-5.3-flash #3 (off-picture)']
```

`w3_records.py`:

```python
# W3: five record-level counts the checkers disputed, off the three v13 records.jsonl:
#   (1) two-source-fan-in's strong reds and each one's silent set; (2) which records carry `wake_passive`;
#   (3) loop-until-dry's rounds_settled per record; (4) grep-then-edit glm-5.3 #1 and #3 as recorded;
#   (5) the v13 verification fails.
# Usage: python3 w3_records.py
import json, collections
RUNS = "/Users/jasl/Workspaces/cybros-ai.alt2/e2e/evals/runs/2026-09-25-v13-{}/records.jsonl"
rows = {fam: [json.loads(l) for l in open(RUNS.format(fam), encoding="utf-8")] for fam in ("task", "compose", "workflow")}
short = lambda r: f"{r['model'].split('/')[-1]} #{r['run']}"

print("(1) compose-two-source-fan-in strong reds:")
over_read = 0
for r in rows["compose"]:
    if r["task"] == "compose-two-source-fan-in" and r["facts"]["tier"] == "strong" and r["verdict"]["class"]:
        silent = r["facts"]["score"].get("silent", [])
        over_read += "over_read" in silent
        print("   ", short(r), r["verdict"]["class"], "silent", silent, "| reason:", r["reason"][:80])
print("    over_read in", over_read, "of the strong reds")

print("(2) records carrying wake_passive:")
for fam, rs in rows.items():
    c = collections.Counter(f"{r['task']} wake_passive={r['facts']['wake_passive']}" for r in rs if "wake_passive" in r["facts"])
    print("   ", fam, dict(c) or "{}")
tm = [r for r in rows["task"] if r["task"] == "task-mail"]
print("    task-mail records", len(tm), "reached", sum(r["verdict"]["reached"] for r in tm),
      "with wake_passive", sum("wake_passive" in r["facts"] for r in tm))

print("(3) workflow-loop-until-dry rounds_settled per record:")
lud = [r for r in rows["workflow"] if r["task"] == "workflow-loop-until-dry"]
for m in ("glm-5.3", "kimi-k3", "deepseek-flash", "glm-5.3-flash"):
    print("   ", m, [r["facts"]["rounds_settled"] for r in sorted(lud, key=lambda r: r["run"]) if r["model"].endswith("/" + m)])
allr = [r["facts"]["rounds_settled"] for r in lud]
print("    range", min(allr), "-", max(allr), "; records at 20-27:", sum(20 <= x <= 27 for x in allr), "of", len(allr))

print("(4) compose-grep-then-edit glm-5.3 #1 and #3:")
for r in rows["compose"]:
    if r["task"] == "compose-grep-then-edit" and r["model"].endswith("/glm-5.3") and r["run"] in (1, 3):
        print("   ", short(r), "class", r["verdict"]["class"], "task_pass", r["verdict"]["task_pass"],
              "valid_first", r["facts"]["score"].get("valid_first"), "silent", r["facts"]["score"].get("silent"))

print("(5) v13 verification fails:")
for fam, rs in rows.items():
    for r in rs:
        if r["verdict"]["task_pass"] is False:
            print("   ", fam, r["task"], short(r), "class", r["verdict"]["class"])
```

Output:

```text
(1) compose-two-source-fan-in strong reds:
    glm-5.3 #1 model conduct silent ['over_read'] | reason: the picture is not the objective's (silent: over_read): {"nodes" => ["tool-1:too
    glm-5.3 #2 model conduct silent ['over_sync'] | reason: the picture is not the objective's (silent: over_sync): {"nodes" => ["tool-1:too
    glm-5.3 #3 model conduct silent ['over_sync', 'over_read'] | reason: the picture is not the objective's (silent: over_sync, over_read): {"nodes" => [
    kimi-k3 #1 model conduct silent ['over_read'] | reason: the picture is not the objective's (silent: over_read): {"nodes" => ["tool-1:too
    kimi-k3 #2 model conduct silent ['over_read'] | reason: the picture is not the objective's (silent: over_read): {"nodes" => ["tool-1:too
    kimi-k3 #3 model conduct silent ['over_read'] | reason: the picture is not the objective's (silent: over_read): {"nodes" => ["tool-1:too
    over_read in 5 of the strong reds
(2) records carrying wake_passive:
    task {'task-detached-receipt wake_passive=False': 12, 'task-mail wake_passive=False': 3}
    compose {}
    workflow {}
    task-mail records 12 reached 3 with wake_passive 3
(3) workflow-loop-until-dry rounds_settled per record:
    glm-5.3 [26, 27, 26]
    kimi-k3 [26, 26, 20]
    deepseek-flash [14, 15, 22]
    glm-5.3-flash [20, 26, 8]
    range 8 - 27 ; records at 20-27: 9 of 12
(4) compose-grep-then-edit glm-5.3 #1 and #3:
    glm-5.3 #1 class disagreement task_pass True valid_first True silent ['missing_steps']
    glm-5.3 #3 class disagreement task_pass True valid_first True silent ['extra_steps']
(5) v13 verification fails:
    compose compose-grep-then-edit glm-5.3-flash #1 class lane bug
    workflow workflow-adversarial-verify kimi-k3 #1 class model conduct
    workflow workflow-adversarial-verify kimi-k3 #3 class model conduct
```

`w4_artifacts.py`:

```python
# W4: four artifact reads the checkers disputed.
#   (a) compose-race glm-5.3-flash #1: its compose rows' status, result and is_error (was the first call an error?);
#   (b) task-fan-five glm-5.3-flash #1 (v13) and kimi-k3 #2 (v11): where the merged reply lives (artifact vs world logs);
#   (c) the two lane-bug artifacts' facts keys (does the stored trace carry `in_flight`?);
#   (d) barrier-free kimi-k3 #1 (v13): every bash command, to read how it normalised.
# Usage: python3 w4_artifacts.py
import json, glob, os
ART = "/Users/jasl/Workspaces/cybros-ai.alt2/e2e/artifacts/evals/"


def load(label, stem):
    return json.load(open(f"{ART}{label}/{stem}.json", encoding="utf-8"))


print("(a) compose-race glm-5.3-flash #1 compose rows:")
a = load("2026-09-25-v13-compose", "compose-race.openrouter_z-ai_glm-5.3-flash.nexus.1")
for t in a["tasks"]:
    if t.get("tool_name") == "compose":
        print("   ", t["key"], "status", t.get("status"), "is_error", t.get("is_error"), "result", json.dumps(t.get("result"))[:160])
print("    record verdict:", json.dumps(a["record"].get("verdict")), "record keys:", sorted(a["record"].keys())[:12])

print("(b) task-fan-five merged reply:")
for label, stem in (("2026-09-25-v13-task", "task-fan-five.openrouter_z-ai_glm-5.3-flash.nexus.1"),
                    ("2026-09-24-v11-task", "task-fan-five.openrouter_moonshotai_kimi-k3.nexus.2")):
    art = load(label, stem)
    text = open(f"{ART}{label}/{stem}.json", encoding="utf-8").read()
    logs = glob.glob(f"{ART}{label}/logs/{stem}/*.log")
    in_logs = [os.path.basename(p) for p in logs if "All five answers are in" in open(p, encoding="utf-8", errors="replace").read()]
    print("   ", label, stem)
    print("      facts keys:", sorted(art["facts"].keys()))
    print("      facts.reply:", json.dumps(art["facts"].get("reply"))[:160])
    print("      event types:", sorted({e.get("type") for e in art["events"]}))
    print("      'All five answers are in' in artifact json:", "All five answers are in" in text, "; in world logs:", in_logs)

print("(c) lane-bug artifacts' facts keys:")
for stem in ("compose-background-suite.openrouter_z-ai_glm-5.3.nexus.3", "compose-grep-then-edit.openrouter_z-ai_glm-5.3-flash.nexus.1"):
    art = load("2026-09-25-v13-compose", stem)
    print("   ", stem, sorted(art["facts"].keys()), "in_flight" in art["facts"])

print("(d) barrier-free kimi-k3 #1 bash commands:")
b = load("2026-09-25-v13-workflow", "workflow-barrier-free-pipeline.openrouter_moonshotai_kimi-k3.nexus.1")
for t in b["tasks"]:
    if t.get("tool_name") == "bash":
        print("   ", t["key"], json.dumps(t["tool_input"].get("command"))[:400])
```

Output:

```text
(a) compose-race glm-5.3-flash #1 compose rows:
    r2t0 status completed is_error None result {"resolved": true}
    r3t0 status completed is_error None result {"resolved": true}
    record verdict: {"reached": true, "succeeded": true, "task_pass": null, "class": null} record keys: ['adaptations', 'artifact', 'bench_digest', 'capability', 'conduct', 'conduct_reasons', 'driver', 'efficiency', 'facts', 'family', 'loops', 'model']
(b) task-fan-five merged reply:
    2026-09-25-v13-task task-fan-five.openrouter_z-ai_glm-5.3-flash.nexus.1
      facts keys: ['adaptations', 'model', 'nudged', 'reply', 'root', 'style', 'swept', 'tier']
      facts.reply: "status:    completed\nAll five review agents are running. I'll merge their answers as soon as the results arrive.\n"
      event types: ['input_accepted', 'turn_status']
      'All five answers are in' in artifact json: False ; in world logs: ['nexus.rails.log', 'nexus.model_runner.log', 'nexus.jobs.rails.log', 'nexus.model_runner.rails.log', 'nexus.server.log']
    2026-09-24-v11-task task-fan-five.openrouter_moonshotai_kimi-k3.nexus.2
      facts keys: ['adaptations', 'model', 'nudged', 'reply', 'root', 'style', 'swept', 'tier']
      facts.reply: "status:    completed\nAll five review agents are now running in parallel. I'll merge their answers into the single five-line list as soon as their results arri
      event types: ['input_accepted', 'turn_status']
      'All five answers are in' in artifact json: False ; in world logs: []
(c) lane-bug artifacts' facts keys:
    compose-background-suite.openrouter_z-ai_glm-5.3.nexus.3 ['adaptations', 'model', 'nudged', 'root', 'style', 'swept', 'tier'] False
    compose-grep-then-edit.openrouter_z-ai_glm-5.3-flash.nexus.1 ['adaptations', 'model', 'nudged', 'root', 'style', 'swept', 'tier'] False
(d) barrier-free kimi-k3 #1 bash commands:
    r3t0 "sh bin/fetch a | { IFS='|' read -r s d v; printf 'source=%s date=%s value=%s\\n' \"$s\" \"$d\" \"$v\" > a.norm; } &\nsh bin/fetch b | { IFS='|' read -r s d v; printf 'source=%s date=%s value=%s\\n' \"$s\" \"$d\" \"$v\" > b.norm; } &\nsh bin/fetch c | { IFS='|' read -r s d v; printf 'source=%s date=%s value=%s\\n' \"$s\" \"$d\" \"$v\" > c.norm; } &\nwait\ncat a.norm b.norm c.norm > merged.txt\ncat
```

`w5_stall.py`:

```python
# W5: the two deadline stops' streams, per attempt: reasoning_delta frames decoded from the solid_cable_messages
# inserts in each run's copied whole nexus.model_runner.log, the largest gap INSIDE an attempt, the gap across
# the retry, and the trace's canceling/canceled stamps against the last delta.
# Usage: python3 w5_stall.py
import json, re, collections, datetime
BASE = "/Users/jasl/Workspaces/cybros-ai.alt2/e2e/artifacts/evals/2026-09-25-v13-compose/"
CASES = [("compose-background-suite.openrouter_z-ai_glm-5.3.nexus.3", "01a0d4e2-60b1-7b12-80fd-4ba523f31311"),
         ("compose-grep-then-edit.openrouter_z-ai_glm-5.3-flash.nexus.1", "01a0d51c-dd96-776d-adc7-79d9a934ec7b")]
INS = re.compile(r"INSERT INTO \"solid_cable_messages\" \(\"channel\",\"channel_hash\",\"created_at\",\"payload\"\) VALUES "
                 r"\('\\x([0-9a-f]+)', -?\d+, '([^']+)', '\\x([0-9a-f]+)'")


def stamp(s):
    return datetime.datetime.fromisoformat(s.replace("Z", "+00:00")).replace(tzinfo=None)


for stem, loop in CASES:
    frames = []
    for line in open(BASE + "logs/" + stem + "/nexus.model_runner.log", encoding="utf-8", errors="replace"):
        m = INS.search(line)
        if not m:
            continue
        try:
            body = json.loads(bytes.fromhex(m.group(3)).decode("utf-8", "replace"))
        except ValueError:
            continue
        body = body.get("frame") or body.get("event") or {}
        if body.get("agent_loop_public_id") == loop:
            frames.append((datetime.datetime.fromisoformat(m.group(2)), body))
    attempt, per = 0, collections.OrderedDict()
    for t, b in frames:
        if b["type"] == "round_started":
            attempt = b.get("attempt")
        if b["type"] == "reasoning_delta":
            per.setdefault(attempt, []).append(t)
    print(stem, "frames by type", dict(collections.Counter(b["type"] for _, b in frames)))
    last = None
    for a, ts in per.items():
        gaps = [(ts[k + 1] - ts[k]).total_seconds() for k in range(len(ts) - 1)]
        print(f"   attempt {a}: deltas {len(ts)}, first {ts[0].time()}, last {ts[-1].time()}, max gap inside {max(gaps):.1f} s")
        if last is not None:
            print(f"   retry gap (last delta of attempt {last[0]} -> first of {a}): {(ts[0] - last[1]).total_seconds():.1f} s")
        last = (a, ts[-1])
    all_ts = [t for ts in per.values() for t in ts]
    print(f"   all deltas {len(all_ts)}: span {(all_ts[-1] - all_ts[0]).total_seconds():.1f} s")
    art = json.load(open(BASE + stem + ".json", encoding="utf-8"))
    for e in art["events"]:
        status = e.get("payload", {}).get("loop_status")
        if e.get("type") == "turn_status" and status in ("canceling", "canceled"):
            at = e["occurred_at"]
            print(f"   loop {status} at {at}: {(stamp(at) - all_ts[-1]).total_seconds():+.2f} s after the last delta")
```

Output:

```text
compose-background-suite.openrouter_z-ai_glm-5.3.nexus.3 frames by type {'round_started': 1, 'reasoning_delta': 1679}
   attempt 1: deltas 1679, first 19:26:41.895062, last 19:36:21.960021, max gap inside 28.2 s
   all deltas 1679: span 580.1 s
   loop canceling at 2026-09-24T19:36:44.850Z: +22.89 s after the last delta
   loop canceled at 2026-09-24T19:36:45.105Z: +23.14 s after the last delta
compose-grep-then-edit.openrouter_z-ai_glm-5.3-flash.nexus.1 frames by type {'round_started': 2, 'reasoning_delta': 4060, 'stream_reset': 1}
   attempt 1: deltas 2875, first 20:30:35.940855, last 20:37:24.156777, max gap inside 0.4 s
   attempt 2: deltas 1185, first 20:37:35.860326, last 20:40:37.873150, max gap inside 0.4 s
   retry gap (last delta of attempt 1 -> first of 2): 11.7 s
   all deltas 4060: span 601.9 s
   loop canceling at 2026-09-24T20:40:37.627Z: -0.25 s after the last delta
   loop canceled at 2026-09-24T20:40:37.848Z: -0.03 s after the last delta
```

`w6_rescore_dis.py`:

```python
# W6: v11 workflow's classes as recorded, under the `old` tree and under main, off Section D's in-memory rescore
# outputs (d_rescored_old.jsonl, d_rescored_head.jsonl beside this file's parent), and every record whose class
# leaves or enters `disagreement` between old and main. Nothing is appended anywhere.
# Usage: python3 w6_rescore_dis.py
import json, collections, os
D = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
REC = "/Users/jasl/Workspaces/cybros-ai.alt2/e2e/evals/runs/2026-09-24-v11-workflow/records.jsonl"
key = lambda r: (r["task"], r["model"], r["run"])
recorded = {key(r): r for r in (json.loads(l) for l in open(REC, encoding="utf-8"))}
old = {key(r): r for r in (json.loads(l) for l in open(f"{D}/d_rescored_old.jsonl", encoding="utf-8"))}
head = {key(r): r for r in (json.loads(l) for l in open(f"{D}/d_rescored_head.jsonl", encoding="utf-8"))}
cls = lambda r: r["verdict"]["class"] or "green"
for name, rows in (("recorded", recorded), ("old tree", old), ("main", head)):
    print(name, dict(collections.Counter(cls(r) for r in rows.values())))
print("recorded == old tree on class:", all(cls(recorded[k]) == cls(old[k]) for k in recorded))
moves = [(k, cls(old[k]), cls(head[k])) for k in sorted(old) if cls(old[k]) != cls(head[k]) and "disagreement" in (cls(old[k]), cls(head[k]))]
for k, a, b in moves:
    print("  disagreement move:", k[0], k[1].split("/")[-1], f"#{k[2]}", a, "->", b, "| succeeded", old[k]["verdict"]["succeeded"], "->", head[k]["verdict"]["succeeded"])
dis_main = [k for k in head if cls(head[k]) == "disagreement"]
print("main disagreement", len(dis_main), dict(collections.Counter(k[0] for k in dis_main)))
print("of which carry the receipt sentence:", sum("mailed no receipt" in head[k]["reason"] for k in dis_main))
```

Output:

```text
recorded {'disagreement': 13, 'model conduct': 25, 'green': 14, 'cache under floor': 8}
old tree {'disagreement': 13, 'model conduct': 25, 'green': 14, 'cache under floor': 8}
main {'disagreement': 12, 'cache under floor': 12, 'model conduct': 11, 'green': 25}
recorded == old tree on class: True
  disagreement move: workflow-barrier-free-pipeline glm-5.3 #2 disagreement -> cache under floor | succeeded False -> True
main disagreement 12 {'workflow-adversarial-verify': 7, 'workflow-barrier-free-pipeline': 4, 'workflow-judge-panel': 1}
of which carry the receipt sentence: 7
```

`w7_balances.py`:

```python
# W7: the four balance snapshots in the bench driver's log (one before each family and one after the last), the
# balance each family moved, and the cost that family's records carry per provider lane.
# Usage: python3 w7_balances.py
import json, re
LOG = "/private/tmp/claude-501/-Users-jasl-Workspaces-cybros-ai-alt2/fe6d4094-2f85-4b52-abfc-78043a70e275/scratchpad/v13/bench-v13.log"
RUNS = "/Users/jasl/Workspaces/cybros-ai.alt2/e2e/evals/runs/2026-09-25-v13-{}/records.jsonl"
snaps = []
for line in open(LOG, encoding="utf-8"):
    if m := re.match(r"as of (\S+)", line):
        snaps.append({"at": m.group(1)})
    elif m := re.match(r"OpenRouter: ([\d.]+) USD left", line):
        snaps[-1]["openrouter"] = float(m.group(1))
    elif m := re.match(r"DeepSeek: ([\d.]+) CNY", line):
        snaps[-1]["deepseek"] = float(m.group(1))
print("snapshots:", len(snaps), [s["at"] for s in snaps])
for i, fam in enumerate(("task", "compose", "workflow")):
    lane = {"openrouter": 0.0, "deepseek": 0.0}
    for l in open(RUNS.format(fam), encoding="utf-8"):
        r = json.loads(l)
        c = r["efficiency"].get("cost_amount")
        if c is not None:
            lane[r["model"].split("/")[0]] += float(c)
    a, b = snaps[i], snaps[i + 1]
    print(f"{fam}: openrouter balance moved {a['openrouter'] - b['openrouter']:.2f} USD, records {lane['openrouter']:.4f} USD; "
          f"deepseek balance moved {a['deepseek'] - b['deepseek']:.2f} CNY, records {lane['deepseek']:.4f} USD (catalog price)")
print(f"whole bench: openrouter {snaps[0]['openrouter'] - snaps[-1]['openrouter']:.2f} USD, deepseek {snaps[0]['deepseek'] - snaps[-1]['deepseek']:.2f} CNY")
```

Output:

```text
snapshots: 4 ['2026-09-24T17:59:10Z', '2026-09-24T19:12:11Z', '2026-09-25T00:00:05Z', '2026-09-25T02:25:57Z']
task: openrouter balance moved 2.90 USD, records 2.9014 USD; deepseek balance moved 0.26 CNY, records 0.0809 USD (catalog price)
compose: openrouter balance moved 9.32 USD, records 9.1072 USD; deepseek balance moved 1.56 CNY, records 0.4665 USD (catalog price)
workflow: openrouter balance moved 10.26 USD, records 10.2566 USD; deepseek balance moved 1.31 CNY, records 0.3919 USD (catalog price)
whole bench: openrouter 22.48 USD, deepseek 3.13 CNY
```

`w8_call2.rb`:

```ruby
# W8: every compose call of three floor picture runs scored against the task's objective the way
# `Predicates.score_compose` scores the FIRST one (Scoring.score on the script, Executed.reading on the placed
# plan), in memory under main. Call 1 is checked against the recorded `facts.score`.
# Usage (cwd = e2e): BUNDLE_FROZEN=true bundle exec ruby -I. <this file>
require "support/evals"
require "json"
E = E2E::Evals
ROOT = "/Users/jasl/Workspaces/cybros-ai.alt2/e2e"
LABEL = "2026-09-25-v13-compose"
CASES = [["compose-background-suite", "deepseek/deepseek-flash", 1, "O4"],
         ["compose-race", "deepseek/deepseek-flash", 1, "O3"],
         ["compose-race", "openrouter/z-ai/glm-5.3-flash", 1, "O3"]].freeze
records = File.readlines("#{ROOT}/evals/runs/#{LABEL}/records.jsonl", encoding: "UTF-8").map { JSON.parse(_1) }
CASES.each do |task, model, run, objective_id|
  record = records.find { |r| r["task"] == task && r["model"] == model && r["run"] == run }
  trace = E::Rescore.trace_of(record, E::Rescore.artifact_of(record, "#{ROOT}/artifacts/evals", LABEL))
  objective = E2E::ComposeBench::Objectives.find(objective_id)
  trace.compose_rows.each_with_index do |call, i|
    input = trace.input_of(call)
    static = E2E::ComposeBench::Scoring.score(objective, script: input["script"], params: input["params"], tool_names: E::Predicates.declared_names(trace))
    score = E2E::ComposeBench::Executed.reading(objective, static, E2E::ComposeBench::Executed.plan(trace.graph, call["key"]))
    line = "valid_first=#{score["valid_first"].inspect} first_time_right=#{score["first_time_right"].inspect} " \
           "silent=#{Array(score["silent"]).inspect} refusal=#{score["refusal"].inspect}"
    puts "#{task} #{model.split("/").last} ##{run} call #{i + 1} (#{call["key"]}, #{objective_id}): #{line}"
    if i.zero?
      recorded = record.dig("facts", "score")
      same = %w[valid_first first_time_right silent refusal].all? { |k| recorded[k] == score[k] }
      puts "    call 1 equals the recorded facts.score on valid_first/first_time_right/silent/refusal: #{same}"
    end
  end
end
```

Output:

```text
compose-background-suite deepseek-flash #1 call 1 (r2t0, O4): valid_first=false first_time_right=false silent=[] refusal="script_error"
    call 1 equals the recorded facts.score on valid_first/first_time_right/silent/refusal: true
compose-background-suite deepseek-flash #1 call 2 (r3t0, O4): valid_first=true first_time_right=false silent=["suite_waited_on", "extra_steps", "over_sync", "over_read"] refusal=nil
compose-race deepseek-flash #1 call 1 (r2t0, O3): valid_first=false first_time_right=false silent=[] refusal="script_syntax_error"
    call 1 equals the recorded facts.score on valid_first/first_time_right/silent/refusal: true
compose-race deepseek-flash #1 call 2 (r3t0, O3): valid_first=true first_time_right=true silent=[] refusal=nil
compose-race glm-5.3-flash #1 call 1 (r2t0, O3): valid_first=true first_time_right=false silent=["missing_join", "missing_steps"] refusal=nil
    call 1 equals the recorded facts.score on valid_first/first_time_right/silent/refusal: true
compose-race glm-5.3-flash #1 call 2 (r3t0, O3): valid_first=true first_time_right=true silent=[] refusal=nil
```

`w9_queuepass.rb`:

```ruby
# W9: QueuePass over every bash row of workflow-loop-until-dry glm-5.3 #1, v13 and v11: what each command took
# from `queue/`, and the sum, beside the record's verdict.
# Usage (cwd = e2e): BUNDLE_FROZEN=true bundle exec ruby -I. <this file>
require "support/evals"
require "json"
E = E2E::Evals
ROOT = "/Users/jasl/Workspaces/cybros-ai.alt2/e2e"
STEM = "workflow-loop-until-dry.openrouter_z-ai_glm-5.3.nexus.1"
%w[2026-09-25-v13-workflow 2026-09-24-v11-workflow].each do |label|
  artifact = JSON.parse(File.read("#{ROOT}/artifacts/evals/#{label}/#{STEM}.json", encoding: "UTF-8"))
  total = 0
  puts "== #{label}"
  artifact["tasks"].select { _1["tool_name"] == "bash" }.each do |row|
    command = row.dig("tool_input", "command").to_s
    pass = E::QueuePass.read(command, dir: "queue", workdir: row.dig("tool_input", "workdir"))
    total += pass.taken
    puts "  #{row["key"]} taken=#{pass.taken} several=#{pass.several} :: #{command[0, 80].inspect}" if pass.took?
  end
  r7 = artifact["tasks"].find { _1["key"] == "r7t0" }
  puts "  r7t0 is #{r7["tool_name"]} #{JSON.generate(r7["tool_input"])[0, 80]}"
  record = File.readlines("#{ROOT}/evals/runs/#{label}/records.jsonl", encoding: "UTF-8").map { JSON.parse(_1) }
    .find { _1["task"] == "workflow-loop-until-dry" && _1["model"].end_with?("/glm-5.3") && _1["run"] == 1 }
  puts "  total taken #{total}; recorded verdict #{record["verdict"].inspect} class #{record.dig("verdict", "class").inspect}"
end
```

Output:

```text
== 2026-09-25-v13-workflow
  r5t0 taken=1 several=false :: "mkdir -p done && mv queue/item-01.txt done/item-01.txt"
  r9t0 taken=1 several=false :: "mv queue/item-02.txt done/item-02.txt"
  r13t0 taken=1 several=false :: "mv queue/item-03.txt done/item-03.txt"
  r17t0 taken=1 several=false :: "mv queue/item-04.txt done/item-04.txt"
  r21t0 taken=1 several=false :: "mv queue/item-05.txt done/item-05.txt"
  r25t0 taken=1 several=false :: "mv queue/item-06.txt done/item-06.txt"
  r7t0 is read {"path":"queue/item-02.txt"}
  total taken 6; recorded verdict {"reached" => true, "succeeded" => true, "task_pass" => true, "class" => nil} class nil
== 2026-09-24-v11-workflow
  r5t0 taken=1 several=false :: "mv queue/item-01.txt done/item-01.txt && ls queue"
  r7t0 taken=1 several=false :: "mkdir -p done && mv queue/item-01.txt done/item-01.txt && ls queue"
  r10t0 taken=1 several=false :: "mv queue/item-02.txt done/item-02.txt && ls queue"
  r13t0 taken=1 several=false :: "mv queue/item-03.txt done/item-03.txt && ls queue"
  r16t0 taken=1 several=false :: "mv queue/item-04.txt done/item-04.txt && ls queue"
  r19t0 taken=1 several=false :: "mv queue/item-05.txt done/item-05.txt && ls queue"
  r22t0 taken=1 several=false :: "mv queue/item-06.txt done/item-06.txt && ls queue"
  r7t0 is bash {"command":"mkdir -p done && mv queue/item-01.txt done/item-01.txt && ls queue"}
  total taken 7; recorded verdict {"reached" => true, "succeeded" => true, "task_pass" => true, "class" => nil} class nil
```

`w10_v11_reread.rb`:

```ruby
# W10: v11's 228 main-label records re-read in memory through `Rescore.rescored` (nothing appended), under
# main or under the tree in TREE (a `git archive` of e2e/support, e2e/evals, nexus/lib): per model, records
# read, records that raised (named), `reissued_calls` and `leaked_calls` as re-read; compose-race's
# `authored_labels` per run.
# Usage (cwd = e2e): [TREE=<dir>] BUNDLE_FROZEN=true bundle exec ruby -I. <this file>
tree = ENV["TREE"]
$LOAD_PATH.unshift(File.join(tree, "e2e")) if tree
require "support/evals"
require "json"
E = E2E::Evals
ROOT = "/Users/jasl/Workspaces/cybros-ai.alt2/e2e"
corpus = E::Corpus.load_all(bench: E::Bench.read)
per_model = Hash.new { |h, k| h[k] = Hash.new(0) }
raised = []
race = Hash.new { |h, k| h[k] = {} }
%w[task compose workflow].each do |family|
  label = "2026-09-24-v11-#{family}"
  File.readlines("#{ROOT}/evals/runs/#{label}/records.jsonl", encoding: "UTF-8").map { JSON.parse(_1) }.each do |record|
    model = record["model"].split("/").last
    begin
      trace = E::Rescore.trace_of(record, E::Rescore.artifact_of(record, "#{ROOT}/artifacts/evals", label))
      fresh = E::Rescore.rescored(record, corpus.find(record["task"]), trace, Time.utc(2026, 9, 25))
      per_model[model]["read"] += 1
      per_model[model]["reissued=#{fresh.dig("facts", "reissued_calls").inspect}"] += 1
      per_model[model]["leaked=#{fresh.dig("facts", "leaked_calls").inspect}"] += 1
      race[model][record["run"]] = fresh.dig("facts", "authored_labels") if record["task"] == "compose-race"
    rescue StandardError => error
      per_model[model]["raised"] += 1
      raised << "#{record["task"]} #{model} ##{record["run"]}: #{error.class}: #{error.message[0, 140]}"
      race[model][record["run"]] = "raised" if record["task"] == "compose-race"
    end
  end
end
puts "builder/readers: #{tree ? File.basename(tree) : "main"}; loaded predicates from #{$LOADED_FEATURES.grep(%r{support/evals/predicates}).first}"
per_model.sort.each { |model, counts| puts "  #{model}: #{counts.sort.to_h.inspect}" }
puts "  raised: #{raised.empty? ? "none" : raised.join(" | ")}"
race.sort.each { |model, runs| puts "  compose-race authored_labels #{model}: #{runs.sort.to_h.inspect}" }
values = race.values.flat_map(&:values)
puts "  compose-race authored_labels true #{values.count(true)} / read #{values.count { _1 == true || _1 == false }} / of 12 (unread #{values.count { !(_1 == true || _1 == false) }})"
```

Output (main):

```text
builder/readers: main; loaded predicates from /Users/jasl/Workspaces/cybros-ai.alt2/e2e/support/evals/predicates.rb
  deepseek-flash: {"leaked=nil" => 57, "read" => 57, "reissued=0" => 57}
  glm-5.3: {"leaked=nil" => 57, "read" => 57, "reissued=0" => 57}
  glm-5.3-flash: {"leaked=nil" => 56, "raised" => 1, "read" => 56, "reissued=0" => 56}
  kimi-k3: {"leaked=nil" => 57, "read" => 57, "reissued=0" => 57}
  raised: compose-race glm-5.3-flash #1: E2E::ComposeBench::Executed::Drifted: the kernel placed r2t0's plan and the harness refused its script script_error: Error: g.script: results names "tool-1", a member of the race
  compose-race authored_labels deepseek-flash: {1 => true, 2 => true, 3 => true}
  compose-race authored_labels glm-5.3: {1 => false, 2 => true, 3 => true}
  compose-race authored_labels glm-5.3-flash: {1 => "raised", 2 => false, 3 => false}
  compose-race authored_labels kimi-k3: {1 => true, 2 => true, 3 => true}
  compose-race authored_labels true 8 / read 11 / of 12 (unread 1)
```

Output (56469b97):

```text
builder/readers: tree-56469b97; loaded predicates from /private/tmp/claude-501/-Users-jasl-Workspaces-cybros-ai-alt2/fe6d4094-2f85-4b52-abfc-78043a70e275/scratchpad/v13/readout/writer/tree-56469b97/e2e/support/evals/predicates.rb
  deepseek-flash: {"leaked=nil" => 57, "read" => 57, "reissued=0" => 57}
  glm-5.3: {"leaked=nil" => 57, "read" => 57, "reissued=0" => 57}
  glm-5.3-flash: {"leaked=nil" => 57, "read" => 57, "reissued=0" => 57}
  kimi-k3: {"leaked=nil" => 57, "read" => 57, "reissued=0" => 57}
  raised: none
  compose-race authored_labels deepseek-flash: {1 => true, 2 => true, 3 => true}
  compose-race authored_labels glm-5.3: {1 => false, 2 => true, 3 => true}
  compose-race authored_labels glm-5.3-flash: {1 => false, 2 => false, 3 => true}
  compose-race authored_labels kimi-k3: {1 => true, 2 => true, 3 => true}
  compose-race authored_labels true 9 / read 12 / of 12 (unread 0)
```

`w11_barrier_free.py`:

```python
# W11: the v13 barrier-free runs that made no compose call and no two-`task` fan (the "no door" reds): each one's
# bash commands that fetch, so the RATIONALE gloss can be read against what they ran.
# Usage: python3 w11_barrier_free.py
import json, re
BACKGROUND = re.compile(r"(?<!&)&(?!&)")  # a backgrounding ampersand, not `&&`
RUNS = "/Users/jasl/Workspaces/cybros-ai.alt2/e2e/evals/runs/2026-09-25-v13-workflow/records.jsonl"
ART = "/Users/jasl/Workspaces/cybros-ai.alt2/e2e/artifacts/evals/2026-09-25-v13-workflow/"
for line in open(RUNS, encoding="utf-8"):
    r = json.loads(line)
    if r["task"] != "workflow-barrier-free-pipeline" or r["verdict"]["class"] is None:
        continue
    called = r["facts"]["called"]
    if called.get("compose", 0) or called.get("task", 0) >= 2:
        continue
    art = json.load(open(ART + r["artifact"].split("/")[-1], encoding="utf-8"))
    fetches = [t for t in art["tasks"] if t.get("tool_name") == "bash" and "fetch" in json.dumps(t["tool_input"])]
    print(f"{r['model'].split('/')[-1]} #{r['run']}: class {r['verdict']['class']}, task_pass {r['verdict']['task_pass']}, called {called}")
    for t in fetches:
        cmd = t["tool_input"].get("command", "")
        how = "awk" if "awk" in cmd else ("read/printf" if "read -r" in cmd else "other")
        bg = bool(BACKGROUND.search(cmd))
        print(f"    {t['key']} backgrounded={bg} then_wait={'wait' in cmd} normalise={how} :: {json.dumps(cmd)[:(700 if bg else 120)]}")
```

Output:

```text
glm-5.3 #1: class model conduct, task_pass True, called {'ls': 1, 'read': 1, 'todo_write': 3, 'bash': 4}
    r3t1 backgrounded=False then_wait=False normalise=awk :: "mkdir -p raw norm && sh bin/fetch a > raw/a && awk -F'|' '{print \"source=\"$1\" date=\"$2\" value=\"$3}' raw/a > norm/
    r3t2 backgrounded=False then_wait=False normalise=awk :: "mkdir -p raw norm && sh bin/fetch b > raw/b && awk -F'|' '{print \"source=\"$1\" date=\"$2\" value=\"$3}' raw/b > norm/
    r3t3 backgrounded=False then_wait=False normalise=awk :: "mkdir -p raw norm && sh bin/fetch c > raw/c && awk -F'|' '{print \"source=\"$1\" date=\"$2\" value=\"$3}' raw/c > norm/
kimi-k3 #1: class model conduct, task_pass True, called {'ls': 1, 'read': 1, 'bash': 1}
    r3t0 backgrounded=True then_wait=True normalise=read/printf :: "sh bin/fetch a | { IFS='|' read -r s d v; printf 'source=%s date=%s value=%s\\n' \"$s\" \"$d\" \"$v\" > a.norm; } &\nsh bin/fetch b | { IFS='|' read -r s d v; printf 'source=%s date=%s value=%s\\n' \"$s\" \"$d\" \"$v\" > b.norm; } &\nsh bin/fetch c | { IFS='|' read -r s d v; printf 'source=%s date=%s value=%s\\n' \"$s\" \"$d\" \"$v\" > c.norm; } &\nwait\ncat a.norm b.norm c.norm > merged.txt\ncat merged.txt"
kimi-k3 #2: class model conduct, task_pass True, called {'ls': 1, 'bash': 5}
    r2t1 backgrounded=False then_wait=False normalise=other :: "cat bin/fetch; ls bin/"
    r3t0 backgrounded=False then_wait=False normalise=awk :: "sh bin/fetch a | awk -F'|' '{printf \"source=%s date=%s value=%s\\n\", $1, $2, $3}' > record-a.txt && cat record-a.txt"
    r3t1 backgrounded=False then_wait=False normalise=awk :: "sh bin/fetch b | awk -F'|' '{printf \"source=%s date=%s value=%s\\n\", $1, $2, $3}' > record-b.txt && cat record-b.txt"
    r3t2 backgrounded=False then_wait=False normalise=awk :: "sh bin/fetch c | awk -F'|' '{printf \"source=%s date=%s value=%s\\n\", $1, $2, $3}' > record-c.txt && cat record-c.txt"
kimi-k3 #3: class model conduct, task_pass True, called {'ls': 1, 'read': 1, 'bash': 1}
    r3t0 backgrounded=True then_wait=True normalise=awk :: "for s in a b c; do\n  sh bin/fetch \"$s\" | awk -F'|' '{printf \"source=%s date=%s value=%s\\n\", $1, $2, $3}' > \"norm-$s.txt\" &\ndone\nwait\ncat norm-a.txt norm-b.txt norm-c.txt > merged.txt\ncat merged.txt"
deepseek-flash #1: class model conduct, task_pass True, called {'bash': 2, 'ls': 1}
    r2t0 backgrounded=False then_wait=False normalise=other :: "ls -la; echo ---; ls -la bin 2>/dev/null; echo ---; cat bin/fetch 2>/dev/null"
    r3t0 backgrounded=True then_wait=True normalise=awk :: "set -e\n# one pipeline per source: fetch -> normalise -> its own record file, all in parallel.\n# no barrier between a fetch finishing and its own normalisation.\nfor s in a b c; do\n  ( sh bin/fetch \"$s\" | awk -F'|' '{printf \"source=%s date=%s value=%s\\n\", $1, $2, $3}' > \"rec_$s.txt\" ) &\ndone\nwait\necho \"--- records (each written as soon as its own fetch finished) ---\"\nfor s in a b c; do cat \"rec_$s.txt\"; done\nfor s in a b c; do cat \"rec_$s.txt\"; done > merged.txt\necho \"--- merged.txt ---\"\ncat merged.txt"
deepseek-flash #2: class model conduct, task_pass True, called {'bash': 4, 'write': 2}
    r2t0 backgrounded=False then_wait=False normalise=other :: "ls -la; echo ---; ls -la bin 2>/dev/null; echo ---; cat bin/fetch 2>/dev/null"
glm-5.3-flash #2: class model conduct, task_pass True, called {'ls': 1, 'find': 1, 'read': 1, 'bash': 1}
    r4t0 backgrounded=True then_wait=True normalise=awk :: "rm -f norm-a.txt norm-b.txt norm-c.txt merged.txt\nstart=$(date +%s)\nlog() { echo \"[t+$(( $(date +%s) - start ))s] $1\"; }\n\n# Three concurrent fetch->normalise pipelines; each normaliser sees only its own source's output.\n( sh bin/fetch a | awk -F'|' '{printf \"source=%s date=%s value=%s\\n\", $1, $2, $3}' > norm-a.txt && log \"a fetched+normalised\" ) &\np1=$!\n( sh bin/fetch b | awk -F'|' '{printf \"source=%s date=%s value=%s\\n\", $1, $2, $3}' > norm-b.txt && log \"b fetched+normalised\" ) &\np2=$!\n( sh bin/fetch c | awk -F'|' '{printf \"source=%s date=%s value=%s\\n\", $1, $2, $3}' > norm-c.txt && log \"c fetched+normalised\" ) &\np3=$!\n\nwait \"$p1\"; s1=$?\nwait \"$p2\"; s2=$?\
```

`w12_s1_control.sh`:

```zsh
#!/bin/zsh
# W12: the S1 `race_member` sentence over every saved v13 trace and world log, with the positive control named:
# the two repository files known to hold the sentence. Read only.
# Usage: zsh w12_s1_control.sh   (from anywhere)
set -e
REPO=/Users/jasl/Workspaces/cybros-ai.alt2
R='a member of (the race on line [0-9]+|an earlier race); a race stops the members it did not select'
cd "$REPO"
echo "sentence source: $(grep -n 'a race stops the members it did not select' nexus/lib/nexus/compose/builder.js | cut -d: -f1 | tr '\n' ' ')(builder.js line)"
for f in e2e/artifacts/bench/2026-09-24-s1/dryrun.md e2e/test/compose_bench_pictures_harness_test.rb; do
  echo "control $f: $(grep -cE "$R" "$f") line(s)"
done
echo "control files holding it: $(grep -lE "$R" e2e/artifacts/bench/2026-09-24-s1/dryrun.md e2e/test/compose_bench_pictures_harness_test.rb | wc -l | tr -d ' ') of 2"
for fam in task compose workflow; do
  echo "v13 $fam files holding it: $(grep -rlE "$R" "e2e/artifacts/evals/2026-09-25-v13-$fam" | wc -l | tr -d ' ') of $(find "e2e/artifacts/evals/2026-09-25-v13-$fam" -type f | wc -l | tr -d ' ')"
done
```

Output:

```text
sentence source: 399 (builder.js line)
control e2e/artifacts/bench/2026-09-24-s1/dryrun.md: 5 line(s)
control e2e/test/compose_bench_pictures_harness_test.rb: 1 line(s)
control files holding it: 2 of 2
v13 task files holding it: 0 of 1080
v13 compose files holding it: 0 of 1620
v13 workflow files holding it: 0 of 900
```
