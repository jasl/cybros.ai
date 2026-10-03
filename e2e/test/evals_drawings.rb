require "support/evals"

# THE CORPUS'S DRAWN TRACES: one green and one red per task, in
# `E2E::Evals::Drawing`'s vocabulary (the route's node, edge, the joined
# task rows, the feed's items, the driver's facts). The gallery's
# drawings (`gallery_shapes_test.rb`) are re-drawn here in the same
# words; the compose scripts are the harness test's canonical ones with
# rho's tool names (`bash`, `grep`) where the text bench's `probe_host`
# and `curl` were, each drawn as the plan it places. Loaded by
# `evals_expected_test.rb` and `evals_predicates_test.rb`, never by a lane.
module EvalsDrawings
  D = E2E::Evals::Drawing

  # ── graphs ─────────────────────────────────────────────────────────────
  LINEAR_GRAPH = D.graph(
    [D.n("r1", "model_task"), D.n("r1t0", "tool_task"), D.n("r2", "model_task"), D.n("r2t0", "tool_task"),
     D.n("r3", "model_task", deliverable: true)],
    [%w[r1 r1t0], %w[r1t0 r2], %w[r2 r2t0], %w[r2t0 r3]]
  )
  LINEAR_TASKS = [D.tool("r1t0", "write", after: ["r1"], input: { "path" => "fizzbuzz.rb", "content" => "…" }),
                  D.tool("r2t0", "bash", after: ["r2"], input: { "command" => "ruby fizzbuzz.rb" })].freeze

  # r1 fans three tool rows into r2.
  def self.three_wide(names, inputs)
    graph = D.graph(
      [D.n("r1", "model_task"), D.n("r1t0", "tool_task"), D.n("r1t1", "tool_task"), D.n("r1t2", "tool_task"),
       D.n("r2", "model_task", deliverable: true)],
      [%w[r1 r1t0], %w[r1 r1t1], %w[r1 r1t2], %w[r1t0 r2], %w[r1t1 r2], %w[r1t2 r2]]
    )
    rows = names.each_with_index.map { |name, i| D.tool("r1t#{i}", name, after: ["r1"], input: inputs[i]) }
    [graph, rows]
  end

  # A SPINE DRAWN FROM ITS ROUNDS' CALLS, each call `[name, input]` or `[name, input, extra]` — the
  # row's other keys, as a read-class row's `output`: every round is the spine's, in order, and a
  # last round answers unless `answer: false` (a run cut before one).
  def self.spine(*rounds, answer: true, facts: {})
    keys = (1..(rounds.size + (answer ? 1 : 0))).map { |i| "r#{i}" }
    rows = rounds.each_with_index.flat_map do |calls, i|
      calls.each_with_index.map do |(name, input, extra), j|
        D.tool("r#{i + 1}t#{j}", name, after: ["r#{i + 1}"], input: input).merge(extra || {})
      end
    end
    nodes = keys.map { |key| D.n(key, "model_task", deliverable: answer && key == keys.last) } + rows.map { |row| D.n(row["key"], "tool_task") }
    D.trace(D.graph(nodes, []), rows, [], facts: facts)
  end

  def self.bash(command) = ["bash", { "command" => command }]

  # Five `task` calls in r1, each with its branch root, all into r2.
  FIVE_ROOTS = (0..4).flat_map { |i| [D.n("r1t#{i}", "tool_task"), D.n("r1t#{i}-model-1", "model_task", spine: false)] }
  FIVE_EDGES = (0..4).flat_map { |i| [%W[r1 r1t#{i}], %W[r1t#{i} r1t#{i}-model-1], %W[r1t#{i} r2]] }
  FIVE_GRAPH = D.graph([D.n("r1", "model_task"), *FIVE_ROOTS, D.n("r2", "model_task", deliverable: true)], FIVE_EDGES)
  FIVE_TASKS = %w[a b c d e].each_with_index.map do |f, i|
    D.tool("r1t#{i}", "task", after: ["r1"], input: { "prompt" => "Review lib/#{f}.rb for the uncalled method.", "wait" => true })
  end.freeze
  FIVE_REPLY = "lib/a.rb — orphan_a\nlib/b.rb — orphan_b\nlib/c.rb — orphan_c\nlib/d.rb — orphan_d\nlib/e.rb — orphan_e".freeze

  ASK_GRAPH = D.graph(
    [D.n("r1", "model_task"), D.n("r1t0", "tool_task"), D.n("r1t0-ask-1", "await_task"), D.n("r2", "model_task"),
     D.n("r2t0", "tool_task"), D.n("r3", "model_task", deliverable: true)],
    [%w[r1 r1t0], %w[r1t0 r2], %w[r1t0 r1t0-ask-1], %w[r1t0-ask-1 r2], %w[r2 r2t0], %w[r2t0 r3]]
  )
  ASK_TASKS = [D.tool("r1t0", "ask", after: ["r1"], input: { "prompt" => "What is the codeword?" }),
               D.tool("r2t0", "write", after: ["r2"], input: { "path" => "greeting.txt" })].freeze
  ASK_EVENTS = [D.event("attention_required", { "reason" => "awaiting_human", "blocked_task_keys" => ["r1t0-ask-1"] })].freeze

  HALT_GRAPH = D.graph(
    [D.n("gate-1", "await_task", status: "timed_out", error_key: "await_timeout"),
     D.n("gate-2", "await_task"), D.n("work", "model_task", deliverable: true)],
    [%w[gate-1 work], %w[gate-2 work]]
  )

  # Each planted round names its attempt's check and hold: the rows of an earlier append, by key.
  UNTIL_GRAPH = D.graph(
    [D.n("r1", "model_task"), D.n("r1t0", "tool_task"), D.n("r2", "model_task"),
     D.n("check-1", "tool_task"), D.n("hold-1", "await_task"), D.n("work-2", "model_task", result_from: %w[check-1 hold-1]),
     D.n("check-2", "tool_task"), D.n("hold-2", "await_task"),
     D.n("summary", "model_task", deliverable: true, result_from: %w[check-2 hold-2])],
    [%w[r1 r1t0], %w[r1t0 r2], %w[r2 check-1], %w[check-1 hold-1], %w[hold-1 work-2], %w[check-1 work-2],
     %w[work-2 check-2], %w[check-2 hold-2], %w[hold-2 summary], %w[check-2 summary]]
  )

  # The 2026-09-09 trace on deepseek: the root under the call, the branch's
  # own round keyed r3 (the kernel marks it the branch's: `spine: false`),
  # nothing in the branch reaching r2.
  MAIL_GRAPH = D.graph(
    [D.n("r1", "model_task"), D.n("r1t0", "tool_task"), D.n("r1t1", "tool_task"), D.n("r2", "model_task", deliverable: true),
     D.n("r1t0-model-1", "model_task", spine: false), D.n("r3t0", "tool_task"), D.n("r3", "model_task", spine: false)],
    [%w[r1 r1t0], %w[r1 r1t1], %w[r1t0 r2], %w[r1t1 r2], %w[r1t0 r1t0-model-1], %w[r1t0-model-1 r3t0], %w[r3t0 r3]]
  )
  MAIL_TASKS = [D.tool("r1t0", "task", after: ["r1"], input: { "prompt" => "run ruby test/all.rb" }),
                D.tool("r1t1", "bash", after: ["r1"], input: { "command" => "ls lib | wc -l" })].freeze
  MAIL_EVENTS = [
    D.event("turn_status", { "agent_loop_public_id" => "loop-1", "loop_status" => "completed" }),
    D.event("input_accepted", { "origin" => "task_result", "kind" => "direct_reply", "delivery_mode" => "queue",
                                "agent_loop_public_id" => "loop-1", "task_key" => "r1t0" }),
    D.event("turn_status", { "agent_loop_public_id" => "loop-2", "loop_status" => "running" }),
    D.event("turn_status", { "agent_loop_public_id" => "loop-2", "loop_status" => "completed" }),
  ].freeze
  MAIL_FACTS = { "reply_final_with_background" => true, "mailed" => true, "receipt_woke_a_turn" => true, "task_started" => true,
                 "mail_in_turn_2_history" => true, "turn_2_reply" => "status: completed\ntest_subtracts",
                 "turn_2_bash_commands" => [], "reply" => "3", "turn_1_called" => { "task" => 1, "bash" => 1 } }.freeze

  # THE PASSIVE RECEIPT (the v11 bench's task-mail deepseek-flash #2, task-detached-receipt kimi-k3
  # #2 and #3): the call asked `wake: "passive"`, so the kernel mails the receipt as a `message` —
  # history, no reply started — and the next loop on the feed is the person's turn 2, not a woken one.
  MAIL_PASSIVE_TASKS = [D.tool("r1t0", "task", after: ["r1"], input: { "prompt" => "run ruby test/all.rb", "wake" => "passive" }),
                        MAIL_TASKS.last].freeze
  MAIL_PASSIVE_EVENTS = [
    D.event("turn_status", { "agent_loop_public_id" => "loop-1", "loop_status" => "completed" }),
    D.event("input_accepted", { "origin" => "task_result", "kind" => "message", "delivery_mode" => "queue",
                                "agent_loop_public_id" => "loop-1", "task_key" => "r1t0" }),
    D.event("input_accepted", { "origin" => "person", "kind" => "direct_reply", "delivery_mode" => "queue" }),
    D.event("turn_status", { "agent_loop_public_id" => "loop-2", "loop_status" => "running" }),
    D.event("turn_status", { "agent_loop_public_id" => "loop-2", "loop_status" => "completed" }),
  ].freeze
  MAIL_PASSIVE_FACTS = MAIL_FACTS.merge("wake_passive" => true, "receipt_woke_a_turn" => false).freeze

  # THE PANEL THAT WAITED (kimi-k3's judge panel on the pack row, 2026-09-16-pack-workflow #1 and
  # #2; glm-5.3's pack #1 the same): three judges fanned by r2 with `wait: true`, each a branch
  # root, a waited chair after them, NO receipt on the feed (the kernel mails `task_result` for a
  # detached task alone), the loop completed, the reply `winner: b` with verdict.md holding — the
  # fan that came back whole, read as the panel it is.
  PANEL_JUDGES = (0..2).to_a.freeze
  PANEL_GRAPH = D.graph(
    [D.n("r1", "model_task"), D.n("r1t0", "tool_task"), D.n("r2", "model_task"),
     *PANEL_JUDGES.flat_map { |i| [D.n("r2t#{i}", "tool_task"), D.n("r2t#{i}-model-1", "model_task", spine: false)] },
     D.n("r3", "model_task"), D.n("r3t0", "tool_task"), D.n("r3t0-model-1", "model_task", spine: false),
     D.n("r4", "model_task", deliverable: true)],
    [%w[r1 r1t0], %w[r1t0 r2], *PANEL_JUDGES.flat_map { |i| [%W[r2 r2t#{i}], %W[r2t#{i} r2t#{i}-model-1], %W[r2t#{i} r3]] },
     %w[r3 r3t0], %w[r3t0 r3t0-model-1], %w[r3t0 r4]]
  )
  PANEL_TASKS = [
    D.tool("r1t0", "ls", after: ["r1"], input: { "path" => "." }),
    *PANEL_JUDGES.map do |i|
      D.tool("r2t#{i}", "task", after: ["r2"],
        input: { "prompt" => "You are Judge #{i + 1} of three independent judges. Read SPEC.md, a/slugify.rb and b/slugify.rb; score both.", "wait" => true })
    end,
    D.tool("r3t0", "task", after: ["r3"], input: { "prompt" => "You are the chair. Tally the three scores and name the winner.", "wait" => true }),
  ].freeze

  def self.panel_trace(reply: "status:    completed\nwinner: b\n", tasks: PANEL_TASKS, loops: nil)
    D.trace(PANEL_GRAPH, tasks, [], facts: { "reply" => reply }, loops: loops)
  end

  # THE DELEGATES' OWN ROUNDS (the v11 bench's adversarial-verify kimi-k3 #1, its refuters' reads):
  # r1 fans a detached `task` per input, each opening its root; the root's call and the branch round
  # it continues to carry round keys off the loop-global counter (`r3t0` made by the root, then `r3`,
  # whose own call is `r6t0`), and the kernel marks every such round the branch's (`spine: false`) —
  # each delegate calls `tool` twice, the spine none. `own` are the spine's own calls `[tool, input]`,
  # made by r2 once the fan came back.
  def self.delegated(tool, inputs, own: [])
    width = inputs.size
    last = "r#{3 + (2 * width)}"
    branches = inputs.each_index.map do |i|
      root, first, second = "r2t#{i}-model-1", "r#{3 + i}", "r#{3 + width + i}"
      { nodes: [D.n("r2t#{i}", "tool_task"), D.n(root, "model_task", spine: false), D.n("#{first}t0", "tool_task"),
                D.n(first, "model_task", spine: false), D.n("#{second}t0", "tool_task"), D.n(second, "model_task", spine: false)],
        edges: [["r1", "r2t#{i}"], ["r2t#{i}", "r2"], ["r2t#{i}", root], [root, "#{first}t0"], ["#{first}t0", first],
                [first, "#{second}t0"], ["#{second}t0", second]],
        rows: [D.tool("r2t#{i}", "task", after: ["r1"], input: { "prompt" => "Check #{inputs[i].values.last}", "wait" => false }),
               D.tool("#{first}t0", tool, after: [root], input: inputs[i]), D.tool("#{second}t0", tool, after: [first], input: inputs[i])] }
    end
    calls = own.each_with_index.map { |(name, input), j| D.tool("#{last}t#{j}", name, after: ["r2"], input: input) }
    graph = D.graph(
      [D.n("r1", "model_task"), *branches.flat_map { |branch| branch[:nodes] }, D.n("r2", "model_task", deliverable: own.empty?),
       *calls.map { |row| D.n(row["key"], "tool_task") }, *(own.empty? ? [] : [D.n(last, "model_task", deliverable: true)])],
      branches.flat_map { |branch| branch[:edges] } + calls.flat_map { |row| [["r2", row["key"]], [row["key"], last]] }
    )
    [graph, branches.flat_map { |branch| branch[:rows] } + calls]
  end

  # THE SPAWN FAMILY: a detached `spawn` row settles at once on the parent's graph (the child is
  # another conversation — no branch under the call), the count runs direct, the child's reply lands
  # as kernel mail of origin `child` and wakes loop-2.
  SPAWN_GRAPH = D.graph(
    [D.n("r1", "model_task"), D.n("r1t0", "tool_task"), D.n("r1t1", "tool_task"), D.n("r2", "model_task", deliverable: true)],
    [%w[r1 r1t0], %w[r1 r1t1], %w[r1t0 r2], %w[r1t1 r2]]
  )
  SPAWN_TASKS = [D.tool("r1t0", "spawn", after: ["r1"], input: { "prompt" => "Run ruby test/all.rb and fix what fails in lib/.", "label" => "suite" }),
                 D.tool("r1t1", "bash", after: ["r1"], input: { "command" => "ls lib | wc -l" })].freeze
  SPAWN_EVENTS = [
    D.event("turn_status", { "agent_loop_public_id" => "loop-1", "loop_status" => "completed" }),
    D.event("input_accepted", { "origin" => "child", "kind" => "direct_reply", "delivery_mode" => "queue",
                                "agent_loop_public_id" => "loop-1", "task_key" => "r1t0",
                                "sender_conversation_public_id" => "child-conversation" }),
    D.event("turn_status", { "agent_loop_public_id" => "loop-2", "loop_status" => "running" }),
    D.event("turn_status", { "agent_loop_public_id" => "loop-2", "loop_status" => "completed" }),
  ].freeze
  SPAWN_FACTS = { "spawn_waited" => false, "child_replied" => true, "reply_woke_a_turn" => true, "mail_in_turn_2_history" => true,
                  "turn_2_reply" => "status: completed\ntest_subtracts", "turn_2_bash_commands" => [], "reply" => "3",
                  "turn_1_called" => { "spawn" => 1, "bash" => 1 } }.freeze
  # The passive twin: the spawn asked `wake: "passive"`, the child's reply is a `message` in the
  # history, and loop-2 is the person's turn 2.
  SPAWN_PASSIVE_TASKS = [D.tool("r1t0", "spawn", after: ["r1"],
    input: { "prompt" => "Run ruby test/all.rb and fix what fails in lib/.", "label" => "suite", "wake" => "passive" }),
                         SPAWN_TASKS.last].freeze
  SPAWN_PASSIVE_EVENTS = [
    D.event("turn_status", { "agent_loop_public_id" => "loop-1", "loop_status" => "completed" }),
    D.event("input_accepted", { "origin" => "child", "kind" => "message", "delivery_mode" => "queue",
                                "agent_loop_public_id" => "loop-1", "task_key" => "r1t0",
                                "sender_conversation_public_id" => "child-conversation" }),
    D.event("input_accepted", { "origin" => "person", "kind" => "direct_reply", "delivery_mode" => "queue" }),
    D.event("turn_status", { "agent_loop_public_id" => "loop-2", "loop_status" => "running" }),
    D.event("turn_status", { "agent_loop_public_id" => "loop-2", "loop_status" => "completed" }),
  ].freeze
  SPAWN_PASSIVE_FACTS = SPAWN_FACTS.merge("wake_passive" => true, "reply_woke_a_turn" => false).freeze
  # The peer relay: one waited `spawn` addressed by handle, the paired
  # reply the call's own result, the person's reply the line it named.
  PEER_GRAPH = D.graph(
    [D.n("r1", "model_task"), D.n("r1t0", "tool_task"), D.n("r2", "model_task", deliverable: true)],
    [%w[r1 r1t0], %w[r1t0 r2]]
  )
  PEER_TASKS = [D.tool("r1t0", "spawn", after: ["r1"],
    input: { "prompt" => "Review lib/calc.rb: on which line is Calc.sub wrong?", "agent" => "@reviewer", "wait" => true })].freeze
  PEER_FACTS = { "reply" => "status: completed\n3" }.freeze

  # Ten spine rounds: the first nine each fan the identical `cat status.txt`, and r10, having read
  # the ninth, is refused.
  BRAKE_GRAPH = D.graph(
    [*(1..9).flat_map { |i| [D.n("r#{i}", "model_task"), D.n("r#{i}t0", "tool_task")] },
     D.n("r10", "model_task", status: "failed", error_key: E2E::Gallery::EXPANSION_REFUSED)],
    (1..9).flat_map { |i| [["r#{i}", "r#{i}t0"], ["r#{i}t0", "r#{i + 1}"]] }
  )
  BRAKE_TASKS = ((1..9).map { |i| D.tool("r#{i}t0", "bash", after: ["r#{i}"], input: { "command" => "cat status.txt" }) } +
    [D.round("r10", status: "failed", error: { "key" => E2E::Gallery::EXPANSION_REFUSED, "detail" => E2E::Gallery::REPEAT_LOOP })]).freeze
  BRAKE_EVENTS = [D.event("attention_required", { "reason" => "halt_failure", "blocked_task_keys" => ["r10"] })].freeze

  def self.compaction_graph(kind)
    D.graph(
      [D.n("r1", "model_task"), D.n("r1t0", "tool_task"), D.n("r2", "model_task"), D.n("r2t0", "tool_task"),
       D.n("r3", "model_task"), D.n("r3t0", "tool_task"), D.n("k1", kind, spine: (false if kind == "model_task")), D.n("r4", "model_task"),
       D.n("r4t0", "tool_task"), D.n("r5", "model_task", deliverable: true)],
      [%w[r1 r1t0], %w[r1t0 r2], %w[r2 r2t0], %w[r2t0 r3], %w[r3 r3t0], %w[r3t0 r4], %w[k1 r4], %w[r4 r4t0], %w[r4t0 r5]]
    )
  end

  def self.compaction_events(mode, trigger: "manual", task_key: "r4")
    [D.event("context_compacted", { "mode" => mode, "trigger" => trigger, "task_key" => task_key,
                                    "summary_task_key" => (mode == "prune" ? nil : "k1"), "agent_loop_public_id" => "loop-1" }.compact)]
  end

  KERNEL_GRAPH = compaction_graph("model_task")
  DELEGATE_GRAPH = compaction_graph("tool_task")
  SLEEP_TASKS = [D.tool("r1t0", "read", after: ["r1"], input: { "path" => "notes/brief.txt" }),
                 D.tool("r2t0", "bash", after: ["r2"], input: { "command" => "sleep 20" }),
                 D.tool("r3t0", "bash", after: ["r3"], input: { "command" => "sleep 20" }),
                 D.tool("r4t0", "bash", after: ["r4"], input: { "command" => "printf done > done.txt" })].freeze
  DELEGATE_TASKS = (SLEEP_TASKS + [D.tool("k1", "summarize_history", after: nil)]).freeze
  SUMMARY_FACTS = { "summaries" => { "k1" => "Summary of earlier work:\nTool read notes/brief.txt (completed, 3 KB)\nTool bash sleep 20 (completed)" } }.freeze

  # A wall session: reads of doc-001..doc-004, a prune at r5, more reads.
  WALL_TASKS = (1..6).map { |i| D.tool("r#{i}t0", "read", after: ["r#{i}"], input: { "path" => format("corpus/doc-%03d.txt", i) }) }.freeze
  WALL_GRAPH = D.graph(
    (1..6).flat_map { |i| [D.n("r#{i}", "model_task"), D.n("r#{i}t0", "tool_task")] } + [D.n("r7", "model_task", deliverable: true)],
    (1..6).flat_map { |i| [%W[r#{i} r#{i}t0], %W[r#{i}t0 r#{i + 1}]] }
  )
  # The summarizer `k1` is the kernel's branch (`spine: false`), never a spine round.
  WALL_KERNEL_GRAPH = D.graph(WALL_GRAPH["nodes"] + [D.n("k1", "model_task", spine: false)], WALL_GRAPH["edges"].map(&:values) + [%w[k1 r5]])

  # ── compose scripts (the harness test's canonical ones, rho's names) ───
  # Each step is handed what it reads by name, as the canonical scripts are.
  SCRIPTS = {
    "O1" => <<~JS,
      const reviews = [
        g.model({ prompt: "Read patch.diff and review it for security problems." }),
        g.model({ prompt: "Read patch.diff and review it for performance problems." }),
        g.model({ prompt: "Read patch.diff and review it for style." }),
      ];
      g.parallel(reviews);
      g.model({ prompt: "Weigh the three reviews and give one verdict.", results: reviews });
    JS
    "O2" => <<~JS,
      const user = g.tool({ name: "grep", input: { pattern: "def full_name", path: "app/models/user.rb" } });
      const account = g.tool({ name: "grep", input: { pattern: "def full_name", path: "app/models/account.rb" } });
      const team = g.tool({ name: "grep", input: { pattern: "def full_name", path: "app/models/team.rb" } });
      g.parallel([user, account, team]);
      g.model({ prompt: "Rename full_name to display_name in the file whose grep matched.", results: [user, account, team] });
    JS
    "O3" => <<~JS,
      const race = g.parallel([
        g.tool({ name: "bash", input: { command: "bin/probe alpha" } }),
        g.tool({ name: "bash", input: { command: "bin/probe bravo" } }),
        g.tool({ name: "bash", input: { command: "bin/probe charlie" } }),
      ], { until: "any" });
      g.model({ prompt: "Say which host responded first.", results: [race] });
    JS
    "O4" => <<~JS,
      const lint = g.tool({ name: "bash", input: { command: "bin/rubocop app" } });
      g.parallel([
        g.tool({ name: "bash", input: { command: "bin/rails test" } }),
        [lint, g.model({ prompt: "Fix every offence the lint output names.", results: [lint] })],
      ]);
    JS
    "O7" => <<~JS,
      const normalised = ["a", "b", "c"].map((source) => {
        const fetch = g.tool({ name: "bash", input: { command: "sh bin/fetch " + source } });
        return [fetch, g.model({ prompt: "Normalise source " + source + ".", results: [fetch] })];
      });
      g.parallel(normalised);
      g.model({ prompt: "Merge the three normalised sets.", results: normalised.map((pair) => pair[1]) });
    JS
    "O7b" => <<~JS,
      const tests = g.tool({ name: "bash", input: { command: "bin/rails test" } });
      const testSummary = g.model({ prompt: "Summarise the test failures.", results: [tests] });
      const lint = g.tool({ name: "bash", input: { command: "bin/rubocop app" } });
      const types = g.tool({ name: "bash", input: { command: "bin/srb tc" } });
      const checks = g.parallel([lint, types]);
      const qualitySummary = g.model({ prompt: "Summarise code quality from lint and types.", results: [lint, types] });
      g.parallel([[tests, testSummary], [checks, qualitySummary]]);
      g.model({ prompt: "Write the report from the two summaries.", results: [testSummary, qualitySummary] });
    JS
    "T5" => <<~JS,
      const migrate = g.tool({ name: "bash", input: { command: "bin/rails db:migrate" } });
      const seed = g.tool({ name: "bash", input: { command: "bin/rails db:seed" } });
      const dump = g.tool({ name: "bash", input: { command: "bin/rails db:schema:dump" }, after: [migrate, seed] });
      const migrateReview = g.model({ prompt: "review migrate + dump", results: [migrate, dump] });
      const seedReview = g.model({ prompt: "review seed + dump", results: [seed, dump] });
      const merge = g.model({ prompt: "merge", results: [migrateReview, seedReview] });
      g.parallel([migrate, seed, dump, migrateReview, seedReview, merge]);
    JS
    "FINDERS" => <<~JS,
      const finders = [
        #{%w[auth billing cache export import mailer search webhooks].map { |f| "g.model({ prompt: \"Find the TODO(sec) token in lib/#{f}.rb.\" })" }.join(",\n  ")}
      ];
      g.parallel(finders);
      g.model({ prompt: "Merge the eight findings into one list.", results: finders });
    JS
  }.freeze

  # EACH SCRIPT ON ITS OWN PLAN: the graph the kernel places for it (`Drawing.composed`, drawn once
  # per script here), so a compose row is read on the plan its own script places, and a script
  # scored against another objective's picture is red for its own shape, never for a borrowed
  # graph. O1's — three model members into a fourth — is the fan.
  DRAWN = SCRIPTS.values.to_h { |script| [script, D.composed(script)] }.freeze
  FAN_GRAPH = DRAWN.fetch(SCRIPTS["O1"])
  # A compose call the kernel refused: it placed nothing.
  REFUSED_GRAPH = D.graph(
    [D.n("r1", "model_task"), D.n("r1t0", "tool_task", status: "failed", error_key: "script_error", expansion_parent: "r1"),
     D.n("r2", "model_task", deliverable: true, expansion_parent: "r1")],
    [%w[r1 r1t0], %w[r1t0 r2]]
  )

  def self.compose_trace(script, facts: {}, graph: DRAWN.fetch(script) { D.composed(script) })
    D.trace(graph, [D.tool("r1t0", "compose", after: ["r1"], input: { "script" => script })], [], facts: facts)
  end

  # A REFUSED CALL, THEN ITS REPAIR: the kernel settled r1t0's script `completed` with an error
  # result and placed nothing; the continuation's call r2t0 placed `script`'s plan, which completed.
  def self.repaired_trace(script, facts: {})
    repaired = D.composed(script, call: "r2t0")
    graph = D.graph([D.n("r1", "model_task"), D.n("r1t0", "tool_task", expansion_parent: "r1"), *repaired["nodes"]],
      [%w[r1 r1t0], %w[r1t0 r2], *repaired["edges"].map(&:values)])
    refused = D.tool("r1t0", "compose", after: ["r1"], input: { "script" => "g.model({ prompt: " })
      .merge("result" => { "resolved" => true, "is_error" => true })
    D.trace(graph, [refused, D.tool("r2t0", "compose", after: ["r2"], input: { "script" => script })], [], facts: facts)
  end

  # ── the floor's compose cell (the scorecard's and the ledger's) ────────
  # Four floor records of a compose picture task as the lane writes them — the tier fact, the
  # picture fact, `usable_on_call` — two usable (one of them the picture too), one reached and not
  # usable, one that never reached.
  def self.floor_picture_cell
    [[1, true, true], [2, true, "the picture is not the objective's"], [3, false, "the script was refused"],
     [4, nil, "no compose call to score"]].map do |run, usable, picture|
      D.record(task: "compose-race", family: "compose", model: "fixture/floor", run: run, task_pass: nil,
        reached: !usable.nil?, succeeded: usable,
        facts: { "round_errors" => {}, "attention_reasons" => {}, "rounds_settled" => 3, "tier" => E2E::Evals::Bench::FLOOR,
                 "picture" => picture, "usable_on_call" => (1 if usable) })
    end
  end

  # ── the exit ladder's drawings ─────────────────────────────────────────
  def self.chain(rows)
    nodes = rows.each_with_index.flat_map { |_row, i| [D.n("r#{i + 1}", "model_task"), D.n("r#{i + 1}t0", "tool_task")] }
    edges = rows.each_with_index.flat_map { |_row, i| [%W[r#{i + 1} r#{i + 1}t0], %W[r#{i + 1}t0 r#{i + 2}]] }
    graph = D.graph(nodes + [D.n("r#{rows.size + 1}", "model_task", deliverable: true)], edges)
    tasks = rows.each_with_index.map { |(name, input, extra), i| D.tool("r#{i + 1}t0", name, after: ["r#{i + 1}"], input: input).merge(extra || {}) }
    [graph, tasks]
  end

  SMALL = chain([["bash", { "command" => "ruby -Ilib -Itest test/cart_test.rb" }], ["read", { "path" => "lib/pricing.rb" }],
                 ["edit", { "path" => "lib/pricing.rb" }], ["bash", { "command" => "ruby -Ilib -Itest test/cart_test.rb" }]])
  MEDIUM = chain([["bash", { "command" => "ruby -Ilib -Itest test/all.rb" }], ["read", { "path" => "FEATURE.md" }],
                  ["edit", { "path" => "lib/ledger/entry.rb" }], ["edit", { "path" => "lib/ledger/journal.rb" }],
                  ["write", { "path" => "test/currency_more_test.rb" }], ["bash", { "command" => "ruby -Ilib -Itest test/all.rb" }]])
  LONG_ROWS = [["read", { "path" => "spec/vectors/vec-01.txt" }], ["bash", { "command" => "printf 'vec-01.txt: …' >> VECTORS.md" }, { "approval" => { "origin" => "agent" } }],
               ["start_process", { "command" => "ruby server/app.rb" }, { "approval" => { "origin" => "agent" } }],
               ["read_process", { "id" => "p1" }], ["write", { "path" => "lib/frame_codec.rb" }, { "approval" => { "origin" => "agent" } }]].freeze
  LONG_GRAPH, LONG_TASKS = chain(LONG_ROWS)
  LONG_LADDER = D.graph(
    LONG_GRAPH["nodes"].reject { |n| n["key"] == "r6" } +
      [D.n("r6", "model_task"), D.n("check-1", "tool_task"), D.n("hold-1", "await_task"), D.n("summary", "model_task", deliverable: true)],
    LONG_GRAPH["edges"].map(&:values) + [%w[r6 check-1], %w[check-1 hold-1], %w[hold-1 summary]]
  )
  LONG_ALL_TASKS = (LONG_TASKS + [D.tool("check-1", "bash", after: ["r6"], input: { "command" => "sh check.sh" }).merge("approval" => { "origin" => "author" })]).freeze
  LONG_FACTS = { "park_list" => [{ "key" => "r2t0", "tool" => "bash", "argument" => "printf", "verb" => "approve" },
                                 { "key" => "r3t0", "tool" => "start_process", "argument" => "ruby server/app.rb", "verb" => "approve" },
                                 { "key" => "r5t0", "tool" => "write", "argument" => "lib/frame_codec.rb", "verb" => "approve" }],
                 "parks" => 3, "denied" => 0 }.freeze

  APPROVAL = chain([["bash", { "command" => "printf first > first.txt" }],
                    ["bash", { "command" => "printf second > second.txt" }, { "status" => "failed", "error" => { "key" => "approval_denied", "detail" => "…" } }],
                    ["bash", { "command" => "printf changed > second.txt" }]])
  APPROVAL_FACTS = { "park_list" => [{ "key" => "r1t0", "tool" => "bash", "argument" => "printf first > first.txt", "verb" => "approve" },
                                     { "key" => "r2t0", "tool" => "bash", "argument" => "printf second > second.txt", "verb" => "deny" },
                                     { "key" => "r3t0", "tool" => "bash", "argument" => "printf changed > second.txt", "verb" => "approve" }] }.freeze

  QUEUE = chain((1..3).map { |i| ["bash", { "command" => "cat queue/item-0#{i}.txt && mv queue/item-0#{i}.txt done/" }] } +
    [["write", { "path" => "results/item-03.txt" }]])
  QUEUE_ONE_SHOT = chain([["bash", { "command" => "for f in queue/*.txt; do echo $((2 * $(cat $f))) > results/$(basename $f); mv $f done/; done" }]])

  # THE RECEIPT DOOR (loop-until-dry's "a task per pass, each receipt waking the next"): r1 detaches
  # a `task` whose delegate takes the head item (`r3t0`, a round key its root made), and each of
  # the `receipts` wakes a turn that detaches the next — those turns are loops of their own, whose
  # rows the trace does not hold, so one take is traced and every receipt is on the feed. `take`
  # is the delegate's command.
  QUEUE_HEAD_PICK = 'h=$(ls queue | head -n1); n=$(cat "queue/$h"); echo $((n * 2)) > "results/$h"; mv "queue/$h" done/'.freeze

  def self.receipt_door(receipts, take: QUEUE_HEAD_PICK)
    graph = D.graph(
      [D.n("r1", "model_task"), D.n("r1t0", "tool_task"), D.n("r1t0-model-1", "model_task", spine: false),
       D.n("r3t0", "tool_task"), D.n("r3", "model_task", spine: false), D.n("r2", "model_task", deliverable: true)],
      [%w[r1 r1t0], %w[r1t0 r1t0-model-1], %w[r1t0-model-1 r3t0], %w[r3t0 r3], %w[r1t0 r2]]
    )
    tasks = [D.tool("r1t0", "task", after: ["r1"], input: { "prompt" => "Process the head item of queue/.", "wait" => false }),
             D.tool("r3t0", "bash", after: ["r1t0-model-1"], input: { "command" => take })]
    loops = (1..(receipts + 1)).map { |i| { "id" => "loop-#{i}", "status" => "completed" } }
    events = loops.each_with_index.flat_map do |row, i|
      mail = { "origin" => "task_result", "kind" => "direct_reply", "delivery_mode" => "queue", "agent_loop_public_id" => row["id"] }
      [*(i.zero? ? [] : [D.event("input_accepted", mail)]),
       D.event("turn_status", { "agent_loop_public_id" => row["id"], "loop_status" => "completed" })]
    end
    D.trace(graph, tasks, events, loops: loops)
  end

  PROCESSES = chain([["start_process", { "command" => "sh serve.sh", "wait_for" => "Serving HTTP" }],
                     ["bash", { "command" => "curl -s http://127.0.0.1:4321/hello.txt" }]])
  PROCESS_FACTS = { "reply" => "hello from the project abc", "listed_under_loop" => true, "served_on_port" => "hello from the project abc\n",
                    "killed" => true, "port_freed" => true, "log_under_home" => true }.freeze

  HANDOFF_FACTS = { "handed_off" => true, "tree_synced" => true, "turn_2_bash_rows" => 1, "turn_2_bash_on_runner" => true,
                    "runner_log_claimed_turn_2" => true, "own_runner_idle_after" => true, "reply" => "DONE" }.freeze

  MEMORY = chain([["read", { "path" => "TOKEN.txt" }], ["memory_write", { "path" => "user/token.md", "content" => "zqabc" }]])
  MEMORY_FACTS = { "memory_paths" => ["user/token.md"], "note_under_user" => true, "note_carries_token" => true,
                   "other_workspace_carries_token" => true, "other_workspace_reply" => "zqabc" }.freeze

  # ── what a composed step is owed (`ComposedReads`, the kernel check) ──
  # A race's plan as the route serves it: every drawn edge structural — a barrier's in-edges and
  # every wait — and among the task rows the compose call's and each race's settlement
  # (`result.outcomes`, the snapshot `JoinTask#winning_source_keys` reads). Keys are the builder's; a
  # stage-placed race's are ids no model saw. Each shape takes the reader's `result_from` — what its
  # `results:` named, as the kernel stores it — and reads nothing by position.
  RACE = { "until" => "any", "losers" => "cancel" }.freeze
  RACE_JOIN = "r1t0-parallel-1".freeze

  def self.race_trace(nodes, edges, joins, call: "r1t0")
    graph = D.graph(nodes, edges)
    graph = graph.merge("edges" => graph["edges"].map { |edge| edge.merge("structural" => true) })
    round = call.sub(/t\d+\z/, "")
    D.trace(graph, [D.tool(call, "compose", after: [round], input: { "script" => "/* the plan drawn below */" }), *joins], [])
  end

  def self.settled(key, outcomes, status: "completed")
    { "key" => key, "kind" => "join_task", "status" => status, "result" => { "outcomes" => outcomes } }
  end

  # The call `r1t0` of round `r1`, and `r2` after it reading the call alone (a detached compose).
  def self.under_call(*steps, reader)
    [D.n("r1", "model_task"), D.n("r1t0", "tool_task", expansion_parent: "r1"), *steps, reader,
     D.n("r2", "model_task", deliverable: true, expansion_parent: "r1", input_from: %w[r1 r1t0])]
  end

  # compose-race-anon's shape: three [probe, wrap] arms raced, the second won and the other two were
  # canceled; the call's model step after the race names what `result_from` says.
  def self.staged_arms(result_from)
    probes = (1..3).map { |i| "r1t0-tool-#{i}" }
    wraps = (1..3).map { |i| "r1t0-script-#{i}" }
    status = %w[canceled completed canceled]
    arms = (0..2).flat_map do |i|
      [D.n(probes[i], "tool_task", status: status[i], expansion_parent: "r1t0"),
       D.n(wraps[i], "script_task", status: status[i], expansion_parent: "r1t0", result_from: [probes[i]])]
    end
    nodes = under_call(*arms, D.n(RACE_JOIN, "join_task", join: RACE, expansion_parent: "r1t0"),
      D.n("r1t0-model-1", "model_task", spine: false, expansion_parent: "r1t0", result_from: result_from))
    edges = [%w[r1 r1t0], *probes.map { |probe| ["r1t0", probe] }, *probes.zip(wraps), *wraps.map { |wrap| [wrap, RACE_JOIN] },
             [RACE_JOIN, "r1t0-model-1"], %w[r1t0 r2]]
    race_trace(nodes, edges, [settled(RACE_JOIN, wraps.zip(%w[waiting completed waiting]).to_h)])
  end

  # compose-race deepseek-flash #1's shape: three stages each placed [probe, wrap] (keyed by ids), the
  # race over the wraps; the stage-placed wraps are a stage's, and the step after the race the call's.
  STAGE_PLACED = (1..6).map { |i| format("01a0d536-6fd2-7c01-9f01-48b799c9ca%02d", i) }.freeze

  def self.stage_placed(result_from)
    stages = (1..3).map { |i| "r1t0-script-#{i}" }
    probes, wraps = STAGE_PLACED.each_slice(3).to_a
    status = %w[canceled completed canceled]
    placed = (0..2).flat_map do |i|
      [D.n(stages[i], "script_task", expansion_parent: "r1t0"),
       D.n(probes[i], "tool_task", status: status[i], expansion_parent: stages[i]),
       D.n(wraps[i], "script_task", status: status[i], expansion_parent: stages[i], result_from: [probes[i]])]
    end
    nodes = under_call(*placed, D.n(RACE_JOIN, "join_task", join: RACE, expansion_parent: "r1t0"),
      D.n("r1t0-model-1", "model_task", spine: false, expansion_parent: "r1t0", result_from: result_from))
    edges = [%w[r1 r1t0], *stages.map { |stage| ["r1t0", stage] }, *stages.zip(probes), *probes.zip(wraps),
             *wraps.map { |wrap| [wrap, RACE_JOIN] }, [RACE_JOIN, "r1t0-model-1"], %w[r1t0 r2]]
    race_trace(nodes, edges, [settled(RACE_JOIN, wraps.zip(%w[waiting completed waiting]).to_h)])
  end

  # A FAILED QUORUM (`until: 2`, absorbed): three [probe, wrap] arms; the first arm answered, the
  # other two probes failed and their wraps were skipped, so the race failed quorum_unreachable
  # holding its one partial winner.
  def self.failed_quorum(result_from)
    probes = (1..3).map { |i| "r1t0-tool-#{i}" }
    wraps = (1..3).map { |i| "r1t0-script-#{i}" }
    arms = (0..2).flat_map do |i|
      [D.n(probes[i], "tool_task", status: (i.zero? ? "completed" : "failed"), expansion_parent: "r1t0"),
       D.n(wraps[i], "script_task", status: (i.zero? ? "completed" : "skipped"), expansion_parent: "r1t0", result_from: [probes[i]])]
    end
    nodes = under_call(*arms,
      D.n(RACE_JOIN, "join_task", status: "failed", error_key: "quorum_unreachable", join: RACE.merge("until" => 2), expansion_parent: "r1t0"),
      D.n("r1t0-model-1", "model_task", spine: false, expansion_parent: "r1t0", result_from: result_from))
    edges = [%w[r1 r1t0], *probes.map { |probe| ["r1t0", probe] }, *probes.zip(wraps), *wraps.map { |wrap| [wrap, RACE_JOIN] },
             [RACE_JOIN, "r1t0-model-1"], %w[r1t0 r2]]
    race_trace(nodes, edges, [settled(RACE_JOIN, wraps.zip(%w[completed skipped skipped]).to_h, status: "failed")])
  end

  # A QUORUM OF TWO WHOSE WINNERS FINISHED OUT OF PLACEMENT ORDER: three probes raced `until: 2`,
  # the third answering first and the first second; the settlement's outcomes are written in
  # placement order, the task rows say when each finished.
  def self.quorum_out_of_order(result_from)
    probes = (1..3).map { |i| "r1t0-tool-#{i}" }
    status = %w[completed canceled completed]
    arms = probes.zip(status).map { |probe, state| D.n(probe, "tool_task", status: state, expansion_parent: "r1t0") }
    nodes = under_call(*arms, D.n(RACE_JOIN, "join_task", join: RACE.merge("until" => 2), expansion_parent: "r1t0"),
      D.n("r1t0-model-1", "model_task", spine: false, expansion_parent: "r1t0", result_from: result_from))
    edges = [%w[r1 r1t0], *probes.map { |probe| ["r1t0", probe] }, *probes.map { |probe| [probe, RACE_JOIN] },
             [RACE_JOIN, "r1t0-model-1"], %w[r1t0 r2]]
    finished = [D.tool(probes[0], "bash").merge("completed_at" => "2026-09-26T10:00:05.000Z"),
                D.tool(probes[2], "bash").merge("completed_at" => "2026-09-26T10:00:02.000Z")]
    race_trace(nodes, edges, [*finished, settled(RACE_JOIN, probes.zip(%w[completed waiting completed]).to_h)])
  end

  # A MEMBER THAT USED TOOLS, NAMED BY A LATER STEP: `model-1` called `bash` and its round `r3`
  # continued it — the kernel re-points the later step's name at `r3`, and the envelope names the
  # step, `model-1`, whose brief it carries. `input_from` draws what the kernel handed the reader
  # by position — nothing, on a composed step.
  def self.continued_member(input_from: nil)
    nodes = under_call(D.n("r1t0-model-1", "model_task", spine: false, expansion_parent: "r1t0"),
      D.n("r1t0-model-1t0", "tool_task", expansion_parent: "r1t0-model-1"),
      D.n("r3", "model_task", spine: false, expansion_parent: "r1t0-model-1", input_from: %w[r1t0-model-1 r1t0-model-1t0]),
      D.n("r1t0-model-2", "model_task", spine: false, expansion_parent: "r1t0", input_from: input_from, result_from: %w[r3]))
    edges = [%w[r1 r1t0], %w[r1t0 r1t0-model-1], %w[r1t0-model-1 r1t0-model-1t0], %w[r1t0-model-1t0 r3], %w[r3 r1t0-model-2],
             %w[r1t0 r2]]
    race_trace(nodes, edges, [])
  end

  # ── workflow-scout-then-fan (D6): list first, then fan over what was listed ──
  # The fixture's eleven sources under lib/ and the five that define a class with a `call` method;
  # two of the six others hold a `def call` inside a module (the near-miss a grep for it lists).
  SCOUT_FILES = %w[csv_out date_parse index_build ledger_close queue_drain relay_send sign_payload slug sweep_stale
                   token_bucket zip_reader].freeze
  SCOUT_CALLERS = %w[csv_out ledger_close relay_send sweep_stale token_bucket].freeze
  SCOUT_NEAR_MISSES = %w[date_parse queue_drain].freeze
  # What rho's `ls` and `grep` return over lib/: bare names, relative to the path searched.
  SCOUT_LS = ["ls", { "path" => "lib" }, { "output" => SCOUT_FILES.map { |f| "#{f}.rb" }.join("\n") }].freeze
  SCOUT_GREP = ["grep", { "pattern" => "def call", "path" => "lib" },
                { "output" => (SCOUT_CALLERS + SCOUT_NEAR_MISSES).sort.map { |f| "#{f}.rb:4:  def call" }.join("\n") }].freeze

  # One review per named file, handed out as a detached `task`.
  def self.scout_reviews(stems) = stems.map { |f| ["task", { "prompt" => "Review lib/#{f}.rb: one line, your verdict.", "wait" => false }] }

  # ── the two-sided table ────────────────────────────────────────────────
  GREEN = {
    "shape-linear" => D.trace(LINEAR_GRAPH, LINEAR_TASKS, [], spend: { "cost_amount" => 0.02, "cost_unit" => "USD" }),
    "shape-fan-join" => compose_trace(SCRIPTS["O1"], facts: { "reply" => FIVE_REPLY }),
    "shape-ask-human" => D.trace(ASK_GRAPH, ASK_TASKS, ASK_EVENTS),
    "shape-halt-retry" => D.trace(HALT_GRAPH, [], []),
    "shape-repeat-brake" => D.trace(BRAKE_GRAPH, BRAKE_TASKS, BRAKE_EVENTS, status: "needs_attention"),
    "compose-review-angles" => compose_trace(SCRIPTS["O1"]),
    "compose-grep-then-edit" => compose_trace(SCRIPTS["O2"]),
    "compose-race" => compose_trace(SCRIPTS["O3"], facts: { "reply" => "bravo won" }),
    "compose-race-anon" => compose_trace(SCRIPTS["O3"], facts: { "reply" => "bravo won" }),
    "compose-background-suite" => compose_trace(SCRIPTS["O4"]),
    "compose-single-read" => D.trace(LINEAR_GRAPH, [D.tool("r1t0", "read", after: ["r1"], input: { "path" => "app.yml" })], [], facts: { "reply" => "warn" }),
    "compose-three-stage-pairing" => compose_trace(SCRIPTS["O7"]),
    "compose-two-source-fan-in" => compose_trace(SCRIPTS["O7b"]),
    "compose-rendezvous" => compose_trace(SCRIPTS["T5"]),
    "task-two-calls" => D.trace(*three_wide(%w[read read read], [{ "path" => "lib/alpha.rb" }, { "path" => "lib/bravo.rb" }, { "path" => "lib/charlie.rb" }]),
      [], facts: { "reply" => "lib/charlie.rb defines run" }),
    "task-background-suite" => D.trace(MAIL_GRAPH,
      [D.tool("r1t0", "task", after: ["r1"], input: { "prompt" => "Run bin/rails test and report", "wait" => false }),
       D.tool("r1t1", "bash", after: ["r1"], input: { "command" => "bin/rubocop app" })], MAIL_EVENTS),
    "task-grep-three-control" => D.trace(*three_wide(%w[grep grep grep], %w[app db cache].map { |f| { "pattern" => "debug", "path" => "config/#{f}.yml" } }),
      [], facts: { "reply" => "config/db.yml and config/cache.yml set debug to true" }),
    "task-mail" => D.trace(MAIL_GRAPH, MAIL_TASKS, MAIL_EVENTS, facts: MAIL_FACTS,
      loops: [{ "id" => "loop-1", "status" => "completed" }, { "id" => "loop-2", "status" => "completed" }]),
    "task-fan-five" => D.trace(FIVE_GRAPH, FIVE_TASKS, [], facts: { "reply" => FIVE_REPLY }),
    "task-detached-receipt" => D.trace(MAIL_GRAPH, MAIL_TASKS, MAIL_EVENTS, facts: MAIL_FACTS),
    "spawn-subagent-suite" => D.trace(SPAWN_GRAPH, SPAWN_TASKS, SPAWN_EVENTS, facts: SPAWN_FACTS,
      loops: [{ "id" => "loop-1", "status" => "completed" }, { "id" => "loop-2", "status" => "completed" }]),
    "spawn-peer-relay" => D.trace(PEER_GRAPH, PEER_TASKS, [], facts: PEER_FACTS),
    "approval-reformulate" => D.trace(*APPROVAL, [], facts: APPROVAL_FACTS),
    "until-ladder" => D.trace(UNTIL_GRAPH, [D.tool("r1t0", "write", after: ["r1"], input: { "path" => "note.txt" })], []),
    "processes-dev-server" => D.trace(*PROCESSES, [], facts: PROCESS_FACTS),
    "handoff-mid-conversation" => D.trace(LINEAR_GRAPH, [D.tool("r1t0", "write", after: ["r1"], input: { "path" => "hello.txt" }),
                                                        D.tool("r2t0", "bash", after: ["r2"], input: { "command" => "cat hello.txt" })], [], facts: HANDOFF_FACTS),
    "memory-user-scope" => D.trace(*MEMORY, [], facts: MEMORY_FACTS),
    "ask-codeword" => D.trace(ASK_GRAPH, ASK_TASKS, ASK_EVENTS, facts: { "asked_prompt" => "What is the codeword?" }),
    "exit-small" => D.trace(*SMALL, []),
    "exit-medium" => D.trace(*MEDIUM, []),
    "exit-long" => D.trace(LONG_LADDER, LONG_ALL_TASKS, [D.event("attention_required", { "reason" => "approval_required" })], facts: LONG_FACTS),
    "workflow-fan-out-finders" => compose_trace(SCRIPTS["FINDERS"], facts: { "reply" => "eight tokens" }),
    "workflow-adversarial-verify" => D.trace(FIVE_GRAPH, FIVE_TASKS.map { |row| row.merge("tool_input" => row["tool_input"].merge("wait" => false)) }, MAIL_EVENTS,
      loops: [{ "id" => "loop-1", "status" => "completed" }, { "id" => "loop-2", "status" => "completed" }]),
    "workflow-judge-panel" => compose_trace(SCRIPTS["O1"], facts: { "reply" => "winner: b" }),
    "workflow-barrier-free-pipeline" => compose_trace(SCRIPTS["O7"]),
    "workflow-loop-until-dry" => D.trace(*QUEUE, []),
    "workflow-scout-then-fan" => spine([SCOUT_LS, SCOUT_GREP], scout_reviews(SCOUT_CALLERS)),
    "compaction-kernel-manual" => D.trace(KERNEL_GRAPH, SLEEP_TASKS, compaction_events("kernel"), facts: SUMMARY_FACTS),
    "compaction-delegate-manual" => D.trace(DELEGATE_GRAPH, DELEGATE_TASKS, compaction_events("delegate"), facts: SUMMARY_FACTS),
    "compaction-wall-long" => D.trace(WALL_GRAPH, WALL_TASKS, compaction_events("prune", trigger: "wall", task_key: "r5"), facts: { "checks" => ["check 1/6: passed"] }),
    "compaction-wall-kernel" => D.trace(WALL_KERNEL_GRAPH, WALL_TASKS, compaction_events("kernel", trigger: "wall", task_key: "r5"),
      facts: { "summaries" => { "k1" => "Summary of earlier work:\nTool read src/part-01.txt (completed, 45 KB)" } }),
  }.freeze

  # The wrong shape, and the sentence it must answer with.
  RED = {
    "shape-linear" => [compose_trace(SCRIPTS["O1"]), /outside the spine/],
    "shape-fan-join" => [D.trace(LINEAR_GRAPH, LINEAR_TASKS, []), /no compose call/],
    "shape-ask-human" => [D.trace(LINEAR_GRAPH, LINEAR_TASKS, []), /no ask/],
    "shape-halt-retry" => [D.trace(LINEAR_GRAPH, LINEAR_TASKS, []), /authored gates are not on the graph/],
    "shape-repeat-brake" => [D.trace(LINEAR_GRAPH, LINEAR_TASKS, []), /no round was refused repeat_call_loop/],
    "compose-review-angles" => [compose_trace(SCRIPTS["O2"]), /the picture is not the objective's/],
    "compose-grep-then-edit" => [compose_trace(SCRIPTS["O1"]), /the picture is not the objective's/],
    "compose-race" => [D.trace(LINEAR_GRAPH, LINEAR_TASKS, []), /no compose call/],
    "compose-race-anon" => [compose_trace(SCRIPTS["O1"]), /the picture is not the objective's/],
    "compose-background-suite" => [compose_trace(SCRIPTS["O7"]), /the picture is not the objective's/],
    "compose-single-read" => [compose_trace(SCRIPTS["O1"]), /over-reach/],
    "compose-three-stage-pairing" => [compose_trace(SCRIPTS["O4"]), /the picture is not the objective's/],
    "compose-two-source-fan-in" => [D.trace(LINEAR_GRAPH, LINEAR_TASKS, []), /no compose call/],
    "compose-rendezvous" => [D.trace(LINEAR_GRAPH, LINEAR_TASKS, []), /no compose call/],
    "task-two-calls" => [D.trace(LINEAR_GRAPH, [D.tool("r1t0", "read", after: ["r1"], input: { "path" => "lib/alpha.rb" })], []), /fanned 1 call/],
    "task-background-suite" => [D.trace(LINEAR_GRAPH, LINEAR_TASKS, []), /no `task` call/],
    "task-grep-three-control" => [D.trace(*three_wide(%w[task task task], %w[app db cache].map { |f| { "prompt" => "Does config/#{f}.yml set debug: true?" } }), []),
                                  /over-reach/],
    "task-mail" => [D.trace(LINEAR_GRAPH, LINEAR_TASKS, [], facts: { "turn_1_called" => { "start_process" => 1 } }), /no `task` call/],
    "task-fan-five" => [D.trace(MAIL_GRAPH, MAIL_TASKS, MAIL_EVENTS), /1 task call\(s\) in the first message/],
    "task-detached-receipt" => [D.trace(LINEAR_GRAPH, LINEAR_TASKS, []), /no `task` call/],
    "spawn-subagent-suite" => [D.trace(LINEAR_GRAPH, LINEAR_TASKS, [], facts: { "turn_1_called" => { "bash" => 2 } }), /no `spawn` call/],
    "spawn-peer-relay" => [D.trace(PEER_GRAPH, [D.tool("r1t0", "spawn", after: ["r1"], input: { "prompt" => "Review lib/calc.rb", "wait" => true })], [],
      facts: PEER_FACTS), /the spawn named no peer/],
    "approval-reformulate" => [D.trace(*APPROVAL, [], facts: { "park_list" => [] }), /nothing parked/],
    "until-ladder" => [D.trace(LINEAR_GRAPH, LINEAR_TASKS, []), /missing from the ladder/],
    "processes-dev-server" => [D.trace(LINEAR_GRAPH, LINEAR_TASKS, []), /never called start_process/],
    "handoff-mid-conversation" => [D.trace(LINEAR_GRAPH, [LINEAR_TASKS.first], [], facts: HANDOFF_FACTS), /turn 1 ran no shell command/],
    "memory-user-scope" => [D.trace(LINEAR_GRAPH, LINEAR_TASKS, []), /no memory_write row/],
    "ask-codeword" => [D.trace(LINEAR_GRAPH, LINEAR_TASKS, []), /no ask/],
    "exit-small" => [D.trace(LINEAR_GRAPH, LINEAR_TASKS, []), /the suite was never run/],
    "exit-medium" => [D.trace(LINEAR_GRAPH, LINEAR_TASKS, []), /never explored the project/],
    "exit-long" => [D.trace(LINEAR_GRAPH, LINEAR_TASKS, []), /no whole-file read of a vector/],
    "workflow-fan-out-finders" => [D.trace(*three_wide(%w[grep grep grep], [{ "pattern" => "TODO" }] * 3), []), /no compose call and no round fanned two task calls/],
    "workflow-adversarial-verify" => [D.trace(FIVE_GRAPH, FIVE_TASKS, []), /no input_accepted/],
    "workflow-judge-panel" => [D.trace(LINEAR_GRAPH, LINEAR_TASKS, []), /no compose call and no round fanned two task calls/],
    "workflow-barrier-free-pipeline" => [D.trace(FIVE_GRAPH, FIVE_TASKS, []), /the task door cannot pair/],
    "workflow-loop-until-dry" => [D.trace(*QUEUE_ONE_SHOT, []), /no iteration/],
    "workflow-scout-then-fan" => [spine(scout_reviews(SCOUT_FILES)), /\Afanned over guessed names: lib\/csv_out\.rb, /],
    "compaction-kernel-manual" => [D.trace(KERNEL_GRAPH, SLEEP_TASKS, compaction_events("delegate"), facts: SUMMARY_FACTS), /mode "delegate", expected kernel/],
    "compaction-delegate-manual" => [D.trace(KERNEL_GRAPH, SLEEP_TASKS, compaction_events("delegate"), facts: SUMMARY_FACTS), /k1 is model_task, expected tool_task/],
    "compaction-wall-long" => [D.trace(WALL_GRAPH, WALL_TASKS, []), /never overflowed on a fact/],
    "compaction-wall-kernel" => [D.trace(WALL_GRAPH, WALL_TASKS, compaction_events("prune", trigger: "wall", task_key: "r5")), /every wall pruned/],
  }.freeze

  # ── the passive wake, by what each task asked ──────────────────────────
  # Every call asked `wake: "passive"`: green where the instruction leaves the wake open and turn 2
  # read the receipt from the history; red where the instruction asked to be told when the suite
  # ends, with the sentence it must answer.
  TWO_LOOPS = [{ "id" => "loop-1", "status" => "completed" }, { "id" => "loop-2", "status" => "completed" }].freeze
  PASSIVE_GREEN = {
    "task-mail" => D.trace(MAIL_GRAPH, MAIL_PASSIVE_TASKS, MAIL_PASSIVE_EVENTS, facts: MAIL_PASSIVE_FACTS, loops: TWO_LOOPS),
    "spawn-subagent-suite" => D.trace(SPAWN_GRAPH, SPAWN_PASSIVE_TASKS, SPAWN_PASSIVE_EVENTS, facts: SPAWN_PASSIVE_FACTS, loops: TWO_LOOPS),
  }.freeze
  PASSIVE_RED = {
    "task-detached-receipt" => [D.trace(MAIL_GRAPH, MAIL_PASSIVE_TASKS, MAIL_PASSIVE_EVENTS.first(2), facts: MAIL_PASSIVE_FACTS),
                                /\Aonly 1 loop completed on the feed: the receipt woke no turn — the call asked `wake: "passive"`, so no turn told the person whether the suite passed\z/],
  }.freeze
end
