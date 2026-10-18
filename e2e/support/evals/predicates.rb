require "active_support/all"
require_relative "../gallery/shapes"
require_relative "../task_bench/declared_set"
require_relative "../task_bench/look"
require_relative "../task_bench/objectives"
require_relative "bench"
require_relative "queue_pass"
require_relative "task_reads"
require_relative "trace"

module E2E
  module Evals
    # Shared predicates over the public task graph, tool calls and execution events.
    module Predicates
      module_function

      # ── the plainest reach ───────────────────────────────────────────────
      def any_call(trace)
        trace.calls.empty? ? "no tool call: the model answered in text (#{trace.rounds.size} rounds)" : true
      end

      def loop_completed(trace)
        trace.status == "completed" ? true : "the loop rests #{trace.status.inspect}: #{trace.attention_reasons.inspect}"
      end

      def bash_commands(trace) = trace.tool_rows("bash").map { |row| trace.input_of(row)["command"].to_s }

      def declared_names(trace)
        names = SealedRequest.tool_names(trace.sealed)
        names.empty? ? E2E::TaskBench::DeclaredSet.names(style: style_words(trace)) : names
      end

      def style_words(trace)
        words = Array(Hash(trace.fact(:adaptations))["tool_style"])
        words.empty? ? (trace.fact(:style) || "nexus") : words.join("+")
      end

      def losers_completed(trace)
        races = Array(trace.graph["nodes"]).select { |node| node["kind"] == "join_task" && node.dig("join", "until") != "all" }
        return nil if races.empty?

        races.sum do |join|
          ends = join.dig("join", "until")
          needed = ends == "any" ? 1 : Integer(ends)
          completed = trace.edges_into(join["key"]).count { |source| trace.node(source)&.fetch("status", nil) == "completed" }
          [completed - needed, 0].max
        end
      end

      def branch_completed(trace, call)
        row = trace.task(call)
        return "the task call #{call} #{row["status"]}: #{row.dig("error", "key").inspect}" if row && row["status"] != "completed"

        under = trace.under(call)
        return "no task was placed under #{call}: the call placed no node" if under.empty?

        amiss = under.reject { |node| %w[completed canceled].include?(node["status"]) }
        return "#{amiss.map { |n| "#{n["key"]}(#{n["status"]})" }.join(", ")} did not complete under #{call}" unless amiss.empty?

        true
      end

      def delegated_nothing(trace)
        verbs = trace.task_rows
        verbs.empty? ? true : "over-reach: #{verbs.map { |r| "#{r["key"]}:#{r["tool_name"]}" }.join(", ")} on one read's worth of work"
      end

      # ── the task family (the offline probe's rules through rho) ──────────
      def background?(row) = row["tool_name"] == Trace::TASK && Hash(row["tool_input"])["wait"] != true

      def first_round_task_rows(trace) = trace.first_round_rows.select { |row| row["tool_name"] == Trace::TASK }

      def task_prompts(trace) = trace.task_rows.map { |row| trace.input_of(row)["prompt"].to_s }

      def per_file(trace, files)
        texts = task_prompts(trace)
        files.to_h { |file| [file, texts.count { |text| text.include?(file) }] }
      end

      def graph_verbs_inside_branches(trace) = (trace.task_rows - trace.mainline_calls).size

      def door(trace)
        return "task_fan" if trace.rounds.any? { |round| trace.fanned_by(round["key"]).count { |r| r["tool_name"] == Trace::TASK } >= 2 }

        nil
      end

      def reached_a_door(trace)
        door(trace) ? true : "no round fanned two task calls: #{trace.called.inspect}"
      end

      # ── the door, read as the door register reads it (beside `door`) ─────
      # A door is read on the mainline's first three rounds: a look, a second look, the door.
      DOOR_ROUNDS = 3
      # The graph verbs that hand work out: the round making the first is the dispatch round.
      DISPATCH_TOOLS = [Trace::TASK].freeze
      # A call that reads before a dispatch — a shell command counted whatever it runs.
      READ_CLASS_TOOLS = Trace::READ_CLASS
      # How much of a dispatch call's brief rides the record.
      BRIEF_HEAD = 80

      # THE DOOR THE RUN WENT THROUGH, a kind as the door register kinds one: the first of the
      # mainline's first three rounds that is not a look (`TaskBench::Look`) is the door, its calls kinded
      # by the task bench's `Door`; three looks, or fewer rounds all looks, are `scout`; a mainline with no
      # round is `none`. `declared` names the entries a door round declared outright; else the round's
      # own (`door_declared`).
      def door_kind(trace, declared: nil) = door_reading(trace, declared: declared).fetch("door_kind")

      # The door's facts beside its kind (`Door#fields`): the round among the first three it was
      # read at (nil on a scout), whether its script built, its members, what came back unread, and
      # the calls beside it.
      def door_read(trace, declared: nil) = door_reading(trace, declared: declared).except("door_kind")

      def door_reading(trace, declared: nil)
        keys = Trace.mainline_keys(trace.graph).first(DOOR_ROUNDS)
        rounds = keys.map { |key| round_calls(trace, key) }
        index = rounds.index { |round| !TaskBench::Look.look?(round) }
        door = if index
          round_door(trace, keys[index], declared: declared)
        else
          TaskBench::Door.new(kind: rounds.empty? ? "none" : TaskBench::Door::SCOUT, members: 0, beside: [])
        end
        { "door_kind" => door.kind, "round" => index&.succ }.merge(door.fields.except("door_kind"))
      end

      # One round's door, kinded under the entries it declared (`door_declared`) or `declared`.
      def round_door(trace, key, declared: nil)
        TaskBench::Objectives.door(TaskBench::Look.calls(round_calls(trace, key)), declared: declared || door_declared(trace, key))
      end

      # A round's calls as a recorded round holds them: `{name, input}` in the order it made them.
      def round_calls(trace, key) = trace.fanned_by(key).map { |row| { "name" => row["tool_name"], "input" => trace.input_of(row) } }

      # THE ENTRIES THE DOOR ROUND DECLARED: the sealed request's (`request_options.tools`, the set the
      # model saw) when the sealed round is that round; else the set the run's style words imply, as
      # `declared_names` falls back.
      def door_declared(trace, key)
        sealed = trace.sealed if trace.sealed && trace.sealed["task_key"] == key
        tools = Array(sealed&.dig("request_options", "tools"))
        tools.empty? ? TaskBench::DeclaredSet.function_definitions(style: style_words(trace)) : tools
      end

      def dispatch_round(trace)
        index = Trace.mainline_keys(trace.graph).index { |key| trace.fanned_by(key).any? { |row| DISPATCH_TOOLS.include?(row["tool_name"]) } }
        index&.succ
      end

      # A SCOUT, THEN THE DOOR: the dispatch round is the second or later, and an earlier mainline round
      # made a read-class call.
      def scout_then_door(trace)
        at = dispatch_round(trace)
        earlier = at.nil? ? [] : Trace.mainline_keys(trace.graph).first(at - 1)
        earlier.any? { |key| trace.fanned_by(key).any? { |row| READ_CLASS_TOOLS.include?(row["tool_name"]) } }
      end

      # THE DISPATCH ROUND'S DOOR: the round that handed work out, kinded as `door_kind` kinds a round —
      # its place (`round`) and `Door#fields` — where a scout the look rule reads as a door (an `echo`
      # beside a listing, a todo beside one, three look rounds) still dispatched later; nil when
      # nothing was dispatched.
      def dispatch_door(trace)
        at = dispatch_round(trace)
        at.nil? ? nil : { "round" => at }.merge(round_door(trace, Trace.mainline_keys(trace.graph).fetch(at - 1)).fields)
      end

      # The lib/ sources the dispatch round's delegations name in their briefs.
      def dispatch_names(trace)
        at = dispatch_round(trace)
        at.nil? ? [] : delegations(trace, Trace.mainline_keys(trace.graph).fetch(at - 1)).flat_map { |row| brief_names(trace, row) }.uniq
      end

      def door_calls(trace)
        at = dispatch_round(trace)
        rows = at.nil? ? [] : trace.fanned_by(Trace.mainline_keys(trace.graph).fetch(at - 1))
        rows.map do |row|
          input = trace.input_of(row)
          brief = input["prompt"] || input["command"]
          { "tool" => row["tool_name"], "wait" => input["wait"], "prompt_head" => (brief.to_s[0, BRIEF_HEAD] unless brief.nil?) }
        end
      end

      # ── the scout's names (D6: list, then fan over what was listed) ──────
      # A source under lib/ as a brief names it.
      LIB_SOURCE = %r{\blib/[\w-]+\.rb\b}
      # A Ruby file's own name as a listing prints it: bare (`ls lib`, rho's `grep` over lib/, which
      # print names relative to the path they read) or under a directory (`find`, `grep -l`).
      LISTED_NAME = /[\w-]+\.rb\b/

      def guessed_names(trace) = guesses(trace).flat_map(&:last).uniq

      # THE GUESSES A DELEGATE MAY HAVE LISTED, for a hand read: the guessed names of a round some
      # earlier mainline round made a `task` call before — its result (a receipt, a waited call's output)
      # is text the trace does not join, so a fan over what a discovering delegate returned reads as
      # guessed.
      def guessed_after_a_delegate(trace)
        keys = Trace.mainline_keys(trace.graph)
        guesses(trace).select { |index, _names| keys.first(index).any? { |key| trace.fanned_by(key).any? { |row| row["tool_name"] == Trace::TASK } } }
          .flat_map(&:last).uniq
      end

      # Each mainline round's guessed names, `[its index, names]`, in round order.
      def guesses(trace)
        keys = Trace.mainline_keys(trace.graph)
        keys.each_with_index.map do |key, index|
          listed = listed_names(trace, keys.first(index))
          [index, delegations(trace, key).flat_map { |row| brief_names(trace, row) }.reject { |name| listed.include?(File.basename(name)) }]
        end
      end

      # D6's wrong door (`door-choice-design.md:281`): a delegation over names not in the listing.
      def fan_over_guessed_names(trace) = guessed_names(trace).any?

      # Every lib/ source the mainline's delegations named, in the order first named.
      def briefed_names(trace) = Trace.mainline_keys(trace.graph).flat_map { |key| delegations(trace, key) }.flat_map { |row| brief_names(trace, row) }.uniq

      # The file names the read-class calls of these mainline rounds returned.
      def listed_names(trace, keys)
        keys.flat_map { |key| trace.fanned_by(key) }.select { |row| READ_CLASS_TOOLS.include?(row["tool_name"]) }
          .flat_map { |row| trace.output_of(row).scan(LISTED_NAME) }.uniq
      end

      def delegations(trace, key) = trace.fanned_by(key).select { |row| DISPATCH_TOOLS.include?(row["tool_name"]) }

      def brief_names(trace, row)
        input = trace.input_of(row)
        input["prompt"].to_s.scan(LIB_SOURCE)
      end

      # ── the job's door (D4: one background `task` for a long command) ────
      # The rows the mainline made in the rounds up to and including the dispatch round; none when
      # nothing was dispatched.
      def through_dispatch(trace)
        at = dispatch_round(trace)
        at.nil? ? [] : Trace.mainline_keys(trace.graph).first(at).flat_map { |key| trace.fanned_by(key) }
      end

      def d4_right(trace, suite)
        rows = through_dispatch(trace)
        tasks = rows.select { |row| row["tool_name"] == Trace::TASK }
        tasks.one? && background?(tasks.first) && suite.match?(trace.input_of(tasks.first)["prompt"].to_s) &&
          rows.none? { |row| row["tool_name"] == TaskBench::Door::START_PROCESS }
      end

      # Detached tasks owe a result receipt; waited tasks return their results inline.
      def receipt_loop(trace)
        return no_receipt(trace) if trace.receipts.zero?

        every_loop_completed(trace)
      end

      def no_receipt(trace)
        rows = trace.task_rows
        detached = rows.count { |row| background?(row) }
        if detached.zero?
          "no input_accepted{origin: task_result}: every task call waited (wait: true on #{rows.size} of #{rows.size}), " \
            "so no receipt was owed and the receipt-wake loop never ran (#{trace.called.inspect})"
        else
          "no input_accepted{origin: task_result}: the kernel mailed no receipt for #{detached} detached task call(s) " \
            "(#{trace.called.inspect})"
        end
      end

      # A fan-and-merge succeeds when every raised task and every loop completes. A waited task
      # returns inline while a detached task returns as mail; receipt count and wait style are
      # recorded independently from success. Iterative objectives keep their separate receipt-wake
      # predicate.
      def fan_completed(trace)
        return "no round fanned two task calls: #{trace.called.inspect}" unless door(trace) == "task_fan"

        amiss = trace.task_rows.reject { |row| row["status"] == "completed" }
        return "#{amiss.map { |r| "#{r["key"]}(#{r["status"]})" }.join(", ")} did not complete: the fan never came back whole" unless amiss.empty?

        every_loop_completed(trace)
      end

      def every_loop_completed(trace)
        statuses = trace.payloads("turn_status").group_by { |p| p["run_public_id"] }
          .transform_values { |items| items.map { |p| p["run_status"] } }
        stuck = statuses.reject { |_id, seen| seen.include?("completed") }.keys
        stuck += trace.loops.reject { |row| row["status"] == "completed" }.map { |row| row["id"] }
        stuck.uniq.empty? ? true : "loop #{stuck.uniq.join(", ")} never completed on the feed"
      end

      # What each bash command did to the queue directory (`QueuePass`, from the call's `workdir`),
      # in call order, beside the command.
      def queue_readings(trace, queue)
        trace.tool_rows("bash").map do |row|
          input = trace.input_of(row)
          [input["command"].to_s, QueuePass.read(input["command"].to_s, dir: queue, workdir: input["workdir"])]
        end
      end

      def queue_passes(trace, queue) = queue_readings(trace, queue).map(&:last)

      # ONE ITEM PER PASS, read off what each bash command did rather than the words it spells: none
      # loops over the queue with a shell construct, none takes more than one item out of it, and
      # none reads the contents of more than one — a head-pick that moves one item is one pass, a
      # listing is none, and a look at every item handles every item though it takes none out.
      def one_item_per_pass(trace, queue)
        queue_readings(trace, queue).each do |command, pass|
          return "a shell loop over the queue: #{command[0, 120].inspect}" if pass.looped
          return "one bash call handles #{pass.count_word} items: #{command[0, 120].inspect}" if pass.several?
          return "one bash call handles #{pass.read_word} items: #{command[0, 120].inspect}" if pass.read_several?
        end
        true
      end

      # Record how the workflow iterated independently from whether it succeeded.
      def loop_style(trace)
        { "door" => door(trace), "rounds" => trace.mainline_rounds.size, "receipts" => trace.receipts,
          "task_calls" => trace.task_rows.size, "bash_calls" => trace.tool_rows("bash").size }
      end

      # ── the compaction family (decision 12) ──────────────────────────────
      # KEYS ARE MARKS, NEVER NUMBERS: the mainline carries rounds the until
      # extension authored (`work-2`) beside the kernel's `rN`, and a
      # reader that took the number out of a key raised on the wall-kernel
      # record (evals run 2). The columns count by the loop row's ORDER
      # from the round the first compaction repaired (its payload's
      # `task_key`).
      def mainline_keys(trace) = trace.mainline_rounds.map { |row| row["key"] }

      # The mainline round the first compaction repaired, by key — the
      # earliest in mainline order; nil when nothing was compacted.
      def compacted_round(trace)
        repaired = trace.compactions.map { |p| p["task_key"] }
        mainline_keys(trace).find { |key| repaired.include?(key) }
      end

      def read_paths(rows, trace) = rows.select { |row| row["tool_name"] == "read" }.map { |row| trace.input_of(row)["path"].to_s }

      # Reads of a path already read before the compaction's round, over
      # the reads after it; a call is before when the round it hangs off
      # precedes the repaired round in the loop row's order (a branch's
      # round in its own place). nil when nothing was compacted or nothing
      # read after.
      def reread_rate(trace)
        at = compacted_round(trace) or return nil
        keys = trace.rounds.map { |row| row["key"] }
        # A repaired round the loop row no longer carries — a stopped loop
        # whose tail was canceled (12a L9) — has nothing after it to rate.
        return nil unless keys.include?(at)

        earlier = keys.take_while { |key| key != at }
        before, after = trace.calls.partition { |row| Array(row["after"]).intersect?(earlier) }
        seen = read_paths(before, trace).uniq
        later = read_paths(after, trace)
        later.empty? ? nil : (later.count { |path| seen.include?(path) }.to_f / later.size).round(3)
      end

      # Mainline rounds from the compacted round on, beyond the task's stated
      # minimum after a compaction; nil when nothing was compacted.
      def induced_rounds(trace, minimum_after:)
        at = compacted_round(trace) or return nil
        keys = mainline_keys(trace)
        index = keys.index(at) or return nil
        [keys.size - index - minimum_after, 0].max
      end

      # A harness deadline or cost stop is classified at the loop level. Ignore its
      # `creator_requested` and `run_canceled` node failures when judging whether model rounds
      # completed; other failure keys remain visible.
      HARNESS_STOP = %w[creator_requested run_canceled].freeze

      def rounds_not_completed(trace)
        trace.rounds.reject { |row| row["status"] == "completed" || HARNESS_STOP.include?(row.dig("error", "key")) }
      end

      def every_round_completed(trace)
        amiss = rounds_not_completed(trace)
        amiss.empty? ? true : "a round did not complete: #{amiss.map { |r| "#{r["key"]}(#{r["status"]}#{r.dig("error", "key") ? " !#{r.dig("error", "key")}" : ""})" }.join(", ")}"
      end

      def summaries(trace) = Hash(trace.fact(:summaries))

      def summary_bytes(trace) = summaries(trace).values.sum { |body| body.to_s.bytesize }

      # A summary carries pointers, never values: none of the fixture's
      # body-only tokens may appear in any summary body.
      def pointers_never_values(trace, tokens)
        summaries(trace).each do |key, body|
          leaked = tokens.find { |token| body.to_s.include?(token) }
          return "the summary #{key} reproduced a value from a file body: #{leaked}" if leaked
        end
        true
      end

      def compaction_columns(trace, minimum_after:)
        { "compactions" => trace.compaction_tally, "reread_rate" => reread_rate(trace),
          "induced_rounds" => induced_rounds(trace, minimum_after: minimum_after), "summary_bytes" => summary_bytes(trace),
          "summary_keys" => summaries(trace).keys }
      end
    end
  end
end
