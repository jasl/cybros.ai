require "json"
require_relative "reporting/connection"

module Rho
  module Cli
    # THE RENDERERS: documents in, lines out. Every line the terminal prints for a verb, and
    # nothing a verb does — the verbs are `Rho::Core`'s primitives, composed by `exe/rho`
    # and the extensions' bodies. A renderer READS ONLY THROUGH NAMED CORE PRIMITIVES
    # (`core.task`, `core.asks`, `core.model_facts`, `core.status_document`, the stored
    # facts); it names no route and sends no request
    # (`test/code_style/core_surface_test.rb`). Mixed into `Rho::Cli::Terminal`, which
    # answers `core`, `out` and `home`.
    #
    # THE HINT HOOKS (`test/code_style/shipped_hints_test.rb`):
    # a line's FACT is shared, the verb it names is the surface's. The
    # shipped terminal names the capability — a product home has no
    # `retry`, `answer` or `approve` to type — and rho-dev's `Hints`,
    # extended onto the same terminal, answer the three hooks
    # (`uncertain_hint`, `ask_hint`, `approval_tail`) with its verbs.
    module Reporting
      # A round a provider DECLINED: `refused` by its classifier, `blocked`
      # by a content stop. The kernel's key for the step that failed for it,
      # which the round's own item does not carry (its invocation completed).
      DECLINED = %w[refused blocked].freeze
      DECLINED_KEY = "model_refused".freeze

      # `seen` carries the last `[status, waiting_on]` shown per task, so
      # forty tasks where one moved print one line, and a waiting round
      # prints again only when what holds it moved. Public because `rho
      # follow` renders the pushed stream in the same lines. A BRANCH READS
      # AS A BRANCH: its rounds are `rN` keys too, so a flat list made a
      # branch's forty rounds look like a mainline runaway; a task whose
      # `after` chain reaches a branch root prints indented under the call
      # key that minted it, and mainline lines stay byte-identical.
      def report_tasks(row, seen)
        tasks = Array(row["tasks"])
        remember_edges(tasks, seen)
        statuses = tasks.to_h { |task| [task.fetch("task_key"), task.fetch("status")] }
        tasks.each do |task|
          key = task.fetch("task_key")
          waiting = waiting_on(task, statuses, seen)
          # The claimant's ask for more time reprints the park it extends;
          # a declined round's facts reprint the failure they explain (the
          # pushed stream names the failure a moment before its round).
          shown = [task.fetch("status"), waiting, task["extension_ms"], declined_stand(task)]
          next if seen[key] == shown

          seen[key] = shown
          @out.puts task_line(task, waiting, branch_of(key, seen), refusal_way_on(task, row, seen))
        end
        # A background answer that outlived its turn, delivered to the
        # conversation: once, by the key the model saw; a peer's
        # `send` (origin `agent`) once by its input id; under either the
        # speaker when the row carries one.
        # A SCHEDULED ROW gets its
        # own line — the input and the time the kernel holds — whatever
        # its origin: the follower remembers a timed `person` row too.
        Array(row["delivered_results"]).each do |mail|
          key = mail["task_key"] || mail.fetch("input_public_id")
          next if seen["delivered_results:#{key}"]

          seen["delivered_results:#{key}"] = true
          if mail["deliver_at"]
            @out.puts "scheduled: #{mail.fetch("input_public_id")} for #{mail["deliver_at"]}"
          else
            @out.puts "  #{(mail["origin"] == "agent" ? "sent" : "delivered").ljust(14)} #{key}"
          end
          from = from_line(mail)
          @out.puts from if from
        end
        # THE CHILD TREE: each spawned conversation once, and
        # again when a reply starts or ends there.
        Array(row["children"]).each do |child|
          id = child.fetch("public_id")
          next if seen["child:#{id}"] == child["busy"]

          seen["child:#{id}"] = child["busy"]
          @out.puts child_line(child)
        end
      end

      # The ask prints once and only while it stands: the follower clears the
      # field when a hold is resolved.
      def report_attention(row)
        attention = row["attention"]
        if attention.nil?
          @announced_attention = nil
          return
        end
        reason = attention.fetch("reason")
        return if @announced_attention == reason

        @announced_attention = reason
        keys = Array(attention["blocked_task_keys"])
        @out.puts "  ASKING     #{reason}#{keys.empty? ? "" : " — #{keys.join(", ")}"}"
      end

      # THE DAEMON'S PENDING ROWS on `rho status`: the
      # `ask` and `approval` rows of its own inbox through `core.asks` —
      # the questions, then the held calls — and ONE line naming where a
      # person answers and decides them: the console, the surface every
      # install carries. A daemon that refuses the read (no executor plane
      # yet) gets neither block: the inbox is not a fact it holds.
      def report_asks
        rows = pending_asks
        return if rows.nil?

        asks, approvals = rows.partition { |row| row["kind"] == ASK_KIND }
        @out.puts "asks:      #{asks.empty? ? "(none)" : "#{asks.length} pending"}"
        asks.each { |ask| @out.puts ask_line(ask) }
        @out.puts "approvals: #{approvals.empty? ? "(none)" : "#{approvals.length} pending"}"
        approvals.each { |row| @out.puts approval_line(row) }
        @out.puts CONSOLE_HINT unless rows.empty?
      end

      CONSOLE_HINT = "console:   answer and decide them on the console: `rho console`".freeze

      # Beside the follower's ASKING line: the inbox line for each ask once,
      # the park line for each approval once, while the row stands — an
      # ask with the hint that answers it when the surface has one
      # (`ask_hint`), a park with its tail (`approval_tail`). The ASKING
      # line stays as it was.
      def report_asks_once(seen)
        Array(pending_asks).each do |row|
          mark = "#{row["kind"]}:#{row["run_public_id"]}:#{row["task_key"]}"
          next if seen[mark]

          seen[mark] = true
          if row["kind"] == ASK_KIND
            @out.puts ask_line(row)
            hint = ask_hint(row)
            @out.puts hint if hint
          else
            @out.puts approval_line(row)
          end
        end
      end

      # THE PERSON'S CHECKLIST, transcript-derived: when a `todo_write` call
      # reaches `completed`, ONE task read (`core.task`) reads the call's
      # `tool_input` off the kernel's row and the list prints as a block
      # under the task line that announced it — once per CHANGE, never per
      # poll; an empty or all-completed list prints `(cleared)`; a refused
      # write (`is_error`) changed nothing and prints nothing. The daemon
      # mints no event and keeps no table: the call's NAME is the kernel's
      # `step_started` frame for the key (the snapshot's ring, the follow's
      # stream), and where no frame named a completed call — a host
      # re-adopted after a restart, whose ring is empty — the same task
      # read names it, newest first, until the last `todo_write` is found.
      # The newest list of a frame is the one that stands (a whole-list
      # replace): the older ones in the same frame are stale by
      # construction and cost no read. Every line through `bounded`.
      def report_todo(row, seen)
        remember_tool_names(row, seen)
        seen["todo:run_public_id"] = row["run_public_id"] || row["public_id"] || seen["todo:run_public_id"]
        pending = Array(row["tasks"]).select do |task|
          task["status"] == "completed" && task["kind"] == TOOL_TASK_KIND && !seen["todo:#{task.fetch("task_key")}"]
        end
        pending.reverse_each do |task|
          key = task.fetch("task_key")
          seen["todo:#{key}"] = true
          name = seen["tool:#{key}"]
          next if name && name != TODO_TOOL

          detail = task_detail(seen["todo:run_public_id"], key)
          next if detail.nil?

          seen["tool:#{key}"] = detail["tool_name"]
          next if detail["tool_name"] != TODO_TOOL || detail.dig("result", "is_error")

          print_todo(detail)
          pending.each { |older| seen["todo:#{older.fetch("task_key")}"] = true }
          break
        end
      end

      # A DISPATCHED CALL WAITING FOR A RUNNER THAT IS NOT ONLINE: read off the task's addressee through the task read — a
      # kernel read, for dispatched rows alone, which are the rows nobody
      # has claimed — and printed once per change of the presence word. A
      # daemon without the read prints nothing.
      def report_runner_waits(row, seen)
        run_public_id = row["run_public_id"] || row["public_id"]
        Array(row["tasks"]).each do |task|
          next unless task["status"] == "dispatched"

          address = addressed_to(run_public_id, task.fetch("task_key"))
          next if address.nil? || address["presence"].nil? || address["presence"] == "online"

          word = Rho::RunnerSlot.presence_word(address["presence"], address["last_seen_at"]).sub(" (", ", ").chomp(")")
          mark = "runner:#{task.fetch("task_key")}"
          next if seen[mark] == word

          seen[mark] = word
          @out.puts "  waiting for runner #{address["executor_public_id"]} (#{word})"
        end
      end

      # A check prints once, as it lands.
      def report_checks(row, seen)
        Array(row.dig("until", "checks")).each do |check|
          attempt = check.fetch("attempt")
          next if seen[attempt]

          seen[attempt] = true
          verdict =
            if check["passed"] then "passed"
            elsif check["timed_out"] then "timed out"
            else "exit #{check["exit_status"].inspect}"
            end
          @out.puts "  check #{attempt}/#{check.fetch("attempts")}: #{verdict}"
        end
      end

      # WHAT IS HAPPENING RIGHT NOW: the newest progress
      # frames the daemon holds, each once by its sequence, indented under
      # the KEY that produced it — the task key of a call's tail, the
      # process id of a process's lines, the round or call a kernel frame
      # names — so a busy call reads as its own column beside the table,
      # never as rows of it (the branch-rounds lesson: print under the key
      # before judging a shape). A call's tail prints its newest whole
      # line when it changed; a process prints every line the frame
      # carried; the exit closes it. The kernel's own three print once
      # each: `started · <model> · <bytes> · attempt N` for a round dialled
      # (`(branch)` after a branch round's key), `<tool> <status>` for a
      # call dispatched, run or held, `claimed by <executor>` for a claim.
      def report_frames(row, seen)
        Array(row["frames"]).each do |frame|
          next if frame.fetch("seq") <= seen.fetch("frames", 0)

          seen["frames"] = frame.fetch("seq")
          frame_lines(frame, seen).each { |key, line| @out.puts "  #{key.ljust(14)} │ #{line}" }
        end
      end

      # THE ONE BOUND every model-authored text is printed through (S26):
      # one line, at most the ask width, every control character escaped.
      # Public, so an extension's verb renders a grant's matcher (`rho
      # approve --always`, `rho rules`) the way the park line renders the
      # held command — never a second escaper.
      def bounded(text)
        text = text.to_s
        shown = text.length > ASK_PROMPT_WIDTH ? "#{text[0, ASK_PROMPT_WIDTH]}…" : text
        terminal_text(shown)
      end

      # The same escaper with NO width: a listing whose words are the point
      # (`rho turns`, the replay's mainline) prints them whole on the line.
      def unbounded(text) = terminal_text(text.to_s)

      # THE OUTPUT CONTRACT:
      # `conversation:`, `turn:`, `run:` — the paid lanes parse `^run:`
      # and drive every run-grain verb on it — then the model adaptation
      # row and the line an extension's flags put on the 201 body (a "named leak"). A turn the kernel has not
      # materialized within the daemon's bound prints `pending` and exits
      # 0: the input is queued, the work is not lost. `pending_hint` is the
      # verb that follows it — rho-dev's `do` passes its `rho watch` line;
      # `run` follows the turn itself and prints the bare line (a product
      # home has no verb to name). A pending turn behind the kernel's
      # between-turn summary (`compaction` on the answer) says so and names the summary's run, so nobody
      # follows it as the turn's.
      def report_turn(answer, pending_hint: nil)
        @out.puts "conversation: #{answer.fetch("conversation").fetch("public_id")}"
        if answer["pending"]
          @out.puts "pending:      #{pending_line(answer)}#{pending_hint ? "; #{pending_hint}" : ""}"
          report_adaptations(answer["adaptations"], width: 14)
          report_access(answer)
          report_answerer(answer)
          report_runner(answer, "runner:       ")
          return answer
        end

        @out.puts "turn:         #{answer.fetch("turn").fetch("public_id")}"
        @out.puts "run:         #{answer.fetch("run").fetch("public_id")}" if answer["run"]
        report_adaptations(answer["adaptations"], width: 14)
        report_access(answer)
        report_answerer(answer)
        report_attachments(answer, "attached:     ")
        report_runner(answer, "runner:       ")
        policy = answer["until"]
        @out.puts "until:        #{policy["command"]} (#{policy["attempts"]} checks#{until_where(policy)})" if policy
        answer
      end

      # What `say` answered: the queued input and its state, whom it was
      # addressed to when the daemon resolved one, the staged pictures,
      # the runner slot. Answers the `input` row.
      def report_said(document)
        @out.puts "queued:    #{document.dig("input", "public_id")} (#{input_state(document.fetch("input"))})"
        addressed = document["addressed_to"]
        @out.puts "to:        @#{addressed.fetch("handle")} (#{addressed.fetch("public_id")})" if addressed
        report_attachments(document, "attached:  ")
        report_runner(document, "runner:    ")
        document.fetch("input")
      end

      # What `stop` answered: the host and its status. A conversation nobody
      # here followed — a spawned child — says so; no verb is
      # offered, because `rho attach` takes a RUN id and the person holds
      # the conversation's.
      def report_stopped(stopped)
        @out.puts "stopped:   #{stopped.fetch("public_id")} (#{stopped.fetch("host_type")})"
        @out.puts "status:    #{stopped.fetch("status")}"
        @out.puts "followed:  no — canceled through the kernel" if stopped["followed"] == false
        stopped
      end

      # `rho status`: what a person needs before anything else — am I
      # connected, as whom, and is anything actually running? It answers
      # with or without a daemon, because "nothing is running" is one of
      # the states worth knowing.
      def report_status
        @out.puts "nexus:     #{@home.base_url}"
        daemon = core.running_daemon
        return report_stored if daemon.nil?

        document = report_running(daemon)
        report_asks
        document
      end

      # The printed lines (crit-product M-2): what was revoked, what it leaves
      # behind, and — for a whole disconnect — the connection that ended.
      def report_disconnect(document)
        revoked = Array(document["revoked"])
        if revoked.include?("runner")
          @out.puts "Revoked the runner credential (#{document["runner_executor_public_id"] || Rho::REGISTRATION_IDENTIFIER})."
        end
        unclaimed = document["unclaimed"].to_i
        if unclaimed.positive?
          @out.puts "#{unclaimed} task#{"s" unless unclaimed == 1} addressed to this runner #{unclaimed == 1 ? "is" : "are"} " \
            "unclaimed and will time out; accepted tasks retain their original target."
        end
        if revoked.include?("agent") || (revoked.include?("runner") && document["mode"] == "runner")
          identity = document["identity"] || {}
          @out.puts "Disconnected from #{@home.base_url} as #{identity["user_public_id"] || identity["executor_public_id"]}."
        end
        document
      end

      # The task's header lines, shared by `rho task` and `rho call_tool`.
      def print_task(row)
        @out.puts "task:      #{row.fetch("key")} (#{row.fetch("kind")}) #{row.fetch("status")}"
        @out.puts "tool:      #{row["tool_name"]}" if row["tool_name"]
        @out.puts "input:     #{JSON.generate(row["tool_input"])}" if row["tool_input"]
        @out.puts "asked:     #{row["prompt"]}" if row["prompt"]
        # The choices as data, when the ask gave them.
        if row["options"]
          @out.puts "options:   #{Array(row["options"]).join(" | ")}#{row["multi"] ? " (several may be taken)" : ""}"
        end
        # The detail joins the key: a denial's reason IS the fact a
        # person reads back.
        @out.puts "error:     #{[row.dig("error", "key"), row.dig("error", "detail")].compact.join(" — ")}" if row["error"]
        @out.puts "approval:  #{approval_words(row["approval"])}" if row["approval"]
        # The UI's two fields, when the executor sent them:
        # the header and the model-invisible carrier, as JSON.
        @out.puts "title:     #{row["title"]}" if row["title"]
        @out.puts "metadata:  #{JSON.generate(row["metadata"])}" if row["metadata"]
        # The tool's structured answer, when the executor sent one — the
        # call_tool's read-back of a runner's received binding rides here.
        @out.puts "structure: #{JSON.generate(row["structured_content"])}" if row["structured_content"]
      end

      # `pending, scheduled for 2026-…Z` on a row the kernel holds a time
      # for; the state alone otherwise. Printed by `say` and `inputs edit`.
      def input_state(input)
        input["deliver_at"] ? "#{input["state"]}, scheduled for #{input["deliver_at"]}" : input["state"].to_s
      end

      # `diagram.png (image/png, 184 KiB)` — the descriptor's three facts as
      # the kernel answered them; printed by `say`, `do` and Ops's `inputs`.
      def attachment_line(upload)
        "#{upload.fetch("filename")} (#{upload.fetch("content_type")}, #{human_size(upload.fetch("byte_size"))})"
      end

      def human_size(bytes)
        return "#{bytes} B" if bytes < 1024
        return "#{(bytes / 1024.0).round} KiB" if bytes < 1024 * 1024

        "#{(bytes / (1024.0 * 1024)).round(1)} MiB"
      end

      private

        TOOL_TASK_KIND = "tool_task".freeze
        TODO_TOOL = Rho::Extensions::Todo::Write::NAME
        TODO_LABEL = "todo".freeze
        # A terminal display bound (the ask line's precedent), never a
        # capacity ceiling: the kernel's document bound is the one bound.
        TODO_PRINT_LINES = 50

        # The kernel's `step_started` frame names the call's tool for its
        # key — the one fact the task rows themselves do not carry.
        def remember_tool_names(row, seen)
          Array(row["frames"]).each do |frame|
            next unless frame["type"] == "step_started" && frame["task_key"] && frame["tool_name"]

            seen["tool:#{frame["task_key"]}"] = frame["tool_name"]
          end
        end

        # One task off the kernel through the core; nil for a daemon that
        # refuses the read or lacks the route — nothing to print.
        def task_detail(run_public_id, task_key)
          core.task(run_public_id.to_s, task_key)
        rescue Rho::Error
          nil
        end

        def print_todo(detail)
          list = Rho::Extensions::Todo::List.of(detail.dig("tool_input", "todos"))
          return @out.puts(todo_line(TODO_LABEL, "(cleared)")) if list.empty? || list.finished?

          lines = list.render.lines.map(&:chomp)
          lines.first(TODO_PRINT_LINES).each_with_index do |line, index|
            @out.puts todo_line(index.zero? ? TODO_LABEL : "", bounded(line))
          end
          @out.puts todo_line("", "… and #{lines.length - TODO_PRINT_LINES} more") if lines.length > TODO_PRINT_LINES
        end

        def todo_line(label, text) = "  #{label.ljust(10)} #{text}"

        # The answerer line: printed only when `--agent` named
        # one — rho answering its own conversation is not news.
        def report_answerer(answer)
          named = answer["answered_by"]
          return if named.nil?

          @out.puts "agent:        @#{named.fetch("handle")} (#{named.fetch("public_id")})"
        end

        # The access line: printed only when `--restricted` set a
        # default — the kernel's own `full` is not news.
        def report_access(answer)
          default = answer["access"]
          return if default.nil?

          @out.puts "access:       #{default} (restricted)"
        end

        # Where the check runs: this machine's directory, byte-identical to
        # before; a runner elsewhere by id, with the directory when one is
        # known (the check is a tool step on the bound runner).
        def until_where(policy)
          where = [("on runner #{policy["runner"]}" if policy["runner"]),
                   ("in #{policy["directory"]}" if policy["directory"])].compact.join(" ")
          where.empty? ? "" : ", #{where}"
        end

        # The words under `pending:` — bare, or naming the between-turn
        # summary's run when the daemon saw one run first.
        def pending_line(answer)
          summary = answer["compaction"]
          return "the turn has not started yet" if summary.nil?

          "the turn has not started yet; a compaction summary runs first (run #{summary.fetch("run").fetch("public_id")})"
        end

        # THE ROW A TURN RUNS UNDER: the model's row
        # and its source — `mock (local)`, `glm-5.3 (gem)`, `off` — with the
        # BOOT row beside it when the two differ (`--model` on a model
        # another row covers: the spellings are the boot's and the hints
        # are this row's). `rho status` names the default model's row.
        def report_adaptations(facts, width:)
          return if facts.nil?

          @out.puts "#{"adaptations:".ljust(width)}#{Rho::Adaptations.describe(facts)}"
        end

        # What the daemon staged for the turn: one line per picture,
        # as the kernel described the bytes back — the type is the bytes'.
        def report_attachments(answer, label)
          Array(answer["attachments"]).each do |upload|
            @out.puts "#{label}#{attachment_line(upload)}"
          end
        end

        # THE THREE-STATE RUNNER SLOT, from the
        # daemon's `runner:` — the kernel's word for a FOREIGN executor as
        # the create response or the row carried it: none bound, offline and
        # not yet seen each get a line; online, and a daemon that says
        # nothing, get none.
        def report_runner(answer, label)
          return unless answer.key?("default_runner")

          line = Rho::RunnerSlot.line(answer["default_runner"])
          @out.puts "#{label}#{line}" if line
        end

        def addressed_to(run_public_id, task_key)
          Hash.try_convert(task_detail(run_public_id, task_key)&.dig("addressed_to"))
        end

        # The follower's memory of the graph, in `seen` beside the statuses:
        # `after` is authored once, so a pushed item that names only its
        # parent still finds the chain the snapshot showed; `on_failure`
        # likewise, which a round's own item never carries.
        def remember_edges(tasks, seen)
          tasks.each do |task|
            after = Array(task["after"])
            seen["after:#{task.fetch("task_key")}"] = after unless after.empty?
            seen["on_failure:#{task.fetch("task_key")}"] = task["on_failure"] if task["on_failure"]
          end
        end

        # The call key a branch task hangs from: `after` walked first source
        # first — a consumer's fan edge precedes what a branch forwarded onto
        # it — to a key the kernel minted under a call (`HostFollower::BRANCH_ROOT`).
        # A mainline chain ends at the root round and answers nil.
        def branch_of(key, seen)
          visited = []
          until key.nil? || visited.include?(key)
            match = Rho::HostFollower::BRANCH_ROOT.match(key)
            return match[:call] if match

            visited << key
            key = Array(seen["after:#{key}"]).first
          end
          nil
        end

        # Derived, never read off the item: what a pre-dispatch task's
        # `after` still names as live, by the statuses this frame and the
        # frames before it showed. A source the stream never named is live.
        def waiting_on(task, statuses, seen)
          return nil unless CybrosAgent::Api::TASK_PRE_START_STATUSES.include?(task.fetch("status"))

          live = Array(task["after"]).reject do |source|
            CybrosAgent::Api::TASK_TERMINAL_STATUSES.include?(statuses[source] || seen[source]&.first)
          end
          live.empty? ? nil : live
        end

        # `uncertain` is the one word a person must act on by hand:
        # the tool's executor expired without a result and its effect may
        # have happened, so nothing re-runs it blind — the line says so,
        # and the surface's hook names how it is decided (the console
        # here; rho-dev's two verbs on a terminal it extends).
        def uncertain_hint = "effect uncertain: check, then retry or abandon it on the console"

        # A pending ask's hint line under its row — none on the shipped
        # surface (`report_asks` names the console once); rho-dev's verb.
        def ask_hint(_ask) = nil

        # The park line's tail — bare on the shipped surface; rho-dev's
        # two verbs on a terminal it extends.
        def approval_tail(_row) = ""

        # A step a provider DECLINED and nothing re-ran: what a person does
        # next — the references' two ways on, another model or a new
        # conversation; for blocked content, move past the step and
        # rephrase, because it is re-sent to no model. The capability on the
        # shipped surface; rho-dev's verbs on a terminal it extends.
        def refusal_hint(_run_public_id, _task_key, blocked:)
          return "abandon it on the console, then rephrase: blocked content is never re-sent" if blocked

          "retry it on another model on the console, or start a new conversation"
        end

        # The declined quality of a task that FAILED on it — the stand — and
        # nil otherwise: a declined round on a task that waits again was
        # re-run, and the switch line says so.
        def declined_stand(task)
          quality = task["finish_quality"]
          quality if task.fetch("status") == "failed" && DECLINED.include?(quality)
        end

        # THE WAY ON from a declined stand a person may adjudicate — the
        # kernel's retry rule: a failure an `absorb` policy settled was read
        # by its reader already, and a resolved one is decided; nil there.
        def refusal_way_on(task, row, seen)
          stand = declined_stand(task)
          key = task.fetch("task_key")
          return nil if stand.nil? || task["failure_resolution"]
          return nil if (task["on_failure"] || seen["on_failure:#{key}"]) == "absorb"

          refusal_hint(task["run_public_id"] || row["run_public_id"] || row["public_id"], key, blocked: stand == "blocked")
        end

        def task_line(task, waiting, call, way_on = nil)
          # 14 is the widest status word (`needs_approval`, `awaiting_input`).
          status = task.fetch("status").ljust(14)
          key = task.fetch("task_key")
          detail = error_words(task, way_on)
          detail += "  waiting_on: #{waiting.join(", ")}" if waiting
          detail += "  — #{uncertain_hint}" if task.fetch("status") == "uncertain"
          detail += "  — #{extension_words(task["extension_ms"])}" if task["extension_ms"]
          detail += "  resolved by #{principal_words(task["resolved_by"])}" if task["resolved_by"]
          detail += "  — #{switch_words(task["model_change"])}" if task["model_change"]
          return "  #{status} #{key}#{detail}" if call.nil?

          "    #{status} #{key}  (#{call})#{detail}"
        end

        # `(key)`, and on a declined stand the provider's category, WHO
        # declined, and the way on when a person has one: `(model_refused:
        # cyber — declined by anthropic/claude-opus-5-5; …)`. A null
        # category drops its word.
        def error_words(task, way_on)
          stand = declined_stand(task)
          key = task["error_key"] || (DECLINED_KEY if stand)
          return "" if key.nil?
          return "  (#{key})" if stand.nil?

          category = task["refusal_category"] ? ": #{terminal_text(task["refusal_category"])}" : ""
          verb = stand == "blocked" ? "blocked" : "declined"
          by = task["model"] ? " — #{verb} by #{task["model"]}" : ""
          "  (#{key}#{category}#{by}#{way_on ? "; #{way_on}" : ""})"
        end

        # The kernel moved the step: `switched from X to Y (reason[: category])`.
        def switch_words(change)
          category = change["category"] ? ": #{terminal_text(change["category"])}" : ""
          "switched from #{change["from"]} to #{change["to"]} (#{change["reason"]}#{category})"
        end

        # The speaker under a wrapped row: `@handle`, the
        # kind, and the conversation it was sent from when stamped. A row
        # from before the envelope carries no author and prints nothing new.
        def from_line(mail)
          author = mail["authored_by"]
          return nil unless author.is_a?(Hash)

          words = ["@#{terminal_text(author["handle"])}", "(#{author["kind"]})", mail["sender_conversation_public_id"]]
          "    from: #{words.compact.join(" ")}"
        end

        def child_line(child)
          name = child.fetch("public_id").dup
          facts = [child["label"], child["spawn_node_key"]].compact
          name << " (#{facts.map { |fact| terminal_text(fact) }.join(", ")})" unless facts.empty?
          "  #{"spawned".ljust(14)} #{name} answered by #{child["answering_user_public_id"]} — " \
            "#{child["busy"] ? "replying" : "idle"}"
        end

        # `{kind, public_id}` as the kernel stamps a resolution; a handle
        # when a door ever adds one.
        def principal_words(principal)
          who = principal["handle"] ? "@#{terminal_text(principal["handle"])}" : principal["public_id"]
          "#{principal["kind"]} #{who}"
        end

        # The inbox through the core; nil for a daemon that refuses the read
        # or answers something that is not the inbox — a scripted status
        # double, or a daemon loaded without the Ops routes, whose webui
        # answers the unrouted GET with a page (`rho status` is a core verb;
        # the inbox read is the run primitives'): nothing to print.
        def pending_asks
          core.asks
        rescue Rho::Error
          nil
        end

        # "runner asked for N more minutes": the claimant's own extension
        # (`task_deadline_extended`), in the unit a person reads a park in.
        def extension_words(milliseconds)
          ms = Integer(milliseconds)
          if ms >= 60_000
            minutes = (ms / 60_000.0).round
            "runner asked for #{minutes} more minute#{minutes == 1 ? "" : "s"}"
          else
            "runner asked for #{(ms / 1000.0).round} more seconds"
          end
        end

        ASK_PROMPT_WIDTH = 80
        ASK_KIND = "ask".freeze

        def ask_line(ask)
          "  #{"ask".ljust(10)} #{ask["run_public_id"]} #{ask["task_key"]}  \"#{bounded(ask["prompt"])}\""
        end

        # THE PARK LINE: the tool, an argument excerpt — a
        # person decides ONE call whose arguments they have read, so the
        # key is on the line — and the surface's tail (`approval_tail`).
        def approval_line(row)
          run_id = row["run_public_id"]
          key = row["task_key"]
          "  #{"approval".ljust(10)} #{run_id} #{key}  #{row["tool_name"]} \"#{bounded(argument_excerpt(row))}\"" \
            "#{approval_tail(row)}"
        end

        # The command when the tool takes one (rho's two command tools — rho
        # knows its own tools' argument names; the kernel never reads them),
        # else the arguments as JSON.
        def argument_excerpt(row)
          input = row["tool_input"]
          command = input.is_a?(Hash) ? input["command"] : nil
          command.is_a?(String) ? command : JSON.generate(input)
        end

        def approval_words(fact)
          origin = fact.fetch("origin")
          return origin unless fact["decided_by"]

          "#{origin} (#{fact["decided_by"]}) at #{fact["decided_at"]}"
        end

        def frame_lines(frame, seen)
          payload = frame["payload"] || {}
          case frame["type"]
          when "executor_progress"
            key = frame.fetch("task_key")
            line = payload["text_tail"].to_s.lines.map(&:chomp).reject(&:empty?).last
            return [] if line.nil? || seen["frame:#{key}"] == line

            seen["frame:#{key}"] = line
            [[key, line]]
          when "process_output"
            key = frame.fetch("process_id")
            lines = Array(payload["lines"]).map { |line| [key, line] }
            lines << [key, "exited #{payload["exit"].inspect}"] if payload.key?("exit")
            lines
          when "round_started"
            key = frame.fetch("task_key")
            key = "#{key} (branch)" if payload["mainline"] == false
            [[key, "started · #{payload["model"]} · #{Rho::Runner::Truncation.format_size(payload["request_bytes"].to_i)} " \
                   "· attempt #{payload["attempt"]}"]]
          when "step_started"
            [[frame.fetch("task_key"), "#{frame["tool_name"]} #{payload["status"]}"]]
          when "step_claimed"
            [[frame.fetch("task_key"), "claimed by #{frame["executor_public_id"]}"]]
          else
            []
          end
        end
    end
  end
end
