require "active_support/all"
require "mini_racer"
require_relative "../gallery/shapes"
require_relative "../compose_bench/objectives"
require_relative "../compose_bench/endpoints"
require_relative "../compose_bench/executed"
require_relative "../compose_bench/inline"
require_relative "../compose_bench/scoring"
require_relative "../task_bench/declared_set"
require_relative "../task_bench/look"
require_relative "../task_bench/objectives"
require_relative "bench"
require_relative "queue_pass"
require_relative "composed_reads"
require_relative "concurrent_fan"
require_relative "trace"
require_relative "usable"

module E2E
  module Evals
    # THE READS THE FAMILIES SHARE, over a `Trace` (a predicate names structure — kinds, edges, tool
    # names, `tool_input` keys, event payloads — and answers `true` or a String in the trace's own
    # words). Each task's `expected.rb` composes these; none copies them. The compose family scores
    # the plan the kernel placed under the call where the trace holds one (`ComposeBench::Executed`),
    # and the script's text through the text bench's scorer (`ComposeBench::Scoring`) beside it and
    # where it holds none — the strong tier's bar; the floor's is usable generation (`Usable`), the
    # lane's tier fact picking between them; the task family's background rule is the offline
    # probe's (`wait != true`), the workflow family's receipt loop the gallery's `detached_receipt?`
    # reads, the compaction family's columns the arm's own vocabulary.
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

      # ── the compose family (decision 3) ──────────────────────────────────
      def compose_call(trace) = trace.compose_rows.first

      def compose_reached(trace)
        compose_call(trace) ? true : "no compose call: the model called #{trace.called.inspect}"
      end

      # The names the round DECLARED, read off the sealed request (`request_options.tools`, the
      # exact set the model saw) — of the round that MADE the compose call when there is one (a
      # member's continuation carries the member's narrowed set and must never score the script); a
      # trace with no sealed request of that round — a drawing, a salvage before any round completed
      # — falls back to the set the run's row implies (`DeclaredSet.names` over the lane-stamped
      # `adaptations` fact's `tool_style` words — never the style word alone: `pack` names no words
      # — else, on a record from before the fact existed, the style word).
      def declared_names(trace)
        calling = compose_call(trace)&.dig("after", 0)
        sealed = trace.sealed if trace.sealed && (calling.nil? || trace.sealed["task_key"] == calling)
        names = SealedRequest.tool_names(sealed)
        names.empty? ? E2E::TaskBench::DeclaredSet.names(style: style_words(trace)) : names
      end

      def style_words(trace)
        words = Array(Hash(trace.fact(:adaptations))["tool_style"])
        words.empty? ? (trace.fact(:style) || "nexus") : words.join("+")
      end

      # The script the model wrote, read off the compose row's `tool_input`, scored on the plan the
      # kernel placed for it where the trace holds one and on its text beside it
      # (`ComposeBench::Executed.reading`) — a Hash, or a String when there is no script to score.
      # The plan's tools are named off the task rows, which the graph route's nodes do not carry.
      def score_compose(trace, objective_id)
        call = compose_call(trace) or return "no compose call to score"
        input = trace.input_of(call)
        return "the compose row #{call["key"]} carries no script" if input["script"].to_s.strip.empty?

        objective = E2E::ComposeBench::Objectives.find(objective_id)
        static = E2E::ComposeBench::Scoring.score(objective, script: input["script"], params: input["params"],
          tool_names: declared_names(trace))
        tools = trace.calls.to_h { |row| [row["key"], row["tool_name"]] }
        E2E::ComposeBench::Executed.reading(objective, static, E2E::ComposeBench::Executed.plan(trace.graph, call["key"], tools: tools))
      end

      # THE BAR A COMPOSE PICTURE TASK READS, by the tier the lane stamped (`Bench#tier_fact`): usable
      # generation on the floor, the picture on the strong tier. A trace with no tier fact — every
      # record before the lane stamped one — reads the picture, the bar it was scored on. Both readings
      # run on every tier, so each one's guard against the harness's own fault (the executed reading's
      # lowering oracle, usable's placed plan for a script the harness refuses) raises into the lane as
      # a lane bug whichever bar the tier picks, never as a missed picture or as model conduct.
      def compose_bar(trace, objective_id)
        picture = compose_picture(trace, objective_id)
        usable = compose_usable(trace)
        trace.fact(:tier) == Bench::FLOOR ? usable : picture
      end

      # THE BAR A RECORDED-ONLY COMPOSE TASK READS (its picture a fact, never the bar), by the tier as
      # `compose_bar` picks: the script the kernel accepted on the strong tier (`compose_accepted`),
      # usable generation whose call's branch completed on the floor (`compose_floor`). Both run on
      # every tier, as `compose_bar`'s two do, so either reading's guard against the harness's own
      # fault raises into the lane whichever the tier picks.
      def recorded_bar(trace, objective_id)
        accepted = compose_accepted(trace, objective_id)
        floor = compose_floor(trace)
        trace.fact(:tier) == Bench::FLOOR ? floor : accepted
      end

      # THE PICTURE, the strong tier's bar and the `picture` fact on either tier: valid first, exact
      # edges AND reads, and the branch the kernel ran under the call completed (a race cancels its
      # losers). A picture that missed over a plan that did no work — a stage whose own source does
      # not parse, a call that placed nothing — names that in usable generation's words, not the
      # buckets of an empty graph; read only once the picture missed, so no exact picture moves.
      def compose_picture(trace, objective_id)
        score = score_compose(trace, objective_id)
        return score if score in String
        return refused(score) unless score["valid_first"]
        return missed_picture(trace, score) unless score["first_time_right"]

        branch_completed(trace, compose_call(trace)["key"])
      end

      def refused(score) = "the script was refused #{score["refusal"]}: #{score["detail"].to_s[0, 160]}"

      # Usable's guard against the harness's own fault — a placed plan whose script the harness
      # refuses — cannot fire here: the script built.
      def missed_picture(trace, score)
        standing = Usable.call(trace, compose_call(trace), tool_names: declared_names(trace))
        if standing in String
          standing
        else
          "the picture is not the objective's (silent: #{Array(score["silent"]).join(", ")}): #{score["graph"].inspect[0, 300]}"
        end
      end

      # THE ACCEPTED SCRIPT: the first call's script built and the branch the kernel ran under it
      # completed, whatever its picture.
      def compose_accepted(trace, objective_id)
        score = score_compose(trace, objective_id)
        return score if score in String
        return refused(score) unless score["valid_first"]

        branch_completed(trace, compose_call(trace)["key"])
      end

      # THE FLOOR'S BAR reads the RUN: green when some compose call of the run met it, since a model
      # that repairs a refused script within the run generated a usable one; else the first call's
      # red, the attempt the run began with. `usable_on_call` records which call first met it, so the
      # first-call rate stays on the record.
      def compose_usable(trace)
        call = compose_call(trace) or return "no compose call to read"
        usable_on_call(trace) ? true : Usable.call(trace, call, tool_names: declared_names(trace))
      end

      # The 1-based place of the first compose call that met the floor's bar; nil when none did.
      def usable_on_call(trace)
        names = declared_names(trace)
        trace.compose_rows.index { |row| Usable.call(trace, row, tool_names: names) == true }&.succ
      end

      # USABLE, AND THE WORK RAN: usable generation by a call of the run, and the branch of the call
      # that met it completed — usable alone reads a model or tool member that failed at run time as
      # a node that stands, which a recorded-only task's bar never forgave. Usable's red when no call
      # met it, else the branch's.
      def compose_floor(trace)
        usable = compose_usable(trace)
        return usable unless usable == true

        branch_completed(trace, trace.compose_rows[usable_on_call(trace) - 1]["key"])
      end

      # ── what a race's delivered results carry (the envelope's `<call>` line) ──
      # A brief's hedge for a winner it may not be able to name.
      HEDGE = /\bunknown\b|does not (?:identify|name)|cannot (?:tell|identify)/i

      # THE LABELS THE RUN AUTHORED to tell its results apart (`ComposeBench::Endpoints`, the text
      # bench's reader): true when some compose call's expanded plan carries them, false when none
      # does, nil when no call's script built — nothing to read. A fact, never a bar.
      def authored_labels(trace) = over_plans(trace) { |steps| ComposeBench::Endpoints.authored_labels?(steps) }

      # A RACE WHOSE MEMBERS FAIL THEMSELVES on their probe's outcome, the reader beside the labels.
      def success_filter(trace) = over_plans(trace) { |steps| ComposeBench::Endpoints.success_filter?(steps) }

      # Whether a model step the run composed was briefed to say it cannot name the winner — the
      # hedge a brief writes when nothing it will read names the host.
      def hedged_brief(trace)
        over_plans(trace) do |steps|
          ComposeBench::Endpoints.plan_leaves(steps).any? { |verb, body| verb == "model" && body["prompt"].to_s.match?(HEDGE) }
        end
      end

      # Every compose call's plan as the evaluator builds it with its result-free stages inlined,
      # read by `reader`: any call's true is the run's; nil when no call's script built.
      def over_plans(trace, &reader)
        names = declared_names(trace)
        plans = trace.compose_rows.filter_map do |row|
          input = trace.input_of(row)
          built = Nexus::Compose::Evaluator.call(script: input["script"].to_s, params: Hash(input["params"]), tool_names: names)
          ComposeBench::Shape.inline(built.steps, tool_names: names).steps if built.built?
        end
        plans.empty? ? nil : plans.any?(&reader)
      end

      # THE ARMS A RACE LET RUN ON, read per arm off the plan that ran: for every race join a
      # compose call placed, the arms that COMPLETED beyond what its `until` needed — each a loser
      # something kept alive past the race (a reader naming a member spares it as shared work),
      # since a race that stops its losers settles each `canceled`. 0 when every race stopped its
      # losers; nil when no call placed a race.
      def losers_completed(trace)
        races = trace.compose_rows.flat_map { |row| trace.under(row["key"]) }.select { |node| node["kind"] == "join_task" }
        return nil if races.empty?

        races.sum do |join|
          ends = join.dig("join", "until")
          needed = ends == "any" ? 1 : Integer(ends)
          completed = trace.edges_into(join["key"]).count { |source| trace.node(source)&.fetch("status", nil) == "completed" }
          [completed - needed, 0].max
        end
      end

      # ── what the composed steps read and what came back (the explicit-read columns) ──
      # THE READS A RUN'S COMPOSE CALLS WROTE, one fact on every compose picture task: per model step
      # a compose call placed, whether its `results:` named anything (`reads_source`: named | none;
      # a step naming nothing reads its prompt alone) and the share that did; the executed reading's
      # credit to a model its stage fed (`stage_fed`); what came back to the caller — per call, the
      # steps it placed that a spine round read or a receipt named (`unread_delivered`); the compose
      # calls a round made after reading an earlier call's results (`recomposed_after_receipt`); and
      # the over-read split — `over_read_positional`, the composed steps the kernel handed anything
      # by position (a kernel finding, never conduct), and `over_read_named`, the picture's
      # `results:` naming more than it reads (nil where no picture was scored). nil when no compose
      # call was made.
      def reads(trace, objective_id)
        return nil if trace.compose_rows.empty?

        steps = ComposedReads::Reading.of(trace.graph, trace.tasks).steps
        named = steps.count { |node| Array(node["result_from"]).any? }
        score = score_compose(trace, objective_id)
        scored = score if score in Hash
        { "reads_source" => steps.to_h { |node| [node["key"], Array(node["result_from"]).any? ? "named" : "none"] },
          "results_named_share" => (steps.empty? ? nil : (named.to_f / steps.size).round(3)),
          "stage_fed" => scored&.fetch("stage_fed", nil),
          "unread_delivered" => unread_delivered(trace), "recomposed_after_receipt" => recomposed_after_receipt(trace),
          "over_read_positional" => steps.count { |node| Array(node["input_from"]).any? },
          "over_read_named" => (Array(scored["silent"]).include?("over_read_named") if scored&.fetch("valid_first")) }
      end

      # What each compose call handed back, by call: the steps it placed that a spine round read — the
      # waited continuation, or the round a receipt woke — or that a `task_result` receipt named, a
      # member's own round counted as the member.
      def unread_delivered(trace)
        read = spine_reads(trace) + trace.payloads("input_accepted").filter_map { |p| p["task_key"] if p["origin"] == "task_result" }
        trace.compose_rows.to_h do |call|
          placed = trace.under(call["key"]).map { |node| node["key"] }
          [call["key"], read.filter_map { |key| placement(trace, key, placed) }.uniq.size]
        end
      end

      # The compose calls after the first made by a round that read what an earlier call placed.
      def recomposed_after_receipt(trace)
        rows = trace.compose_rows
        rows.each_with_index.count do |call, index|
          round = trace.node(Array(call["after"]).first)
          earlier = rows.first(index).flat_map { |row| trace.under(row["key"]).map { |node| node["key"] } }
          read = round ? Array(round["input_from"]) + Array(round["result_from"]) : []
          read.any? { |key| placement(trace, key, earlier) }
        end
      end

      def spine_reads(trace)
        keys = Trace.spine_keys(trace.graph)
        Array(trace.graph["nodes"]).select { |node| keys.include?(node["key"]) }
          .flat_map { |node| Array(node["input_from"]) + Array(node["result_from"]) }
      end

      # The step among `placed` a key is or hangs under (`expansion_parent`), nil when none.
      def placement(trace, key, placed, seen = Set.new)
        return key if placed.include?(key)
        return nil if key.nil? || !seen.add?(key)

        placement(trace, trace.node(key)&.fetch("expansion_parent", nil), placed, seen)
      end

      def branch_completed(trace, call)
        row = trace.task(call)
        return "the compose call #{call} #{row["status"]}: #{row.dig("error", "key").inspect}" if row && row["status"] != "completed"

        under = trace.under(call)
        return "nothing was composed under #{call}: the call placed no node" if under.empty?

        amiss = under.reject { |node| %w[completed canceled].include?(node["status"]) }
        return "#{amiss.map { |n| "#{n["key"]}(#{n["status"]})" }.join(", ")} did not complete under #{call}" unless amiss.empty?

        true
      end

      # The control's success: one call's worth of work composed nothing
      # and delegated nothing (`compose_zero`, `task_zero` on the record).
      def composed_nothing(trace)
        verbs = trace.compose_rows + trace.task_rows
        verbs.empty? ? true : "over-reach: #{verbs.map { |r| "#{r["key"]}:#{r["tool_name"]}" }.join(", ")} on one read's worth of work"
      end

      # ── the task family (the offline probe's rules through rho) ──────────
      def background?(row) = row["tool_name"] == Trace::TASK && Hash(row["tool_input"])["wait"] != true

      def first_round_task_rows(trace) = trace.first_round_rows.select { |row| row["tool_name"] == Trace::TASK }

      def task_prompts(trace) = trace.task_rows.map { |row| trace.input_of(row)["prompt"].to_s }

      # How many delegations named each file — task PROMPTS that name it and
      # compose scripts alike, each text counted once however many times it
      # spells the name (12a L2: a finder prompt saying its file twice read
      # as two finders). A script briefs several members in one text, so a
      # file named by two of its members still reads once here; the script's
      # own picture is the scorer's.
      def per_file(trace, files)
        texts = task_prompts(trace) + trace.compose_rows.map { |row| trace.input_of(row)["script"].to_s }
        files.to_h { |file| [file, texts.count { |text| text.include?(file) }] }
      end

      # The graph verbs a branch called — every `compose` and `task` row the spine did not make
      # (`Trace#spine_calls`, the kernel's mark).
      def graph_verbs_inside_branches(trace) = ((trace.compose_rows + trace.task_rows) - trace.spine_calls).size

      # ── the workflow family (decision 11) ────────────────────────────────
      # Which door the model took: a compose branch, a fan of ≥ 2 `task`
      # calls in one round, or neither — a recorded fact, never a pass condition.
      def door(trace)
        return "compose" if trace.compose_rows.any?
        return "task_fan" if trace.rounds.any? { |round| trace.fanned_by(round["key"]).count { |r| r["tool_name"] == Trace::TASK } >= 2 }

        nil
      end

      def reached_a_door(trace)
        door(trace) ? true : "no compose call and no round fanned two task calls: #{trace.called.inspect}"
      end

      # ── the door, read as the door register reads it (beside `door`) ─────
      # A door is read on the spine's first three rounds: a look, a second look, the door.
      DOOR_ROUNDS = 3
      # The graph verbs that hand work out: the round making the first is the dispatch round.
      DISPATCH_TOOLS = [Trace::TASK, Trace::COMPOSE].freeze
      # A call that reads before a dispatch — a shell command counted whatever it runs.
      READ_CLASS_TOOLS = Trace::READ_CLASS
      # How much of a dispatch call's brief rides the record.
      BRIEF_HEAD = 80

      # THE DOOR THE RUN WENT THROUGH, a kind as the door register kinds one: the first of the
      # spine's first three rounds that is not a look (`TaskBench::Look`) is the door, its calls kinded
      # by the task bench's `Door`; three looks, or fewer rounds all looks, are `scout`; a spine with no
      # round is `none`. `declared` names the entries a door round declared outright; else the round's
      # own (`door_declared`).
      def door_kind(trace, declared: nil) = door_reading(trace, declared: declared).fetch("door_kind")

      # The door's facts beside its kind (`Door#fields`): the round among the first three it was
      # read at (nil on a scout), whether its script built, its members, what came back unread, and
      # the calls beside it.
      def door_read(trace, declared: nil) = door_reading(trace, declared: declared).except("door_kind")

      def door_reading(trace, declared: nil)
        keys = Trace.spine_keys(trace.graph).first(DOOR_ROUNDS)
        rounds = keys.map { |key| round_calls(trace, key) }
        index = rounds.index { |round| !TaskBench::Look.look?(round) }
        door = if index
          round_door(trace, keys[index], declared: declared)
        else
          TaskBench::Door.new(kind: rounds.empty? ? "none" : TaskBench::Door::SCOUT, built: nil, members: 0, unread: [], beside: [])
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

      # THE DISPATCH ROUND: the 1-based place among the spine's rounds of the first that made a `task`
      # or `compose` call — the round a scout the narrow look rule reads as a door still dispatched
      # in; nil when none did.
      def dispatch_round(trace)
        index = Trace.spine_keys(trace.graph).index { |key| trace.fanned_by(key).any? { |row| DISPATCH_TOOLS.include?(row["tool_name"]) } }
        index&.succ
      end

      # A SCOUT, THEN THE DOOR: the dispatch round is the second or later, and an earlier spine round
      # made a read-class call.
      def scout_then_door(trace)
        at = dispatch_round(trace)
        earlier = at.nil? ? [] : Trace.spine_keys(trace.graph).first(at - 1)
        earlier.any? { |key| trace.fanned_by(key).any? { |row| READ_CLASS_TOOLS.include?(row["tool_name"]) } }
      end

      # THE DISPATCH ROUND'S DOOR: the round that handed work out, kinded as `door_kind` kinds a round —
      # its place (`round`) and `Door#fields` — where a scout the look rule reads as a door (an `echo`
      # beside a listing, a todo beside one, three look rounds) still dispatched later; nil when
      # nothing was dispatched.
      def dispatch_door(trace)
        at = dispatch_round(trace)
        at.nil? ? nil : { "round" => at }.merge(round_door(trace, Trace.spine_keys(trace.graph).fetch(at - 1)).fields)
      end

      # The lib/ sources the dispatch round's delegations name in their briefs.
      def dispatch_names(trace)
        at = dispatch_round(trace)
        at.nil? ? [] : delegations(trace, Trace.spine_keys(trace.graph).fetch(at - 1)).flat_map { |row| brief_names(trace, row) }.uniq
      end

      # The dispatch round's calls, each `{tool, wait, prompt_head}`: the call's `wait` as it was
      # written and the head of its brief — a task's prompt, a compose's script, a command; none when
      # nothing was dispatched.
      def door_calls(trace)
        at = dispatch_round(trace)
        rows = at.nil? ? [] : trace.fanned_by(Trace.spine_keys(trace.graph).fetch(at - 1))
        rows.map do |row|
          input = trace.input_of(row)
          brief = input["prompt"] || input["script"] || input["command"]
          { "tool" => row["tool_name"], "wait" => input["wait"], "prompt_head" => (brief.to_s[0, BRIEF_HEAD] unless brief.nil?) }
        end
      end

      # ── the scout's names (D6: list, then fan over what was listed) ──────
      # A source under lib/ as a brief names it.
      LIB_SOURCE = %r{\blib/[\w-]+\.rb\b}
      # A Ruby file's own name as a listing prints it: bare (`ls lib`, rho's `grep` over lib/, which
      # print names relative to the path they read) or under a directory (`find`, `grep -l`).
      LISTED_NAME = /[\w-]+\.rb\b/

      # THE GUESSED NAMES: each lib/ source a spine delegation's brief names — a `task` prompt, a
      # compose script or its params — whose own name no read-class call of an EARLIER spine round
      # returned (its text, `Trace#output_of`), in the order named. A listing beside the delegation, in
      # its own round, briefs nothing: the briefs were written in that turn. What the model named is
      # never a listing (a `read` of lib/slug.rb lists no file), and a branch's own delegations are the
      # branch's, briefed off what the branch listed.
      def guessed_names(trace) = guesses(trace).flat_map(&:last).uniq

      # THE GUESSES A DELEGATE MAY HAVE LISTED, for a hand read: the guessed names of a round some
      # earlier spine round made a `task` call before — its result (a receipt, a waited call's output)
      # is text the trace does not join, so a fan over what a discovering delegate returned reads as
      # guessed.
      def guessed_after_a_delegate(trace)
        keys = Trace.spine_keys(trace.graph)
        guesses(trace).select { |index, _names| keys.first(index).any? { |key| trace.fanned_by(key).any? { |row| row["tool_name"] == Trace::TASK } } }
          .flat_map(&:last).uniq
      end

      # Each spine round's guessed names, `[its index, names]`, in round order.
      def guesses(trace)
        keys = Trace.spine_keys(trace.graph)
        keys.each_with_index.map do |key, index|
          listed = listed_names(trace, keys.first(index))
          [index, delegations(trace, key).flat_map { |row| brief_names(trace, row) }.reject { |name| listed.include?(File.basename(name)) }]
        end
      end

      # D6's wrong door (`door-choice-design.md:281`): a delegation over names not in the listing.
      def fan_over_guessed_names(trace) = guessed_names(trace).any?

      # Every lib/ source the spine's delegations named, in the order first named.
      def briefed_names(trace) = Trace.spine_keys(trace.graph).flat_map { |key| delegations(trace, key) }.flat_map { |row| brief_names(trace, row) }.uniq

      # The file names the read-class calls of these spine rounds returned.
      def listed_names(trace, keys)
        keys.flat_map { |key| trace.fanned_by(key) }.select { |row| READ_CLASS_TOOLS.include?(row["tool_name"]) }
          .flat_map { |row| trace.output_of(row).scan(LISTED_NAME) }.uniq
      end

      def delegations(trace, key) = trace.fanned_by(key).select { |row| DISPATCH_TOOLS.include?(row["tool_name"]) }

      def brief_names(trace, row)
        input = trace.input_of(row)
        [input["prompt"], input["script"], input["params"]].join("\n").scan(LIB_SOURCE)
      end

      # ── the plain concurrent fan (a reached door no graph verb made) ─────
      # THE ROUND THAT RAN A PROGRAM CONCURRENTLY with the shell alone: the 1-based place among the
      # spine's rounds of the first holding two `bash` rows or more that each run `program`, or one
      # row that runs it in two background jobs or more and waits (`ConcurrentFan`); nil when none
      # did. A sequence — a `for` loop, `a && b && c`, one run a round — is no fan, and a row that
      # names the program without running it (`cat bin/fetch`) runs nothing.
      def concurrent_fan_round(trace, program)
        index = Trace.spine_keys(trace.graph).index do |key|
          commands = trace.fanned_by(key).select { |row| row["tool_name"] == "bash" }.map { |row| trace.input_of(row)["command"].to_s }
          commands.count { |command| ConcurrentFan.runs(command, program).positive? } >= 2 ||
            commands.any? { |command| ConcurrentFan.concurrent?(command, program) }
        end
        index&.succ
      end

      # ── the job's door (D4: one background `task` for a long command) ────
      # The rows the spine made in the rounds up to and including the dispatch round; none when
      # nothing was dispatched.
      def through_dispatch(trace)
        at = dispatch_round(trace)
        at.nil? ? [] : Trace.spine_keys(trace.graph).first(at).flat_map { |key| trace.fanned_by(key) }
      end

      # THE JOB DID NOT GO THROUGH COMPOSE: no compose row in or before the dispatch round; else the
      # dispatch round's kind (`compose_one`, …) and what it called.
      def job_not_composed(trace)
        return true if through_dispatch(trace).none? { |row| row["tool_name"] == Trace::COMPOSE }

        key = Trace.spine_keys(trace.graph).fetch(dispatch_round(trace) - 1)
        "the job went through compose (#{round_door(trace, key).kind}): #{key} called " \
          "#{trace.fanned_by(key).map { |row| row["tool_name"] }.tally.inspect}"
      end

      # A compose the run made after its `task` went out: conduct, never the door.
      def compose_after_task(trace) = trace.task_rows.any? && trace.compose_rows.any? && job_not_composed(trace) == true

      # D4'S RIGHT DOOR, the door objective's rule (`TaskBench::Objectives::D4P`) over the dispatch
      # round: one `task` there, in the background (`wait != true`), whose prompt names the suite —
      # `suite`, the task's own words for it — and no `start_process` or compose in or before it.
      def d4_right(trace, suite)
        rows = through_dispatch(trace)
        tasks = rows.select { |row| row["tool_name"] == Trace::TASK }
        tasks.one? && background?(tasks.first) && suite.match?(trace.input_of(tasks.first)["prompt"].to_s) &&
          rows.none? { |row| [Trace::COMPOSE, TaskBench::Door::START_PROCESS].include?(row["tool_name"]) }
      end

      # THE RECEIPT-WAKE LOOP: ≥ 1 receipt accepted as kernel mail, and every loop the feed named
      # reached `completed` (the gallery's `detached_receipt?` reads, `shapes.rb:272-278`). THE
      # COMPOSE DOOR OWES NO RECEIPT: the kernel mails a `task_result` receipt for a DETACHED task's
      # result only (`wake_continuation.rb`), and a compose branch of N members is not a detached
      # fan — a run whose only door is compose (no `task` row) is read by its branch: completed
      # under its call, every loop completed. NO RECEIPT reads two ways: a fan whose every `task`
      # call waited owed none (the model's shape), a detached call with none is mail the kernel owed.
      def receipt_loop(trace)
        return compose_door(trace) if trace.task_rows.empty? && trace.compose_rows.any?
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

      def compose_door(trace)
        trace.compose_rows.each do |call|
          branch = branch_completed(trace, call["key"])
          return "the compose door mails no task_result receipt, and #{branch}" unless branch == true
        end
        every_loop_completed(trace)
      end

      def every_loop_completed(trace)
        statuses = trace.payloads("turn_status").group_by { |p| p["agent_loop_public_id"] }
          .transform_values { |items| items.map { |p| p["loop_status"] } }
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
        { "door" => door(trace), "rounds" => trace.spine_rounds.size, "receipts" => trace.receipts,
          "compose_calls" => trace.compose_rows.size, "task_calls" => trace.task_rows.size, "bash_calls" => trace.tool_rows("bash").size }
      end

      # ── the compaction family (decision 12) ──────────────────────────────
      # KEYS ARE MARKS, NEVER NUMBERS: the spine carries rounds the until
      # extension authored (`work-2`) beside the kernel's `rN`, and a
      # reader that took the number out of a key raised on the wall-kernel
      # record (evals run 2). The columns count by the loop row's ORDER
      # from the round the first compaction repaired (its payload's
      # `task_key`).
      def spine_keys(trace) = trace.spine_rounds.map { |row| row["key"] }

      # The spine round the first compaction repaired, by key — the
      # earliest in spine order; nil when nothing was compacted.
      def compacted_round(trace)
        repaired = trace.compactions.map { |p| p["task_key"] }
        spine_keys(trace).find { |key| repaired.include?(key) }
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

      # Spine rounds from the compacted round on, beyond the task's stated
      # minimum after a compaction; nil when nothing was compacted.
      def induced_rounds(trace, minimum_after:)
        at = compacted_round(trace) or return nil
        keys = spine_keys(trace)
        index = keys.index(at) or return nil
        [keys.size - index - minimum_after, 0].max
      end

      # A harness deadline or cost stop is classified at the loop level. Ignore its
      # `creator_requested` and `loop_canceled` node failures when judging whether model rounds
      # completed; other failure keys remain visible.
      HARNESS_STOP = %w[creator_requested loop_canceled].freeze

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
