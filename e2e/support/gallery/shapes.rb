require "json"
require_relative "../coding_task"

module E2E
  # THE LOOP-SHAPE GALLERY'S TABLE (a journey reads the graph to assert a loop's shape; it never
  # authors edges). Nine tasks of deliberately different shape, each with the text a real model is
  # given, the way the journey drives it, the sentence a reviewer reads above the picture, and a
  # PREDICATE over what the member plane serves.
  #
  # A PREDICATE READS `(graph, tasks, events)` AND NAMES STRUCTURE ONLY: kinds, edges, join words,
  # error keys, event payloads — never a round count or a fan width a model may vary (those are
  # printed by the lane). `graph` is the route's JSON (`nodes`, `edges`, `mermaid`); the node
  # carries no `tool_name` and no detach intent, so `tasks` — the loop row's task rows, tool rows
  # joined with their `tool_input` — and `events` — the conversation feed's `context_compacted`,
  # `attention_required`, `input_accepted` and `turn_status` items — ride beside it. A predicate
  # answers `true` or a String: the reason, which becomes the red row's message and the artifact's
  # verdict line. Pure Ruby: nothing here loads a lane, so the harness test runs every predicate on
  # hand-drawn triples without a daemon.
  module Gallery
    # `files` are written under the shape's fresh project dir before the
    # turn opens; `driver` is the Symbol the journey dispatches.
    Shape = Data.define(:id, :task, :driver, :expected, :compaction, :files, :predicate) do
      def delegate? = compaction == :delegate
    end

    # A ROUND'S KEY — `rN` rounds and `rNtM` calls, the loop-global counter —
    # and the roots the kernel's flat tools mint under a call
    # (`LiveJourney::BRANCH_ROOT`; restated because support must not load
    # the lane mixin). A round key is NOT the mainline: a task branch's own
    # rounds and calls are counted on the same counter, and the mainline is the
    # kernel's mark (`mainline_keys`).
    ROUND_KEY = /\Ar\d+(?:t\d+)?\z/
    BRANCH_ROOT = /\A(?<call>r\d+t\d+)-(?:model|ask)-1\z/
    UNDER_CALL = /\A(?<call>r\d+t\d+)-/
    TERMINAL_TASK_STATUSES = %w[completed failed canceled timed_out uncertain skipped].freeze
    # THE BRAKE'S TWO WORDS (ExpandRound::EXPANSION_REFUSED / RepeatBrake::REPEAT_LOOP):
    # the refused round's `error.key` names the refusal, its `error.detail`
    # the brake — and the graph node carries the KEY alone.
    EXPANSION_REFUSED = "round_expansion_refused".freeze
    REPEAT_LOOP = "repeat_call_loop".freeze

    module_function

    def round_key?(key) = ROUND_KEY.match?(key.to_s)
    def branch_root?(key) = BRANCH_ROOT.match?(key.to_s)
    # The `rNtM` a branch key hangs from; nil for a round key or an authored word.
    def call_of(key) = UNDER_CALL.match(key.to_s)&.[](:call)

    # THE MAINLINE IS THE KERNEL'S MARK: the rounds the graph route marks `mainline: true` — the
    # conversation's own thread — in node order; a branch's rounds are marked `false` whatever
    # their keys.
    def mainline_keys(graph) = Array(graph["nodes"]).select { |node| node["mainline"] == true }.map { |node| node["key"] }

    def nodes_of(graph, kind:) = Array(graph["nodes"]).select { |node| node["kind"] == kind }
    def node(graph, key) = Array(graph["nodes"]).find { |node| node["key"] == key }
    def edge?(graph, from, to) = Array(graph["edges"]).any? { |edge| edge["from"] == from && edge["to"] == to }
    def edges_into(graph, key) = Array(graph["edges"]).select { |edge| edge["to"] == key }.map { |edge| edge["from"] }
    def edges_out_of(graph, key) = Array(graph["edges"]).select { |edge| edge["from"] == key }.map { |edge| edge["to"] }
    def task(tasks, key) = Array(tasks).find { |row| row["key"] == key }
    def tool_rows(tasks, name) = Array(tasks).select { |row| row["kind"] == "tool_task" && row["tool_name"] == name }
    def events_of(events, type) = Array(events).select { |item| item["type"] == type }
    def payloads(events, type) = events_of(events, type).map { |item| Hash(item["payload"]) }

    def find(id) = SHAPES.find { |shape| shape.id == id.to_sym }

    def placed_by(graph, call)
      nodes = Array(graph["nodes"])
      if marked?(graph)
        children = nodes.group_by { |node| node["expansion_parent"] }
        placed = Set.new
        frontier = children.fetch(call, [])
        until frontier.empty?
          placed.merge(frontier.map { |node| node["key"] })
          frontier = frontier.select { |node| node["kind"] == "tool_task" }
            .flat_map { |stage| children.fetch(stage["key"], []) }.reject { |node| placed.include?(node["key"]) }
        end
        nodes.select { |node| placed.include?(node["key"]) }
      else
        nodes.select { |node| call_of(node["key"]) == call }
      end
    end

    # Whether the graph carries the kernel's ownership mark: the route serves `expansion_parent` on
    # every node something placed, so a graph with none predates the mark.
    def marked?(graph) = Array(graph["nodes"]).any? { |node| node.key?("expansion_parent") }

    # A wrong shape answers with WHY, in the trace's own words: the String
    # is the red row's message and the artifact's verdict line.

    # ── 1. linear ────────────────────────────────────────────────────────
    # A chain: rounds fan tools, every tool feeds the next round, nothing
    # branches, nobody is asked. Fan width and round count are free.
    def linear?(graph, _tasks, _events)
      outside = Array(graph["nodes"]).map { |n| n["key"] }.reject { |key| round_key?(key) }
      return "a node outside the mainline: #{outside.first(4).join(", ")}" if outside.any?
      return "a join_task on a linear loop" if nodes_of(graph, kind: "join_task").any?
      return "an await_task on a linear loop: nobody should be asked" if nodes_of(graph, kind: "await_task").any?
      return "fewer than two rounds: #{nodes_of(graph, kind: "model_task").size}" if
        nodes_of(graph, kind: "model_task").size < 2

      nodes_of(graph, kind: "tool_task").each do |tool|
        into = edges_into(graph, tool["key"])
        out = edges_out_of(graph, tool["key"])
        unless into.size == 1 && node(graph, into.first)&.fetch("kind") == "model_task"
          return "#{tool["key"]} is not fanned by exactly one round: #{into.inspect}"
        end
        unless out.size == 1 && node(graph, out.first)&.fetch("kind") == "model_task"
          return "#{tool["key"]} does not feed exactly one round: #{out.inspect}"
        end
      end
      true
    end

    # A tool-owned fan has at least two model members feeding a completed merge task.
    def fan_join?(graph, tasks, _events)
      calls = Array(tasks).select { |row| row["kind"] == "tool_task" }
      fans = calls.filter_map { |call| fan_under(graph, call["key"]) }
      return fans_refused(graph, calls) if fans.empty?

      merge = fans.first
      return "the merge step #{merge["key"]} did not complete: #{merge["status"]}" unless merge["status"] == "completed"

      true
    end

    # The first model step the call placed (`placed_by`, a stage's placements included) with ≥ 2
    # model members feeding it — directly (`all`), or through a join row (a race).
    def fan_under(graph, call)
      members = placed_by(graph, call)
      models = members.select { |n| n["kind"] == "model_task" }
      joins = members.select { |n| n["kind"] == "join_task" }
      models.find do |candidate|
        sources = edges_into(graph, candidate["key"])
        direct = sources.count { |key| models.any? { |m| m["key"] == key } }
        next true if direct >= 2

        joins.any? do |join|
          sources.include?(join["key"]) &&
            edges_into(graph, join["key"]).count { |key| models.any? { |m| m["key"] == key } } >= 2
        end
      end
    end

    def fans_refused(graph, calls)
      calls.map do |call|
        "#{call["key"]} placed #{placed_by(graph, call["key"]).size} tasks and no step reads two model members"
      end.join("; ")
    end

    # ── 3. ask_human ─────────────────────────────────────────────────────
    # The model's `ask`: an await under the call, answered, feeding the
    # round that used the answer; the feed called for a person once.
    def ask_human?(graph, _tasks, events)
      asks = nodes_of(graph, kind: "await_task").select { |n| n["key"].end_with?("-ask-1") }
      return "no ask: the model never called `ask`" if asks.empty?

      ask = asks.first
      return "the ask #{ask["key"]} was not answered: #{ask["status"]}" unless ask["status"] == "completed"

      reader = edges_out_of(graph, ask["key"]).map { |key| node(graph, key) }
        .find { |n| n && n["kind"] == "model_task" && n["status"] == "completed" }
      return "no completed round reads the answer of #{ask["key"]}" if reader.nil?
      return "the feed never called for a person" if events_of(events, "attention_required").empty?

      true
    end

    # ── 4. halt_retry ────────────────────────────────────────────────────
    # The authored halt (`live_repair`): two one-second gates the round
    # waits on; one abandoned (its timeout stays on the node), one retried
    # and answered, the round ran. Exact by construction.
    def halt_retry?(graph, _tasks, _events)
      gate_1 = node(graph, "gate-1")
      gate_2 = node(graph, "gate-2")
      work = node(graph, "work")
      return "the authored keys are missing: #{[gate_1, gate_2, work].map { |n| n&.fetch("key") }.inspect}" if
        [gate_1, gate_2, work].any?(&:nil?)
      return "gate-1 is not an await_task" unless gate_1["kind"] == "await_task"
      return "gate-1 carries no error: it was not abandoned after timing out (#{gate_1["status"]})" if
        gate_1["error_key"].nil? || gate_1["status"] == "completed"
      return "gate-2 was not retried and answered: #{gate_2["status"]}" unless
        gate_2["kind"] == "await_task" && gate_2["status"] == "completed"
      return "work did not run once the gates were resolved: #{work["status"]}" unless
        work["kind"] == "model_task" && work["status"] == "completed"
      return "work is not the deliverable" unless work["deliverable"] == true
      return "work does not wait on both gates" unless edge?(graph, "gate-1", "work") && edge?(graph, "gate-2", "work")

      true
    end

    # ── 5/6. compaction_kernel / compaction_delegate ─────────────────────
    # The manual door on a queued round while a tool runs: a `k1` summary
    # root hung under the round (edge `k1 → rN`), one `context_compacted`
    # naming both keys with `trigger: manual`, the round composed from the
    # summary and completed. The kernel's summarizer is a model_task; the
    # delegate's is rho's own `summarize_history` tool row.
    def compaction?(graph, tasks, events, mode:)
      items = payloads(events, "context_compacted")
      return "no context_compacted item: the door never armed" if items.empty?

      manual = items.select { |p| p["trigger"] == "manual" }
      return "no manual compaction; triggers: #{items.map { |p| p["trigger"] }.inspect}" if manual.empty?
      return "the door armed #{manual.size} times" unless manual.one?

      item = manual.first
      return "mode #{item["mode"].inspect}, expected #{mode}" unless item["mode"] == mode
      return "a fallback fired: #{items.map { |p| p["trigger"] }.inspect}" if items.any? { |p| p["trigger"] == "fallback" }

      round, summary = item.values_at("task_key", "summary_task_key")
      return "the item names no round or no summary: #{item.inspect}" if round.nil? || summary.nil?

      summary_node = node(graph, summary)
      return "no node #{summary} on the graph" if summary_node.nil?
      return "#{summary} is #{summary_node["kind"]}, expected #{summary_kind(mode)}" unless
        summary_node["kind"] == summary_kind(mode)
      return "#{summary} did not complete: #{summary_node["status"]}" unless summary_node["status"] == "completed"
      if mode == "delegate" && task(tasks, summary)&.fetch("tool_name", nil) != "summarize_history"
        return "#{summary} is not rho's summarize_history: #{task(tasks, summary)&.fetch("tool_name", nil).inspect}"
      end
      return "no edge #{summary} → #{round}: the round does not wait on its summary" unless edge?(graph, summary, round)
      return "the repaired round #{round} did not complete: #{node(graph, round)&.fetch("status").inspect}" unless
        node(graph, round)&.fetch("status") == "completed"

      true
    end

    def summary_kind(mode) = mode == "delegate" ? "tool_task" : "model_task"

    # ── 7. until_gate ────────────────────────────────────────────────────
    # `--until` with a check that fails once: r1's reply, `check-1`, its
    # `hold-1`, the planted `work-2` after the hold, `check-2`, `hold-2`,
    # the `summary` round as the deliverable; nothing planted past a pass.
    # Each planted round NAMES its attempt's check and hold — nothing
    # crosses an append by position, so a round naming neither never read
    # the output it is asked to fix.
    def until_gate?(graph, _tasks, _events)
      %w[check-1 hold-1 work-2 check-2 hold-2 summary].each do |key|
        return "#{key} is missing from the ladder: #{Array(graph["nodes"]).map { |n| n["key"] }.inspect}" if node(graph, key).nil?
      end
      %w[check-1 check-2].each do |key|
        return "#{key} is not a completed tool_task: #{node(graph, key).slice("kind", "status")}" unless
          node(graph, key).values_at("kind", "status") == %w[tool_task completed]
      end
      %w[hold-1 hold-2].each do |key|
        return "#{key} is not a resolved await_task: #{node(graph, key).slice("kind", "status")}" unless
          node(graph, key).values_at("kind", "status") == %w[await_task completed]
      end
      return "work-2 is not a round" unless node(graph, "work-2")["kind"] == "model_task"
      return "work-2 does not wait on hold-1" unless edge?(graph, "hold-1", "work-2")
      { "work-2" => 1, "summary" => 2 }.each do |round, attempt|
        named = Array(node(graph, round)["result_from"])
        return "#{round} does not name check-#{attempt} and hold-#{attempt}: results #{named.inspect}" unless
          named == ["check-#{attempt}", "hold-#{attempt}"]
      end
      return "summary is not the completed deliverable round: #{node(graph, "summary").slice("kind", "status", "deliverable")}" unless
        node(graph, "summary").values_at("kind", "status", "deliverable") == ["model_task", "completed", true]
      return "work-3 was planted after a pass" unless node(graph, "work-3").nil?

      true
    end

    # ── 8. detached_receipt ──────────────────────────────────────────────
    # Turn 1's loop: a `task` call whose branch root hangs under the call
    # (rNtM → rNtM-model-1) and whose branch never reaches the call's
    # CONTINUATION — the round the call feeds (a round key, `continuations`).
    # `wait: true` splices the branch under that continuation as its head
    # (DelegateTaskTool::Run), so with a wait the continuation is reachable from the
    # root; detached has no head. The branch's OWN rounds carry `rN`/`rNtM`
    # keys too (the loop-global counter; the 2026-09-09 trace: r2t0-model-1
    # → r3t0 → r3), so "no edge into a round key" is NOT the test. The
    # receipt was accepted as kernel mail; a second loop (the woken turn)
    # reached `completed` on the same conversation's feed.
    def detached_receipt?(graph, tasks, events)
      calls = tool_rows(tasks, "delegate_task")
      return "no background task was started (no `task` call)" if calls.empty?

      rooted = calls.select { |call| node(graph, branch_root_of(call["key"])) }
      return "no task branch was opened under #{calls.map { |c| c["key"] }.inspect}" if rooted.empty?

      detached = rooted.find do |call|
        continuations(graph, call["key"]).none? { |key| reachable?(graph, branch_root_of(call["key"]), key) }
      end
      if detached.nil?
        return "every task branch reaches its call's continuation: the model waited (`wait: true`) on " \
               "#{rooted.map { |c| c["key"] }.inspect}"
      end

      mail = payloads(events, "input_accepted").find { |p| p["origin"] == "task_result" }
      return "no input_accepted{origin: task_result}: the kernel never mailed the receipt" if mail.nil?

      completed = payloads(events, "turn_status").select { |p| p["run_status"] == "completed" }
        .map { |p| p["run_public_id"] }.uniq
      return "only #{completed.size} loop completed on the feed: the receipt woke no turn" if completed.size < 2

      true
    end

    def branch_root_of(call) = "#{call}-model-1"

    # The rounds a call feeds: the model_task targets of its out-edges keyed as rounds — its own
    # root, minted under the call, is none of them. A key read, never the mainline mark: a call a
    # delegate made feeds the delegate's own round, marked `mainline: false`, and that round is its
    # continuation all the same.
    def continuations(graph, call)
      edges_out_of(graph, call).select { |key| round_key?(key) && node(graph, key)&.fetch("kind") == "model_task" }
    end

    # Whether `to` is downstream of `from` along the graph's edges.
    def reachable?(graph, from, to)
      seen = {}
      frontier = [from]
      until frontier.empty?
        key = frontier.shift
        next if seen[key]
        return true if key == to

        seen[key] = true
        frontier.concat(edges_out_of(graph, key))
      end
      false
    end

    # ── 9. repeat_brake ──────────────────────────────────────────────────
    # A round refused expansion for `repeat_call_loop` (the task row's
    # `error` is `{key: round_expansion_refused, detail: repeat_call_loop}`,
    # ApplyStepResult → FailNode; the graph node shows the key) after rounds
    # that brought nothing new: every mainline round before it, back to the
    # chain's first fan, fanned the identical bash call, and there are at
    # least two of them — the kernel's claim read off the rows, its window
    # never restated here. The loop rests `halt_failure`. Which round trips
    # is free.
    def repeat_brake?(graph, tasks, events)
      tripped = Array(tasks).find do |row|
        row["kind"] == "model_task" && row.dig("error", "key") == EXPANSION_REFUSED &&
          row.dig("error", "detail") == REPEAT_LOOP
      end
      return "no round was refused repeat_call_loop: the model varied its call (#{fan_summary(tasks)})" if tripped.nil?

      drawn = node(graph, tripped["key"])
      return "the refused round #{tripped["key"]} is not on the graph" if drawn.nil?
      return "the graph does not show the refusal on #{tripped["key"]}: error_key #{drawn["error_key"].inspect}" unless
        drawn["error_key"] == EXPANSION_REFUSED

      number = tripped["key"][/\Ar(\d+)\z/, 1]
      return "the refused round #{tripped["key"]} is not a mainline round" if number.nil?

      signatures = (1...Integer(number)).map { |back| fan_signature(tasks, "r#{Integer(number) - back}") }
        .take_while(&:any?)
      return "fewer than two fans precede #{tripped["key"]}" if signatures.length < 2
      return "the preceding fans are not identical: #{signatures.uniq.inspect}" unless signatures.uniq.one?
      return "the identical fan is not bash: #{signatures.first.inspect}" unless
        signatures.first.all? { |name, _input| name == "bash" }

      held = payloads(events, "attention_required").any? { |p| p["reason"] == "halt_failure" }
      return "the loop never held for a person on halt_failure" unless held

      true
    end

    # A round's fan as the brake reads it: (name, canonical arguments) pairs,
    # sorted — `tool_input` rides on the joined task rows.
    def fan_signature(tasks, round_key)
      Array(tasks).select { |row| row["kind"] == "tool_task" && Array(row["after"]).include?(round_key) }
        .map { |row| [row["tool_name"].to_s, canonical(row["tool_input"])] }.sort
    end

    def canonical(value)
      hash = Hash.try_convert(value) || {}
      JSON.generate(hash.sort.to_h)
    end

    def fan_summary(tasks)
      Array(tasks).select { |row| row["kind"] == "tool_task" }
        .map { |row| "#{row["tool_name"]}:#{canonical(row["tool_input"])}" }.tally
        .map { |call, n| "#{call}×#{n}" }.first(6).join(" ")
    end

    # The fixture the fan reviews: five files with exactly ONE uncalled
    # method each (`live_task_mail`'s fan project).
    def fan_files
      files = %w[a b c d e]
      files.to_h do |f|
        ["lib/#{f}.rb", "module #{f.upcase}\n  def self.used_#{f}(x) = x * 2\n  def self.orphan_#{f}(x) = x * 3\n" \
          "  def self.call(x) = used_#{f}(x)\nend\n"]
      end.merge("lib/run.rb" => "#{files.map { |f| "require_relative \"#{f}\"" }.join("\n")}\n\n" \
        "#{files.map { |f| "#{f.upcase}.call(1)" }.join("\n")}\n")
    end

    # The slow suite whose receipt outlives the reply (`live_task_mail`'s
    # `mail_project!`): one failing test, a 45-second `all.rb`.
    def mail_files
      {
        "lib/greet.rb" => "module Greet\n  def self.call(x) = x\nend\n",
        "lib/shout.rb" => "module Shout\n  def self.call(x) = x\nend\n",
        "lib/calc.rb" => "module Calc\n  def self.add(a, b) = a + b\n  def self.sub(a, b) = a + b\nend\n",
        "test/calc_test.rb" => "require \"minitest/autorun\"\nrequire_relative \"../lib/calc\"\n\n" \
          "class CalcTest < Minitest::Test\n  def test_adds = assert_equal(3, Calc.add(1, 2))\n" \
          "  def test_subtracts = assert_equal(1, Calc.sub(3, 2))\nend\n",
        "test/all.rb" => "sleep 45 # the suite is slow on purpose: the reply must go final before it\n" \
          "Dir[File.join(__dir__, \"*_test.rb\")].each { |file| require file }\n",
      }
    end

    # `live_until`'s stateful check: fails on its first run, passes from the second.
    UNTIL_CHECK = <<~SH
      #!/bin/sh
      # Fails on its first run, passes from the second: a ladder, not a coin.
      n=$(cat .check-count 2>/dev/null || echo 0)
      n=$((n + 1))
      echo "$n" > .check-count
      if [ ! -f note.txt ]; then echo "note.txt is missing"; exit 2; fi
      if [ "$n" -lt 2 ]; then echo "not yet: run $n"; exit 1; fi
      echo "ok on run $n"
    SH

    FAN_TASK = <<~TEXT.strip.freeze
      Use the `code` tool to delegate one fresh model task per file in lib/a.rb through lib/e.rb.
      Each finds the one unused method in its file. Use nexus.steps with a parallel group of
      model steps and one merge model step whose results name all five task keys. Await the
      operation and select only the merged result as the code call's output. Reply with the
      merged list, one line per file, and nothing else.
    TEXT

    ASK_TASK = <<~TEXT.strip.freeze
      Write a file called greeting.txt containing exactly one word: the
      codeword I have in mind. You do not know the codeword and you cannot
      work it out — you must ask me for it.

      Ask by calling the `ask` tool, and nothing else:

        ask({prompt: "What is the codeword?"})

      Your next round will receive my answer as an <answer> block. Then write
      greeting.txt with exactly that word and nothing else, and reply DONE.
    TEXT

    # TWO sleeps, TWO windows: a continuation is `queued` while its round's
    # tool runs, and the door refuses `nothing_to_compact` on a round with
    # no history behind it — the second sleep's window has a whole round.
    COMPACTION_TASK = <<~TEXT.strip.freeze
      Do exactly these steps, each as its OWN bash call, one per round:
        1. run: sleep 20
        2. run: sleep 20
        3. run: printf done > done.txt
      Then reply DONE. Do not combine the commands and do not skip a sleep.
    TEXT

    UNTIL_TASK = "Create a file named note.txt in this directory containing the single word hello. " \
                 "Do not run check.sh yourself; just create the file and end your turn.".freeze

    # NAMES ITS TOOL, as every other shape does (Gate 3 F4): "a background
    # task" alone reads as `start_process` — a correct reading of the
    # owner's 2026-09-02 definition — and both models took it. The bench's
    # twin (live_task_mail MAIL_TURN_1) keeps the neutral wording as its
    # measurement; this is the shape's text.
    MAIL_TASK = "Hand the suite `ruby test/all.rb` to the `task` tool as a detached sub-task (not `start_process`; " \
                "do not wait for it). While it runs, count the files in lib/ and reply with just that number. " \
                "Do not wait for the suite before you reply.".freeze

    BRAKE_TASK = <<~TEXT.strip.freeze
      The file status.txt will eventually contain the word READY. Run exactly
      `cat status.txt` with the bash tool and nothing else, again and again,
      one call per round, until it prints READY. Do not add sleep, do not
      change the command in any way, do not run anything else, do not give
      up, and do not reply until it prints READY.
    TEXT

    SHAPES = [
      Shape.new(
        id: :linear, task: E2E::CODING_TASK, driver: :plain, compaction: :kernel, files: {},
        expected: "A chain: rN → rNtM → rN+1, every tool fanned by one round and read by the next; " \
                  "no join, no await; fan width and round count free.",
        predicate: ->(graph, tasks, events) { Gallery.linear?(graph, tasks, events) }
      ),
      Shape.new(
        id: :fan_join, task: FAN_TASK, driver: :plain, compaction: :kernel, files: fan_files,
        expected: "One tool call whose branch fans at least two model tasks into one " \
                  "merge model step that reads them all — until: \"all\" places no join row, a race would; " \
                  "the merge completed.",
        predicate: ->(graph, tasks, events) { Gallery.fan_join?(graph, tasks, events) }
      ),
      Shape.new(
        id: :ask_human, task: ASK_TASK, driver: :answer_ask, compaction: :kernel, files: {},
        expected: "An await_task rNtM-ask-1 under the model's `ask`, answered (completed), feeding a " \
                  "completed round; the feed carried attention_required. Which round asks is free.",
        predicate: ->(graph, tasks, events) { Gallery.ask_human?(graph, tasks, events) }
      ),
      Shape.new(
        id: :halt_retry, task: nil, driver: :halting_loop, compaction: :kernel, files: {},
        expected: "The authored halt: gate-1 and gate-2 (await_task) both into work (model_task, the " \
                  "deliverable); gate-1 timed out and abandoned (error_key kept), gate-2 retried and " \
                  "answered (completed), work completed.",
        predicate: ->(graph, tasks, events) { Gallery.halt_retry?(graph, tasks, events) }
      ),
      Shape.new(
        id: :compaction_kernel, task: COMPACTION_TASK, driver: :compact_queued_round, compaction: :kernel, files: {},
        expected: "A k1 model_task (the kernel's summarizer) hung under a queued round rN (edge k1 → rN), " \
                  "one context_compacted{mode: kernel, trigger: manual, task_key: rN, summary_task_key: k1}, " \
                  "rN completed from the summary.",
        predicate: ->(graph, tasks, events) { Gallery.compaction?(graph, tasks, events, mode: "kernel") }
      ),
      Shape.new(
        id: :compaction_delegate, task: COMPACTION_TASK, driver: :compact_queued_round, compaction: :delegate, files: {},
        expected: "A k1 tool_task summarize_history (rho's own summarizer) hung under a queued round rN " \
                  "(edge k1 → rN), one context_compacted{mode: delegate, trigger: manual, task_key: rN, " \
                  "summary_task_key: k1}, no fallback, rN completed from the summary.",
        predicate: ->(graph, tasks, events) { Gallery.compaction?(graph, tasks, events, mode: "delegate") }
      ),
      Shape.new(
        id: :until_gate, task: UNTIL_TASK, driver: :until, compaction: :kernel, files: { "check.sh" => UNTIL_CHECK },
        expected: "The --until ladder: check-1 (tool_task) → hold-1 (await_task) → work-2 (model_task) → … " \
                  "check-2 → hold-2 → summary (model_task, the deliverable); both checks completed, " \
                  "both holds resolved, no work-3.",
        predicate: ->(graph, tasks, events) { Gallery.until_gate?(graph, tasks, events) }
      ),
      Shape.new(
        id: :detached_receipt, task: MAIL_TASK, driver: :say_second_turn, compaction: :kernel, files: mail_files,
        expected: "Loop 1: a `task` call rNtM with its branch root rNtM-model-1 under it, and the call's " \
                  "continuation round NOT reachable from that root (detached: `wait: true` would splice the " \
                  "branch under the continuation; the branch's own rounds carry rN keys too); " \
                  "input_accepted{origin: task_result} on the feed; a second loop — the woken turn — completed " \
                  "on the same conversation.",
        predicate: ->(graph, tasks, events) { Gallery.detached_receipt?(graph, tasks, events) }
      ),
      Shape.new(
        id: :repeat_brake, task: BRAKE_TASK, driver: :brake, compaction: :kernel, files: { "status.txt" => "NOT READY\n" },
        expected: "A mainline round refused expansion for repeat_call_loop (error round_expansion_refused / " \
                  "repeat_call_loop), a round refused after rounds that brought nothing new (the identical " \
                  "`bash cat status.txt` with the unchanged NOT READY); the loop held halt_failure for a " \
                  "person. Which round trips is free; a model that varies its call is red with that finding.",
        predicate: ->(graph, tasks, events) { Gallery.repeat_brake?(graph, tasks, events) }
      ),
    ].freeze
  end
end
