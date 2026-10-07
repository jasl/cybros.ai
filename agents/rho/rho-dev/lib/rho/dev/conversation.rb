require "digest"

module Rho
  module Dev
    # THE FOUR THAT LEFT THE CORE: `do` opens a
    # conversation and RETURNS its ids — the orchestrator's and e2e's verb,
    # where the product's `run` follows the turn to its end; `say` is a
    # second turn from a terminal, a debugging act; `stop` ends what `do`
    # opened; `adaptations` inspects the pack's resolution. Each is one
    # core primitive and the shared renderer for its document.
    module Conversation
      # The line `do` prints under a turn the kernel has not materialized
      # yet: the verb that follows it, this gem's own.
      PENDING_HINT = "`rho watch` follows it".freeze

      MODEL_DESC = "Which model drives it, as provider/reference (e.g. openrouter/qwen3-coder); " \
                   "default: the daemon's `default_model` setting".freeze

      DO_OPTIONS = {
        model: { type: :string, desc: MODEL_DESC },
        "code-mode": { type: :boolean, desc: "Enable code mode for this conversation (--no-code-mode disables it); default: rho's setting" },
        instructions: { type: :string, desc: "Replace the instructions rho assembles from its tools' own snippets" },
        # THE ROOT SET: `--dir` BINDS
        # — the conversation's environment record, its root; `--also` the
        # rest of the set — beside the descriptive `working_directory`;
        # without it nothing is bound and the shell's directory is
        # described alone. `rho-dev environment` moves it later.
        dir: { type: :string, desc: "Bind the conversation's root: where its relative paths resolve, on its runner " \
                                    "(the record in the conversation's store; without it nothing is bound)" },
        also: { type: :array, desc: "Add a directory to the bound root set (repeatable; with --dir)" },
        runner: { type: :string,
                  desc: "The default Runner for this conversation, by public id; " \
                        "default: the `runner` setting, else this machine's own runner" },
        # Who may see rho's conversation is the core's business; the
        # steward's entry is rho's, not the kernel's (an agent creator's steward is never derived): the person typing
        # the verb can see what it opened.
        restricted: { type: :boolean, default: false,
                      desc: "Open the conversation with default access `none`: only you (your steward, at full), " \
                            "rho, and whom `rho conversation participants add` names can see it" },
        # Who answers is the conversation's own fact, set at the create
        # door. In a room (`rho server --workspace`) any
        # agent member; in rho's dedicated workspace only rho itself.
        agent: { type: :string,
                 desc: "Who answers, as @handle or public id (a member agent of this daemon's workspace); " \
                       "default: rho itself" },
        # A file beside the first message: the path is checked
        # here, staged by the daemon on its member plane, bound to the
        # turn by the kernel.
        attach: { type: :array, desc: "Attach a file to the message (repeatable; type detected from bytes)" },
        # THE APPROVAL KNOB: a per-turn TIGHTENING of
        # rho's own `bypass` on the `direct_reply` input `do` posts — `ask`
        # holds every command for a person and lets the kernel tools run,
        # `rules` refuses every command as data. The field is the core's
        # (`Daemon::HostFollowers#open` reads `approval_mode` off the body, as a
        # raw `POST /conversations` may carry it); the flag is this gem's
        # spelling, a debug knob. `say --approval` is the same knob on a
        # later turn; a turn without it is bypass again.
        approval: { type: :string, enum: %w[ask rules],
                    desc: "Hold this turn's tool calls for `rho approve`/`rho deny` (ask), or refuse every " \
                          "call no rule allows (rules) — a tightening of rho's own bypass, for scripting " \
                          "an approval; the next `rho say` turn is bypass again" },
        # A HOST knob, not a rendering one: `do` prints no model
        # text itself, so this decides whether the DAEMON opens the host's
        # transcript feed at all. `--no-stream` is the scripted lane that
        # does not want a second logical subscription held for it; what a
        # watcher SHOWS is `watch`/`follow`'s own `--reasoning`/`--no-stream`.
        stream: { type: :boolean, default: true,
                  desc: "Follow this conversation's transcript feed, so `rho watch`/`rho follow` can show " \
                        "the reply as it arrives (--no-stream holds no transcript subscription for it)" },
        # The acceptance check (rho.until's two flags on `run`), through the
        # ONE fold (`Rho::Until.fold`).
        until: { type: :string,
                 desc: "A shell command run on the conversation's runner when the model ends its turn; " \
                       "exit 0 completes the run, anything else hands the model the output and another " \
                       "attempt (`rho say` lands with the next check)" },
        attempts: { type: :numeric, default: Rho::Until::DEFAULT_ATTEMPTS,
                    desc: "How many times the --until command may run before the run stops and reports" },
      }.freeze

      SAY_OPTIONS = {
        # No Thor default: `steer` unless `--attach` is given, whose turn
        # is QUEUED (the kernel refuses a picture on a steer); an explicit
        # `--mode steer --attach` is refused before any call, by the
        # kernel's word.
        mode: { type: :string, enum: %w[steer queue],
                desc: "`steer` lands at the running turn's next model boundary (the default); `queue` waits for the turn " \
                      "boundary (the default under --attach)" },
        attach: { type: :array, desc: "Attach a file to the message (repeatable; the turn is queued)" },
        # WHO ANSWERS THIS TURN (group chat): a member agent
        # of the daemon's workspace by @handle or public id, holding full
        # on the conversation; absent, the kernel's default — the running
        # reply's answerer for a steer, else the conversation's own.
        to: { type: :string,
              desc: "Who answers this turn, as @handle or public id (a member agent holding full on the conversation); " \
                    "default: the running reply's answerer for a steer, else the conversation's own" },
        # NOT BEFORE A TIME: the two flags are
        # the kernel's two wire fields (`deliver_in`, `deliver_at`) — rho
        # parses no duration; a naive `--at` is read in this terminal's
        # zone. Either implies `--mode queue`, as `--attach` does; refused
        # on a run.
        in: { type: :string, banner: "DURATION",
              desc: "Deliver after this delay from now (90s, 20m, 2h, 1d); the turn is queued" },
        at: { type: :string, banner: "TIME",
              desc: "Deliver at this ISO 8601 time (with an offset, or in this terminal's zone); the turn is queued" },
        # THE TURN'S TWO FIELDS: the
        # tightening on THIS turn alone, the same two words `do` offers
        # (bypass is rho's own posture: no flag is bypass), and the model
        # ahead of the row's — an editor's picker, spelled from a terminal.
        approval: { type: :string, enum: %w[ask rules],
                    desc: "Hold this turn's tool calls for `rho approve`/`rho deny` (ask), or refuse every " \
                          "call no rule allows (rules); no flag is bypass, rho's own posture" },
        model: { type: :string, desc: "Which model drives this turn, as provider/reference; default: the " \
                                      "conversation's own, then the daemon's `default_model` setting" },
        "code-mode": { type: :boolean, desc: "Set this conversation's code mode (--no-code-mode disables it); omitted keeps its choice" },
      }.freeze

      # The line `say` prints under a turn the kernel has not materialized
      # within the daemon's bound, or one that waits behind a turn in
      # flight: the verb that follows it.
      SAY_PENDING = "pending:   the turn has not started yet; `rho watch` follows it".freeze
      # The same line under a STEER (the daemon answers `pending` with the kernel's `steering`): the words joined the turn
      # in flight, so "not started" would be false of it.
      SAY_STEERING = "pending:   the words joined the turn in flight; `rho watch` follows it".freeze
      # The same line when the daemon saw the kernel's between-turn summary
      # run first (`compaction` on the answer): the
      # summary's run is named as what it is, never printed as `run:`.
      SAY_COMPACTING = "pending:   the turn has not started yet; a compaction summary runs first (run %s); " \
        "`rho watch` follows it".freeze

      def self.register(api)
        api.register_command("do", usage: "do [PROMPT]",
          description: "Open a conversation on this machine, with the tools it serves, and print its ids " \
                       "(`rho watch` follows it; the product's `rho run` follows its own); with no PROMPT, " \
                       "open it with no turn and speak in it with `rho say`",
          options: DO_OPTIONS, &method(:do_turn))
        api.register_command("say", usage: "say ID WORDS",
          description: "Say something to a run or conversation this daemon follows",
          options: SAY_OPTIONS, &method(:say))
        api.register_command("stop", usage: "stop ID [TASK_KEY]",
          description: "Stop a conversation and its unfinished work through the kernel; --host-type run " \
                       "stops exactly that run (--graceful lets running run steps finish); " \
                       "with a task key, cancel one branch the model started and leave the turn running; " \
                       "a conversation this daemon does not follow (a spawned child) is canceled through the kernel",
          options: {
            graceful: { type: :boolean, default: false, desc: "Let running run steps finish before stopping" },
            "host-type": { type: :string, default: "conversation", desc: "conversation (default) or run" },
          },
          &method(:stop))
        api.register_command("adaptations",
          description: "Print the adaptation row a model resolves to (the SDK pack's, or a local row), and the kernel's facts",
          options: { model: { type: :string,
                              desc: "Which model to resolve, as provider/reference; default: the `default_model` setting" } },
          &method(:adaptations))
      end

      class << self
        # `rho do [PROMPT]`: the core opens, the terminal prints the ids —
        # the output contract every paid lane parses `run:` off — and returns. The flags this gem owns land on the
        # body here: the approval mode, the feed knob, the check. With NO
        # PROMPT the core's promptless open: the
        # conversation alone, no turn — printed as the id, the create-door
        # lines the answer carries and the verb that speaks in it.
        def do_turn(cli, (prompt), options)
          cli = Rho::Dev.terminal(cli)
          prompt = nil if prompt.to_s.empty?
          directory = options[:dir] && File.expand_path(options[:dir])
          answer = cli.core.open_conversation(
            prompt: prompt, model: options[:model], instructions: options[:instructions],
            directory: directory, directories: Array(options[:also]).map { |path| File.expand_path(path) },
            runner: options[:runner],
            restricted: options[:restricted], agent: options[:agent], attachments: Array(options[:attach]),
            **(options[:"code-mode"].nil? ? {} : { code_mode: options[:"code-mode"] })
          ) { |body| fold(body, options) }
          return report_opened(cli, answer) if prompt.nil?

          cli.report_turn(answer, pending_hint: PENDING_HINT)
          report_environment(cli, answer)
          answer
        end

        # THE ROOT SET'S LINES under the ids: the set the daemon
        # recorded and, on a runner elsewhere, what that runner was told.
        def report_environment(cli, answer)
          environment = answer["environment"]
          return if environment.nil?

          cli.out.puts "environment:  #{Environment.root_set(environment["root"], environment["directories"])}"
          line = Environment.relayed_line(environment["relayed"])
          cli.out.puts "relayed:      #{line}" if line
        end

        # The promptless answer's lines, in `do`'s own column: the
        # conversation, the access default and the answerer when the verb
        # named them, the runner slot, and what to type next.
        def report_opened(cli, answer)
          public_id = answer.fetch("conversation").fetch("public_id")
          cli.out.puts "conversation: #{public_id}"
          cli.out.puts "access:       #{answer["access"]} (restricted)" if answer["access"]
          named = answer["answered_by"]
          cli.out.puts "agent:        @#{named.fetch("handle")} (#{named.fetch("public_id")})" if named
          if answer.key?("default_runner") && (slot = Rho::RunnerSlot.line(answer["default_runner"]))
            cli.out.puts "runner:       #{slot}"
          end
          report_environment(cli, answer)
          cli.out.puts "next:         rho say #{public_id} \"…\""
          answer
        end

        # The three fields the flags write, in one place: `approval_mode`
        # and `stream` as themselves, the check through the one fold.
        def fold(body, options)
          body = body.merge("approval_mode" => options[:approval]) if options[:approval]
          body = body.merge("stream" => false) if options[:stream] == false
          Rho::Until.fold(body, until: options[:until], attempts: options[:attempts])
        end

        # `rho say ID WORDS`: the queued row, then — on a conversation — the
        # turn and the run the daemon's await answered (the ids a scripted lane parses), or `pending:` past its bound or
        # behind a turn in flight, or `blocked:` on a row the kernel parked
        # (the conversation stands, the verb exits 0 and names the two queue verbs); a run host's answer names none
        # and prints none.
        def say(cli, (public_id, text), options)
          cli = Rho::Dev.terminal(cli)
          attachments = Array(options[:attach])
          timed = !(options[:at].nil? && options[:in].nil?)
          mode = options[:mode] || (attachments.empty? && !timed ? "steer" : "queue")
          document = cli.core.say(public_id, text, mode: mode, to: options[:to], attachments: attachments,
            deliver_at: options[:at], deliver_in: options[:in], model: options[:model],
            approval_mode: options[:approval],
            **(options[:"code-mode"].nil? ? {} : { code_mode: options[:"code-mode"] }))
          cli.report_said(document)
          report_turn_ids(cli, document, public_id)
          document
        end

        def report_turn_ids(cli, document, public_id)
          if document["blocked"]
            input_id = document.dig("input", "public_id")
            cli.out.puts "blocked:   #{document.fetch("blocked")} — the input is parked at its position; " \
                         "`rho inputs #{public_id}` lists it, `rho inputs rm #{public_id} #{input_id}` drops it"
          elsif document["compaction"]
            cli.out.puts(format(SAY_COMPACTING, document.dig("compaction", "run", "public_id")))
          elsif document["pending"]
            cli.out.puts(document.dig("input", "state") == "steering" ? SAY_STEERING : SAY_PENDING)
          elsif document["turn"]
            cli.out.puts "turn:      #{document.fetch("turn").fetch("public_id")}"
            cli.out.puts "run:         #{document.fetch("run").fetch("public_id")}" if document["run"]
          end
        end

        def stop(cli, (public_id, task_key), options)
          cli = Rho::Dev.terminal(cli)
          cli.report_stopped(cli.core.stop(public_id, task_key, force: !options[:graceful],
            host_type: options.fetch(:"host-type", "conversation")))
        end

        def adaptations(cli, _args, options)
          report_adaptation(Rho::Dev.terminal(cli), model: options[:model])
        end

        # `rho adaptations [--model M]`: the row M (else `default_model`) resolves to, from the
        # FILES alone (`core.adaptation_choice`), and its fields; the boot
        # row beside it when M's row differs (the spellings are the
        # boot's); then the kernel's FACTS for M through the daemon when
        # one runs, else `(no daemon)`.
        def report_adaptation(cli, model: nil)
          resolution = cli.core.adaptation_choice(model: model)
          subject = resolution.subject
          resolver = resolution.resolver
          choice = resolution.choice
          cli.out.puts "model:             #{subject || "(no default_model: the default row)"}"
          cli.out.puts "row:               #{choice.long_label}"
          report_row(cli, resolver, choice.row, subject) unless choice.off?
          if subject && resolver.boot_differs?(subject)
            cli.out.puts "boot row:          #{resolver.boot.id} — spellings are the boot's"
          end
          cli.out.puts "facts:             #{facts_line(cli, subject)}"
          choice
        end

        private

          # THE ROW'S FIELDS: its model entries and the one that matched,
          # its style words, its description variants and the recut anchors
          # its entries render against the served templates (the pack's own
          # "which specs, in which order" — `Styles.alias_specs`), the
          # summarizer text (a digest and a size — the bytes are the row
          # file's), and the hints by id.
          def report_row(cli, resolver, row, subject)
            cli.out.puts "models:            #{models_line(row, subject)}"
            cli.out.puts "tool_style:        #{row.tool_style.join(", ")}"
            cli.out.puts "tool_descriptions: #{row.tool_descriptions.length}"
            recuts = CybrosAgent::ModelAdaptations::Styles.alias_specs(row, presets: resolver.pack.presets)
            recuts.select { |spec| spec.key?("recut") }.each do |spec|
              cli.out.puts "  recut:           #{spec.fetch("name")} ← #{spec.dig("recut", "anchor").lines.first.to_s.strip.inspect}"
            end
            cli.out.puts "summarizer:        #{summarizer_line(row)}"
            cli.out.puts "lead_hints:        #{row.lead_hints.length}"
            row.lead_hints.each { |hint| cli.out.puts "  hint:            #{hint.fetch("id")}" }
          end

          # The entries, then the one that matched the model (the most
          # specific); none matches under a pin that names another model's
          # row. A row without entries is `default` — every reference no
          # other row covers — or one only a pin reaches.
          def models_line(row, subject)
            if row.models.empty?
              row.id == CybrosAgent::ModelAdaptations::DEFAULT_ROW ? "(every reference no other row covers)" : "(none: reached by adaptations: #{row.id} only)"
            else
              matched = matched_entry(row, subject)
              matched.nil? ? row.models.join(", ") : "#{row.models.join(", ")} (matched #{matched})"
            end
          end

          def matched_entry(row, subject)
            if subject.nil?
              nil
            else
              reference = CybrosAgent::ModelPattern.reference(subject)
              row.models.filter_map { |entry| CybrosAgent::ModelPattern.specificity(entry, reference)&.then { |rank| [rank, entry] } }
                .max_by(&:first)&.last
            end
          end

          def summarizer_line(row)
            text = row.summarizer_prompt
            return "kernel default" if text.nil?

            "#{Digest::SHA256.hexdigest(text)[0, 12]} #{text.bytesize} B (row)"
          end

          # THE KERNEL'S FACT for the model, off `GET /models` through the
          # daemon (`core.model_facts`): `tool_calls true (catalog)`;
          # `model unavailable or unknown` for a reference it does not list; `(no
          # daemon)` when none runs — the files alone answered the row. A
          # daemon that refuses the read prints its sentence; one that
          # cannot be reached is the verb's failure, as it is for every read.
          def facts_line(cli, model)
            return "(no daemon)" if cli.core.running_daemon.nil?
            return "(no default_model to ask about)" if model.nil?

            facts = cli.core.model_facts(model)
            return "model unavailable or unknown (GET /models lists no #{model})" unless facts["known"]

            "tool_calls #{facts["tool_calls"]} (catalog)"
          rescue Rho::ConnectionError
            raise
          rescue Rho::Error => error
            "unavailable (#{error.message})"
          end
      end
    end
  end
end
