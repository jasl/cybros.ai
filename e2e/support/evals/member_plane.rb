require "bigdecimal"
require "json"
require "uri"
require_relative "../gallery/shapes"
require_relative "task_reads"
require_relative "sealed_request"
require_relative "trace"

module E2E
  module Evals
    # THE MEMBER-PLANE AND DAEMON READS EVERY LANE KEEPS A COPY OF: the same bytes in
    # `live_gallery_test.rb:389-481`, `live_task_mail_test.rb:249-302` and
    # `live_exit_long_test.rb:447-477`, moved once. A mixin over `E2E::LiveJourney` (it reads
    # `@daemon`, `agent_api`, `loop_row`, `workspace_public_id`), included by the evals lane; the
    # lanes keep their copies until the RUN half retires them (a residue line). `rho do` is the door
    # for every task but the authored halt (`author_halting_loop!`, live_repair's shape).
    #
    # THE HARNESS'S PATIENCE IS `LiveJourney`'S: `await_loop_completion` raises `E2E::Stopped` on
    # the run's deadline, `stop_over_cost!` stops the conversation over the task's patience in money
    # (`@cost_stop_usd`, the lane sets it per run off `Bench#cost_stop_usd_for`) read off
    # `phases.spend`, and `watching_spend` polls it while a verb blocks — a record with `stopped:
    # cost_stop`, never a kernel ceiling. The stop's verb reads `@conversation`, the turn
    # `open_turn` stashed.
    #
    # THE THIRD STOP IS THE MODEL'S QUESTION: outside answer_ask's scripted person, no driver scripts
    # a person for the model's own `ask` (`attention.reason` `awaiting_human`), which nobody would
    # ever answer — seven scoring runs idled that way to the deadline, ≈ 88 min of box time, each
    # recorded as `stopped: deadline`. Every wait on a model's turn — `await_loop_completion_unattended`,
    # the quiet read, the tasks-settled read, the pump's park loop and the attendant beside turn 1's
    # blocked `rho watch` (`watch_the_turn`) — reads the park off the rows it polls: the run's first
    # ask gets the bench's answer, and the next unanswered one stops the run and raises
    # `needs_person` at once, the ask's loop, key and prompt on the record's facts. The stop is made
    # where `needs_person` is raised, as the cost stop's is (a watch blocked beside the ask ends only
    # on it); `caught` stops for the deadline alone. The word is rho's own (`rho do`'s `react`: an
    # awaiting_human park ends the run, exit 2).
    module MemberPlane
      EVENT_TYPES = %w[context_compacted attention_required input_accepted turn_status].freeze
      # The record's `stopped` word for the person's interrupt.
      INTERRUPTED = "interrupted".freeze
      # The record's `stopped` word for the model's ask once the run's answer is spent.
      NEEDS_PERSON = "needs_person".freeze
      # The kernel's word for a model's question on the loop row's `attention`
      # (`AgentRuns::EvaluateQuiescence::ASKING_REASON`).
      ASKING_REASON = "awaiting_human".freeze
      # The stops that leave the loop running for `caught` to end: the deadline is raised by waits
      # that stop nothing; the cost stop and `needs_person` stop the run where they are raised.
      LOOP_LEFT_RUNNING = ["deadline"].freeze
      # The attendant's cadence beside a blocked `rho watch`: a read of the daemon's own row over
      # the control socket, no member-plane traffic until that row asks.
      ASK_POLL_SECONDS = 3
      # The timeline's two kinds of kernel mail: a `direct_reply` wakes a turn, a `message` joins
      # the history without one (a receipt every call asked `wake: "passive"` for).
      MAIL_TURN_KINDS = %w[direct_reply message].freeze
      # THE TRACE READ IS PACED UNDER THE KERNEL'S CEILING (12a L1): 120
      # member reads a minute per credential is the product's, so one task
      # detail every 0.6 s (100/min) leaves the spend poll and the feed pages
      # room; a Long's ≈ 105 tool tasks read in ≈ 65 s instead of a 429.
      TASK_READ_PACE_SECONDS = 0.6
      # The quiet poll's period, and the two consecutive quiet polls a
      # conversation must answer before its receipts are read as settled.
      QUIET_POLL_SECONDS = 5
      QUIET_POLLS = 2
      # The runner's `in_flight` is waited out before the tools are re-pointed
      # (12a L7), this long.
      RUNNER_IDLE_SECONDS = 120
      # The transcript's page (the route's MAX_LIMIT): a Long's 130 rounds
      # are two paced GETs, a short loop's one.
      TRANSCRIPT_PAGE_LIMIT = 100

      def rho_do_arguments(text, project, model:, flags: {}, runner: nil)
        arguments = ["do", text, "--model", model, "--dir", project]
        arguments.concat(["--approval", flags["approval"].to_s]) if flags["approval"]
        arguments.concat(["--until", flags["until"].to_s, "--attempts", flags.fetch("attempts", 5).to_s]) if flags["until"]
        arguments.concat(["--runner", runner]) if runner
        arguments
      end

      # The turn's ids are stashed as the run OPENED (`@opened`): a driver answers its Run only at
      # its end, and a `Stopped` raised before that — the deadline, the cost stop — must still find
      # the loop to trace (`caught`). A driver that opens two turns keeps the last; the primary's
      # trace is what a stopped record needs.
      def open_turn(text, project, model:, flags: {}, runner: nil)
        arguments = rho_do_arguments(text, project, model: model, flags: flags, runner: runner)
        output, status = @daemon.cli(*arguments)
        # The status rides the sentence: a child that printed nothing and
        # died says HOW it died (a signal, an exit code) or the record
        # carries nothing to read (the box's 2026-09-18 cell). The record
        # files the FIRST line, so rho's own last line — the one sentence a
        # refusal prints — sits beside the status; the whole output follows.
        assert_predicate status, :success?, "rho do failed (#{status.inspect}): #{output.lines.last.to_s.strip}\n#{output}"
        @last_do_output = output
        @conversation, loop_id = ids_of(output)
        @opened = Drivers::Run.one(loop_id, @conversation)
        [@conversation, loop_id]
      end

      attr_reader :last_do_output, :opened

      # A driver that learned facts BEFORE a stop keeps them on the opened Run (the pump's parks),
      # so `caught`'s salvage records them; the Run is rebuilt, never mutated.
      def stash_facts_on_opened(facts)
        @opened = @opened.with(facts: @opened.facts.merge(facts.transform_keys(&:to_s)))
      end

      # THE RUN'S OUTCOME, WHATEVER HAPPENED: the block drives and answers the Run to trace; a
      # `Stopped` or a raise inside it salvages the trace of the Run it answered — or of the turn
      # `open_turn` opened before it raised — so a stopped run is a record with its loops, its
      # rounds, its spend, never `Trace.empty`. A deadline's loop is stopped first (left running it
      # would spend into the next run's window on the re-pointed tools); the cost stop and a
      # `needs_person` stop stopped theirs where they were raised. `{run, trace, stopped,
      # error, note}`. THE PERSON'S INTERRUPT IS A RECORD TOO: a Ctrl-C mid-run stops the loop,
      # salvages its trace — the spend visible — and rides the outcome as `interrupt`, for the lane
      # to re-raise once the record is on disk (`Interrupt` is no StandardError: it was a lost run).
      # A TERM is the same stop by hand — the launcher TERMs a unit's process group, which Ruby
      # raises as a plain `SignalException` — and its note names the signal.
      # WHAT THE WAITS STASHED RIDES A SETTLED RUN TOO: a driver builds its Run from what it saw, so
      # the opened Run's facts — what the harness answered on the way — lie under the run's own.
      def caught
        @opened = nil
        run = yield
        run = run.with(facts: @opened.facts.merge(run.facts)) if @opened
        { run: run, trace: read_trace(run.loop, run.conversation, extra_loops: run.extra_loops, facts: run.facts),
          stopped: nil, error: nil }
      rescue Stopped => stop
        opened = run || @opened
        stop_conversation!(opened.conversation) if LOOP_LEFT_RUNNING.include?(stop.why) && opened&.conversation
        { run: opened, trace: salvage(opened), stopped: stop.why, error: nil, note: stop.message[0, 300] }
      rescue SignalException => interrupt
        opened = run || @opened
        stop_conversation!(opened.conversation) if opened&.conversation
        { run: opened, trace: salvage(opened), stopped: INTERRUPTED, error: nil,
          note: interrupted_note(interrupt), interrupt: interrupt }
      rescue StandardError, Minitest::Assertion => error
        { run: run || @opened, trace: salvage(run || @opened), stopped: nil,
          error: "#{error.class}: #{error.message.lines.first.to_s.strip[0, 300]}" }
      end

      # WHO STOPPED THE RUN, by its signal: INT is the person's Ctrl-C; any other signal — the
      # launcher's TERM — names itself.
      def interrupted_note(signal)
        if signal.signo == Signal.list.fetch("INT")
          "the run was interrupted by the person"
        else
          "the run was stopped by SIG#{Signal.signame(signal.signo)}"
        end
      end

      # The trace of the Run in hand; `Trace.empty` with no Run, or with
      # its facts when the read itself fails (a warning, never a lost record).
      def salvage(run)
        return Trace.empty if run.nil?

        read_trace(run.loop, run.conversation, extra_loops: run.extra_loops, facts: run.facts)
      rescue StandardError => error
        warn "no trace could be salvaged: #{error.class}: #{error.message}"
        Trace.empty(facts: run.facts)
      end

      # THE TOOLS POINTED AT THE RUN'S TREE, the refusal read: `control`
      # parses the body alone, and a root the daemon cannot use answers a
      # `{error: {code: not_a_directory}}` document with a 422 nobody sees —
      # a silent one leaves the run's tools on the previous project. Any
      # refusal is this run's error at once: the door judges the directory
      # alone (the runner's idle is `await_runner_idle!`'s, below).
      def point_tools!(daemon, root)
        answer = daemon.control(:post, "/environment", body: { root: root })
        return answer unless answer.key?("error")

        raise "rho refused to point its tools at #{root}: #{answer["error"].inspect}"
      end

      # THE RUNNER IS IDLE BEFORE THE NEXT RUN'S REPOINT (12a L7): `/status`'s
      # `runner.in_flight` on every daemon serving tools, polled until zero
      # or the patience runs out (then the repoint's own refusal says so). A
      # daemon that serves no runner block reads as idle.
      def await_runner_idle!(daemons, patience: RUNNER_IDLE_SECONDS)
        limit = Process.clock_gettime(Process::CLOCK_MONOTONIC) + patience
        loop do
          busy = daemons.compact.filter_map do |daemon|
            in_flight = daemon.status.dig("runner", "in_flight").to_i
            in_flight.positive? ? in_flight : nil
          end
          return true if busy.empty?

          if Process.clock_gettime(Process::CLOCK_MONOTONIC) > limit
            warn "the runner still has #{busy.sum} tool call(s) in flight after #{patience} s"
            return false
          end
          sleep 3
        end
      end

      # A RUN'S PROCESSES END WITH THE RUN: a process a loop started with
      # `start_process` follows its conversation, and the lane stops a run's
      # conversation without ending it, so a group still live when the next
      # run opens puts rho's environment sentence ("Processes started earlier
      # … may still be running") into that run's developer block. Every live
      # row of each daemon's OWN table is stopped through the person's verb,
      # `rho kill ID` on that daemon's CLI, which TERMs, escalates to KILL and
      # returns once the row reads exited; a home that ended one prints a
      # `processes:` line naming the count. A row still live after it is a
      # warning, and so is a home whose table could not be read or ended —
      # the next home is still ended and the record stands.
      def end_processes!(daemons)
        daemons.compact.each do |daemon|
          end_own_processes!(daemon)
        rescue StandardError => error
          warn "the run's processes on #{daemon.home} could not be ended: #{error.class}: #{error.message.to_s[0, 200]}"
        end
      end

      def end_own_processes!(daemon)
        live = own_live_processes(daemon)
        return if live.empty?

        live.each { |row| daemon.cli("kill", row.fetch("id")) }
        puts "processes: #{live.size} ended (#{live.map { |row| row["id"] }.join(", ")})"
        own_live_processes(daemon).each do |row|
          warn "the run's process #{row["id"]} (#{row["command"]}) still live after rho kill: the next run's prompt names it"
        end
      end

      # THE DAEMON'S OWN TABLE ALONE, `/processes` narrowed to its own runner
      # row (`?runner=`, the listing `rho ps --runner` reads): rho answers
      # that table locally, where the bare listing also asks every followed
      # host's runner through Nexus's relay — a one-task loop opened on that
      # runner per read, for rows this home never ends.
      def own_live_processes(daemon)
        runner = daemon.status.dig("identity", "runner_executor_public_id")
        raise "rho names no runner row of its own: its process table cannot be read without the relay" if runner.nil?

        document = daemon.control(:get, "/processes?runner=#{URI.encode_www_form_component(runner)}")
        raise "rho refused the process listing: #{document["error"].inspect}" if document.key?("error")

        document.fetch("processes").reject { |row| row["status"] == "exited" }
      end

      def ids_of(output)
        ids = %w[conversation run].map { |line| output[/^#{line}:\s+(\S+)/, 1] }
        refute_includes ids, nil, "rho do printed no conversation or loop id:\n#{output}"
        ids
      end

      # ONE GET PER (loop, key) FOR THE RUN (12a L1): the trace read joins
      # every tool task's `tool_input` and the predicates re-read through
      # `task_output` / `task_input`; a SETTLED task's document is memoized
      # so a re-read costs no request, while a task still moving — its row
      # changes — is read fresh each time.
      def task_detail(loop_id, key)
        @task_details ||= {}
        cached = @task_details[[loop_id, key]]
        return cached if cached

        task = agent_api("#{loop_path(loop_id)}/tasks/#{key}").fetch("task")
        @task_details[[loop_id, key]] = task if Gallery::TERMINAL_TASK_STATUSES.include?(task["status"])
        task
      end

      def task_detail_cached?(loop_id, key) = (@task_details || {}).key?([loop_id, key])

      # The pace between uncached task reads inside a trace read.
      def pace_task_reads = sleep(TASK_READ_PACE_SECONDS)

      def task_output(loop_id, key) = task_detail(loop_id, key)["output"].to_s

      def task_input(loop_id, key) = Hash(task_detail(loop_id, key)["tool_input"])

      # `rho result`'s whole print (the status line, then the deliverable's
      # text): what the model answered, through the verb a person types.
      def result_of(loop_id)
        printed, status = @daemon.cli("result", loop_id)
        status.success? ? printed.to_s : "(rho result failed: #{printed.to_s.lines.first.to_s.strip})"
      end

      def graph_of(loop_id) = agent_api("#{loop_path(loop_id)}/graph")

      # A loop backing a turn has no feed of its own — its items ride its
      # conversation's; a standalone loop (the authored halt) has its own.
      def feed(conversation, loop_id = nil)
        base = conversation ? "/agent_api/v1/workspaces/#{workspace_public_id}/conversations/#{conversation}/events" :
          "#{loop_path(loop_id)}/events"
        items = []
        after = nil
        loop do
          page = agent_api("#{base}?limit=200#{after ? "&after=#{after}" : ""}")
          rows = Array(page["events"])
          items.concat(rows)
          after = page.dig("pagination", "next_after")
          break if after.nil? || rows.empty?
        end
        items
      end

      # The conversation's turns, oldest first (live_task_mail's `timeline`).
      def timeline(conversation)
        turns = []
        after = nil
        loop do
          page = agent_api("/agent_api/v1/workspaces/#{workspace_public_id}/conversations/#{conversation}/turns" \
            "?limit=100#{after ? "&after_position=#{after}" : ""}")
          rows = Array(page["turns"])
          turns.concat(rows)
          after = page.dig("pagination", "after_position")
          break if rows.empty? || after.nil?
        end
        turns
      end

      # THE MAIL IS IN A TURN'S HISTORY when the receipt's own turn — kernel-stamped, of origin
      # `task_result` — sits on the timeline BEFORE it (live_task_mail's `mail_before_turn?`): the
      # `direct_reply` a waking receipt opened, or the `message` a passive one joined the history as
      # (`AgentRuns::ResultDelivery`: it drains ahead of the person's later input and starts no reply).
      # `origin` is the kernel row's: a task's receipt (`task_result`) or a spawned child's reply
      # (`child`, the spawn family).
      def mail_before_turn?(conversation, loop_row, origin: "task_result")
        turns = timeline(conversation)
        position = turns.find { |turn| turn["public_id"] == loop_row.dig("turn", "public_id") }&.fetch("position")
        return false if position.nil?

        turns.any? { |turn| turn["origin"] == origin && MAIL_TURN_KINDS.include?(turn["kind"]) && turn["position"] < position }
      end

      # Every loop the feed's turn_status items name, in order of first
      # appearance — the primary and whatever the receipts woke.
      def loops_on_feed(conversation)
        feed(conversation).select { |item| item["type"] == "turn_status" }
          .filter_map { |item| item.dig("payload", "run_public_id") }.uniq
      end

      # THE RECEIPT-WAKE LOOP RUNS UNTIL IT IS DRY: a loop whose reply went final while its branches
      # ran is woken by each receipt, and the woken turn may start branches of its own. Quiet =
      # every loop on the feed settled and no task of any of them live — on QUIET_POLLS consecutive
      # polls QUIET_POLL_SECONDS apart with the SAME loop set (12a L3: the kernel mails a receipt
      # and wakes a turn 100 ms–1 s after the primary completes, and a single quiet poll read the
      # trace with that loop still running). The deadline is the harness's, named on the error. A
      # woken loop's ask is the run's too: answered from the run's one answer, or the run's stop;
      # the answered loop stays live while it runs on, so the quiet count starts again.
      def await_conversation_quiet(conversation, deadline:, every: QUIET_POLL_SECONDS, polls: QUIET_POLLS)
        limit = Process.clock_gettime(Process::CLOCK_MONOTONIC) + deadline
        quiet_sets = []
        loop do
          rows = loops_on_feed(conversation).map { |id| loop_row(id) }
          rows.each do |row|
            asking_loop = row.fetch("public_id")
            attend_the_ask!(asking_loop, row) if unanswered_ask?(asking_loop, row)
          end
          live = rows.reject { |row| settled?(row) } +
            rows.select { |row| row.fetch("tasks").any? { |t| !Gallery::TERMINAL_TASK_STATUSES.include?(t["status"]) } }
          quiet_sets = live.empty? ? (quiet_sets << rows.map { |row| row.fetch("public_id") }.sort) : []
          return rows if quiet_sets.size >= polls && quiet_sets.last(polls).uniq.size == 1
          raise Stopped.new("deadline", "the receipts never went quiet in #{deadline} s: #{live.map { |r| summarize(r) }.join(" | ")}") if
            Process.clock_gettime(Process::CLOCK_MONOTONIC) > limit

          sleep every
        end
      end

      # THE CONVERSATION'S WHOLE SPEND, read AFTER the run is stopped (12a
      # L7): the primary's phases spend plus every other loop the feed
      # named — the receipt-woken turns whose work outlived the driver — so
      # a runaway woken turn lands on the record it belongs to. The sum
      # keeps the route's shape (`cost_amount` a decimal String, the unit
      # one only when every loop agrees, the cache rate recomputed over the
      # summed counts, and `by_model` — the route's split of its receipts by
      # the model each names — summed per model the same way, carried only
      # when some loop served one); a loop whose spend the route did not
      # serve counts nothing.
      def spend_of_loops(loop_ids)
        spends = loop_ids.uniq.map { |id| phases(id)["spend"] }.compact.map { |spend| Hash(spend) }
        return nil if spends.empty?

        input = spends.sum { |spend| spend["input_tokens"].to_i }
        cache_read = spends.sum { |spend| spend["cache_read_tokens"].to_i }
        summed = { "input_tokens" => input, "output_tokens" => spends.sum { |spend| spend["output_tokens"].to_i },
                   "cache_read_tokens" => cache_read, "cache_hit_rate" => (input.zero? ? nil : (cache_read.to_f / input).round(6)),
                   **summed_money(spends) }
        splits = spends.filter_map { |spend| spend["by_model"] }
        splits.empty? ? summed : summed.merge("by_model" => summed_by_model(splits))
      end

      # One model's rows of every split, summed: the tokens, and the money as the whole spend's.
      def summed_by_model(splits)
        splits.flat_map(&:to_a).group_by(&:first).transform_values do |pairs|
          rows = pairs.map(&:last)
          { "input_tokens" => rows.sum { |row| row["input_tokens"].to_i }, "output_tokens" => rows.sum { |row| row["output_tokens"].to_i },
            "cache_read_tokens" => rows.sum { |row| row["cache_read_tokens"].to_i }, **summed_money(rows) }
        end
      end

      # The priced rows' `cost_amount` added as decimals (a String, nil when none priced), and the
      # unit only when every priced row agrees on one.
      def summed_money(rows)
        costs = rows.filter_map { |row| row["cost_amount"] }
        units = rows.filter_map { |row| row["cost_unit"] }.uniq
        { "cost_amount" => (costs.empty? ? nil : costs.sum { |cost| BigDecimal(cost.to_s) }.to_s("F")),
          "cost_unit" => (units.one? ? units.first : nil) }
      end

      # The daemon's rows are keyed by the HOST and carry every loop that
      # backed it, so a loop id finds its row through `loops`, the way `rho watch` does.
      def followed(loop_id)
        @daemon.control(:get, "/followers").fetch("followers").find do |row|
          row.fetch("public_id") == loop_id || Array(row["run_public_ids"]).include?(loop_id)
        end
      end

      def read_trace(loop_id, conversation, extra_loops: [], facts: {})
        row = loop_row(loop_id)
        graph = graph_of(loop_id)
        usage = transcript_usage(loop_id)
        mainline = Trace.mainline_keys(graph)
        tasks = row.fetch("tasks").map { |task| join_task_detail(loop_id, task, mainline: mainline) }
          .map { |task| usage.key?(task["key"]) ? task.merge("usage" => usage.fetch(task["key"])) : task }
        events = feed(conversation, loop_id).select { |item| EVENT_TYPES.include?(item["type"]) }
        loops = [loop_id, *extra_loops].map { |id| { "id" => id, "status" => (id == loop_id ? row : loop_row(id)).fetch("status") } }
        requests = task_requests(loop_id, graph, tasks)
        read = requests.nil? ? {} : { "task_requests" => requests }
        Trace.new(loops: loops, graph: graph, tasks: tasks, events: events, spend: phases(loop_id)["spend"],
          sealed: read_sealed_request(loop_id, tasks, graph), facts: facts.transform_keys(&:to_s).merge(read))
      end

      def task_requests(loop_id, graph, tasks)
        steps = TaskReads::Reading.of(graph, tasks).steps
        return nil if steps.empty?

        steps.to_h { |node| [node["key"], task_request(loop_id, node["key"])] }
      end

      # A diagnostic read, as the sealed request's: an error is a warning and nil, never a lost trace.
      def task_request(loop_id, key)
        document = agent_api(SealedRequest.path(loop_path(loop_id), key))
        pace_task_reads
        SealedRequest.tail_envelopes(SealedRequest.from_document(document, key))
      rescue StandardError => error
        warn "the sealed request of #{key} could not be read: #{error.class}: #{error.message}"
        nil
      end

      # THE DETAIL EACH ROW NEEDS, through the memoized, paced door: a tool row's `tool_input`, and on
      # a read-class call a `mainline` round made (`Trace::READ_CLASS`) its `output` too — the text it
      # returned, which a later brief's names are read against (`Predicates.guessed_names`); a
      # round's `request_bytes` — the kernel's stored size of its sealed body, the series the record
      # keeps per round; absent on a round never scheduled, so the row gains the key only when the
      # read served one — and its `output`, the round's own text, which the leaked-call count reads
      # (`Trace#leaked_calls`). Every other kind (an await, a join) rides as the loop row served it.
      # The round reads are the trace read's added cost: one paced GET per settled round, once per
      # (loop, key) for the run.
      def join_task_detail(loop_id, task, mainline: [])
        kind = task["kind"]
        return task unless %w[tool_task model_task].include?(kind)

        cached = task_detail_cached?(loop_id, task.fetch("key"))
        detail = task_detail(loop_id, task.fetch("key"))
        pace_task_reads unless cached
        return task.merge("tool_input" => detail["tool_input"]).merge(mainline_listing(task, detail, mainline)) if kind == "tool_task"

        task.merge(detail.slice("request_bytes", "output"))
      end

      # A mainline round's read-class call's own text; nothing from any other tool row.
      def mainline_listing(task, detail, mainline)
        listed = Trace::READ_CLASS.include?(task["tool_name"]) && Array(task["after"]).intersect?(mainline)
        listed ? detail.slice("output") : {}
      end

      # EACH MAINLINE ROUND'S USAGE OFF ONE TRANSCRIPT READ (measured-2, the
      # cache audit of 2026-09-16): the transcript route serves every mainline
      # round's `usage` — the kernel's per-round receipt — newest-first
      # behind a cursor; walked once per trace read, a paced GET per page,
      # to `{task_key => usage}` for the rounds that carry one. A transcript
      # that cannot be read is a warning and a series not read (the sealed
      # request's rule), never a lost trace.
      def transcript_usage(loop_id)
        usage = {}
        before = nil
        loop do
          query = { "limit" => TRANSCRIPT_PAGE_LIMIT }
          query["before"] = before unless before.nil?
          page = agent_api("#{loop_path(loop_id)}/transcript?#{URI.encode_www_form(query)}")
          pace_task_reads
          Array(page["rounds"]).each { |round| usage[round.fetch("task_key")] = round["usage"] if round["usage"] }
          break unless page.dig("pagination", "has_older")

          before = page.dig("pagination", "next_before")
        end
        usage
      rescue StandardError => error
        warn "the transcript of #{loop_id} could not be read: #{error.class}: #{error.message}"
        {}
      end

      # THE CLI'S DEBUG DOOR PRINTS THE ROUTE'S BYTES (drive the CLI): `rho request LOOP KEY` once
      # per run, its entries equal to the sealed request the route served.
      def assert_the_binary_prints_the_sealed_request!(loop_id, sealed)
        return if sealed.nil?

        printed, status = @daemon.cli("request", loop_id, sealed.fetch("task_key"))
        assert_predicate status, :success?, "rho request failed:\n#{printed}"
        agreement = SealedRequest.cli_agrees(printed, sealed)
        assert_equal true, agreement, agreement.to_s
      end

      # THE CLI'S PICTURE IS THE ROUTE'S, byte for byte (the gallery's pin):
      # what a person pastes into a renderer is what the kernel drew.
      def assert_the_binary_prints_the_route_picture!(loop_id, graph)
        printed, status = @daemon.cli("graph", loop_id)
        assert_predicate status, :success?, "rho graph failed:\n#{printed}"
        assert_equal graph.fetch("mermaid"), printed.chomp, "rho graph prints the route's mermaid"
      end

      # THE UNATTENDED WAIT: the loop settled, or parked on a question the run has not answered —
      # a running loop whose `attention.reason` is the kernel's asking word — read off the loop-row
      # poll `await_loop_completion` makes, at its cadence (no new door). An approval park is no ask
      # (rho's `react` denies those and runs on; a plain run in bypass never sees one) and waits as
      # before. UNATTENDED, BUT NOT MUTE: the ACP door has no answer to script either (harbor's runner
      # answers nothing, so the model simply runs on there), so a run that ended at the model's first
      # ask was not comparable to it trial for trial — five trials of one plain floor cell stopped
      # that way and the verification then PASSED three of them. The harness answers the bench's
      # sentence to the first `unattended_answers_per_run` asks and stops at the next
      # (`attend_the_ask!`). THE DEADLINE IS THE WHOLE WAIT'S: an answer never restarts the patience,
      # and a wait that follows another on the same turn (`watch_the_turn`) passes `since:` — the
      # moment the patience started — so it gets only what is left. The row is READ BEFORE THE
      # DEADLINE JUDGES IT: a turn that settled while an earlier wait spent the last seconds (the
      # watch's own clock starts after the CLI boots) is settled, never `stopped: deadline`.
      def await_loop_completion_unattended(loop_id, deadline:, since: Process.clock_gettime(Process::CLOCK_MONOTONIC))
        limit = since + deadline
        loop do
          left = limit - Process.clock_gettime(Process::CLOCK_MONOTONIC)
          if left <= 0
            row = loop_row(loop_id)
            raise never_settled(deadline) unless settled?(row)

            return row
          end

          row = await_loop(loop_id, "settled", deadline: left) { |polled| settled?(polled) || unanswered_ask?(loop_id, polled) }
          return row if settled?(row)

          attend_the_ask!(loop_id, row)
        end
      end

      def never_settled(deadline)
        Stopped.new(Scorecard::DEADLINE, "the loop never settled in #{deadline} s (#{harness_answered.length} harness answer(s))")
      end

      # TURN 1 UNDER `rho watch`, ATTENDED (the `until`, `say_second_turn` and `handoff` drivers): the
      # watch blocks for the task's whole deadline while the spend is watched beside it and the
      # model's ask is attended beside that (`attending_asks`) — the ask answered from the run's one
      # answer, the next the run's `needs_person`. The watch runs on through an answered ask (rho's
      # pin: a watch follows a turn through its asks), so its `background:` and `check` lines cover
      # the whole turn. WHAT THE WATCH PRINTED IS STASHED AS IT RETURNS (`watch_facts` maps the
      # output to the driver's facts), inside the innermost block, which always runs to its end:
      # every stop ends the watch before a wrapper raises, so a stopped record keeps the checks and
      # the background line the watch saw. A watch that gave up is the run's deadline; one that
      # failed any other way is the lane's error, rho's own sentence first; the settle after it has
      # only what is left of the same deadline. RHO'S SENTENCE IS FOUND ANYWHERE IN THE OUTPUT: the
      # CLI's stderr is merged into its stdout (`RhoDaemon#cli`), and rho writes the sentence to the
      # unbuffered stderr while the table rows since the last text delta are still in stdout's
      # buffer, flushed at exit — so the sentence can stand before rows printed after it, or end a
      # line of model text left open. Answers `[watched, settled row]`.
      def watch_the_turn(loop_id, deadline:, watch_facts: ->(_watched) { {} })
        since = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        watched, status = attending_asks(loop_id) do
          watching_spend(loop_id) do
            @daemon.cli("watch", loop_id, "--timeout", deadline.to_s).tap { |printed, _| stash_facts_on_opened(watch_facts.call(printed)) }
          end
        end
        if status.success?
          [watched, await_loop_completion_unattended(loop_id, deadline: deadline, since: since)]
        elsif watched.match?(/rho watch: timed out watching #{Regexp.escape(loop_id)}$/)
          raise never_settled(deadline)
        else
          flunk "rho watch failed (#{status.inspect}): #{watched[/rho watch: [^\n]*/] || watched.lines.last.to_s.strip}\n#{watched}"
        end
      end

      # THE ASK ATTENDANT BESIDE A BLOCKING VERB: the daemon's own row polled every `every` seconds
      # (`polling_beside`, the spend watch's poller), the kernel row read only when that row asks —
      # the pump's read (`attend_followed_ask`). It is joined before the verb's answer is used, so no
      # later wait races it for the run's one answer.
      def attending_asks(loop_id, every: ASK_POLL_SECONDS, &verb)
        polling_beside(every, -> { attend_asks_beside(loop_id) }, &verb)
      end

      # One poll: nil to poll on, else what ends the verb — the `needs_person` stop `attend_the_ask!`
      # already made, or a failure (an unreadable row, a refused answer), for which the run is stopped
      # here so the watch ends now. A failure is the run's error, never a warning: unlike the spend
      # poll's diagnostic read, this one answers the model.
      def attend_asks_beside(loop_id)
        attend_followed_ask(loop_id) if followed(loop_id)&.dig("attention", "reason") == ASKING_REASON
        nil
      rescue Stopped => stop
        stop
      rescue StandardError => failure
        stopped_on(loop_id, failure)
      end

      # The failure, once the run is stopped; a stop that fails too leaves the watch to its timeout
      # and rides the failure's own message, so the attendant never dies with nothing to raise.
      def stopped_on(loop_id, failure)
        stop_the_run!(loop_id)
        failure
      rescue StandardError => refused
        failure.exception("#{failure.message} (and the stop failed: #{refused.class}: #{refused.message})")
      end

      # The daemon's row carries no tasks: the ask's key is the kernel row's.
      def attend_followed_ask(loop_id)
        asked = loop_row(loop_id)
        attend_the_ask!(loop_id, asked) if unanswered_ask?(loop_id, asked)
      end

      # THE BUDGET IS THE RUN'S, never one wait's: the opened Run's `harness_answered` fact, which
      # every wait of the run reads — the woken turn, the person's turn 2, the quiet read — and
      # which `open_turn` and `caught` start afresh. An ask is its loop and its key (a woken loop
      # mints the same keys as the primary), and one the run already answered is the same ask still
      # settling: never answered twice, never a stop.
      def harness_answered = opened.facts.fetch("harness_answered", [])

      def unanswered_ask?(loop_id, row) = asking?(row) && !answered?(loop_id, asked_keys(row).first)

      def answered?(loop_id, key) = harness_answered.any? { |entry| entry["loop"] == loop_id && entry["key"] == key }

      # The ask on `row`, answered from the run's budget, or the run's end once the budget is spent:
      # the ask's loop, its key (the loop's live await addressed to the application) and its prompt
      # (the await's own detail, the answer_ask driver's read) go on the opened Run's facts, then the
      # run is stopped through the cost stop's door — the facts first, so a watch the stop releases
      # returns after them — and the stop is raised. What was asked and what was answered ride the
      # record, so a reader can see it was the harness and not a person.
      def attend_the_ask!(loop_id, row)
        key = asked_keys(row).first
        prompt = key ? task_detail(loop_id, key)["prompt"].to_s : ""
        answered = harness_answered
        unless key && answered.length < unattended_bench.unattended_answers_per_run
          stash_facts_on_opened("asked_key" => key, "asked_loop" => loop_id, "asked_prompt" => prompt[0, 500],
            "harness_answered" => answered)
          stop_the_run!(loop_id)
          raise Stopped.new(NEEDS_PERSON, "the model asked a person (#{key}): #{prompt[0, 200].inspect}")
        end

        stash_facts_on_opened("harness_answered" => answered + [answer_the_ask!(loop_id, key, prompt)])
      end

      # THE HARNESS'S ONE ANSWER, through the verb a person types. A refused answer is the harness's
      # own failure, so it raises as the run's error (a lane bug on the record) and never as the
      # model's `needs_person`; the entry is returned only once the daemon took it, so the record
      # never claims an answer the model did not receive.
      def answer_the_ask!(loop_id, key, prompt)
        text = unattended_bench.unattended_answer_text
        output, status = @daemon.cli("answer", loop_id, key, text)
        raise "the harness could not answer #{key}: #{output.to_s[0, 200]}" unless status.success?

        { "loop" => loop_id, "key" => key, "prompt" => prompt[0, 500], "answer" => text }
      end

      # The bench on disk, read once (`Scorecard`'s precedent): the
      # unattended answer's policy is the BENCH's, never a driver literal,
      # so a changed sentence is a changed digest and a new column. A test
      # sets `@unattended_bench` to pin another policy.
      def unattended_bench = (@unattended_bench ||= Bench.read)

      def asking?(row) = row["status"] == "running" && row.dig("attention", "reason") == ASKING_REASON

      # The asks a loop rests on: its live awaits addressed to the
      # application, off the row already in hand (the kernel's loop row
      # names no keys under `attention`).
      def asked_keys(row)
        row.fetch("tasks").select do |task|
          task["kind"] == "await_task" && !Gallery::TERMINAL_TASK_STATUSES.include?(task["status"]) &&
            task.dig("addressed_to", "role") == "agent_application"
        end.map { |task| task.fetch("key") }
      end

      def await_attention(loop_id, deadline:)
        limit = Process.clock_gettime(Process::CLOCK_MONOTONIC) + deadline
        loop do
          row = followed(loop_id)
          return row if row && row["attention"]
          flunk "the loop finished without ever asking: #{row.fetch("status")}" if row && row["complete"]
          flunk "the model never asked: #{row.inspect}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > limit

          sleep 2
        end
      end

      # A branch the model left detached may ask while it settles: that ask is the run's too,
      # answered from the run's one answer or the run's stop, never a lane error for tasks still live.
      def await_tasks_settled(loop_id, deadline:)
        limit = Process.clock_gettime(Process::CLOCK_MONOTONIC) + deadline
        loop do
          row = loop_row(loop_id)
          attend_the_ask!(loop_id, row) if unanswered_ask?(loop_id, row)
          live = row.fetch("tasks").reject { |t| Gallery::TERMINAL_TASK_STATUSES.include?(t["status"]) }
          return row if live.empty? || row["status"] == "needs_attention"
          raise "tasks still live after #{deadline} s: #{live.map { |t| describe_task(t) }.join(" ")}" if
            Process.clock_gettime(Process::CLOCK_MONOTONIC) > limit

          sleep 3
        end
      end

      def await_mail(conversation, deadline:, origin: "task_result")
        limit = Process.clock_gettime(Process::CLOCK_MONOTONIC) + deadline
        loop do
          found = feed(conversation).find do |item|
            item["type"] == "input_accepted" && item.dig("payload", "origin") == origin
          end
          return found if found
          return nil if Process.clock_gettime(Process::CLOCK_MONOTONIC) > limit

          sleep 3
        end
      end

      # The first turn the feed opened on a loop other than `after`.
      def await_next_turn(conversation, after:, deadline:)
        limit = Process.clock_gettime(Process::CLOCK_MONOTONIC) + deadline
        loop do
          found = feed(conversation).find do |item|
            item["type"] == "turn_status" && item.dig("payload", "run_public_id") &&
              !after.include?(item.dig("payload", "run_public_id"))
          end
          return found.dig("payload", "run_public_id") if found
          raise "the receipt woke no turn" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > limit

          sleep 3
        end
      end

      # THE MANUAL DOOR (the gallery's): the continuation of a round whose
      # tool is still running is queued; a round with no history behind it
      # is refused `nothing_to_compact` and the next one is tried.
      def compact_a_queued_round!(loop_id, deadline:)
        limit = Process.clock_gettime(Process::CLOCK_MONOTONIC) + deadline
        refused = {}
        loop do
          row = loop_row(loop_id)
          raise "the loop settled (#{row["status"]}) before the door armed; refusals: #{refused.inspect}" if settled?(row)

          row.fetch("tasks").select { |t| queued_model_task?(t) && !refused.key?(t["key"]) }.each do |round|
            body, code = agent_api_post("#{loop_path(loop_id)}/tasks/#{round["key"]}/compact", {})
            if code == 202
              puts "door:    compacted #{round["key"]} → #{body["summary_task_key"]}"
              return body
            end
            refused[round["key"]] = body.dig("error", "code") || body.to_s[0, 120]
            puts "door:    #{round["key"]} refused #{code} #{refused[round["key"]]}"
          end
          raise "the door never armed within #{deadline} s; refusals: #{refused.inspect}" if
            Process.clock_gettime(Process::CLOCK_MONOTONIC) > limit

          sleep 1
        end
      end

      def queued_model_task?(task) = task["kind"] == "model_task" && task["status"] == "waiting" && task["key"] != "r1"

      # live_repair's authored halt: two one-second asks with `halt` in one
      # fan, and a round placed after them. Answers the loop id and the
      # resolution tokens the receipt returned.
      def author_halting_loop!(model)
        path = "/agent_api/v1/workspaces/#{workspace_public_id}/runs"
        gates = [1, 2].map do |n|
          { "ask" => { "key" => "gate-#{n}", "prompt" => "gate #{n}", "timeout_ms" => 1000, "on_failure" => "halt" } }
        end
        body, status = agent_api_post(path, { "run" => {
          "steps" => [
            { "parallel" => gates },
            { "model" => { "key" => "work", "prompt" => "Reply with exactly DONE.", "model" => { "model" => model } } },
          ],
          "approval_mode" => "bypass",
        } })
        assert_equal 201, status, "authoring the halting loop: #{body}"
        loop_id = body.dig("run", "public_id")
        tokens = body.dig("receipt", "resolution_tokens") || {}
        assert_equal %w[gate-1 gate-2], tokens.keys.sort, "an authored await is minted a token"
        _, started = agent_api_post("#{path}/#{loop_id}/start", {})
        assert_equal 200, started, "starting the halting loop"
        @daemon.control(:post, "/followers/subscribe", body: { public_id: loop_id })
        [loop_id, tokens]
      end
    end
  end
end
