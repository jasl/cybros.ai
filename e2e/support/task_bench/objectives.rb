require "json"
require_relative "../../../nexus/lib/nexus/tool_registry"
require_relative "../../../nexus/lib/nexus/tool_declarations"
require_relative "declared_set"
require_relative "door"

module E2E
  module TaskBench
    # THE TOOLS' OFFLINE OBJECTIVES (the default is the background and `wait: true` the opt-in):
    # each scores ONE emitted assistant message by PROPERTY, never a correlate — the draw's first
    # message that is not all reads (`Sample`'s two-step frame). Gate 0 asks only whether the
    # model puts two calls in one message at all; T2 is where a `task` call for the suite WITHOUT
    # `wait: true` is measured (its cross-turn half runs through rho in `live_task_mail`); the
    # control is the full-set over-reach control: three greps, no delegation. Delegation
    # is measured by the mail lane's `fan` objective — the `task` text is right that reading three
    # files yourself is a weak model's own work — and by the door objectives (`door_objectives.rb`),
    # scored by the door their message went through (`Door`).
    #
    # A CALL IS SCORED AS THE KERNEL RESOLVES IT: `name` is the spelling the model used, `tool` the
    # kernel's wire name and `arguments` the mapped input, through the kernel's own mapper over the
    # declared set — so one rule reads `task` and `Agent` (`run_in_background` inverted onto `wait`)
    # alike, `spawn_agent` (`wait` omitted) resolves to `spawn`, and a spelling the set never
    # declared is no task.
    module Objectives
      Call = Data.define(:name, :tool, :arguments) do
        def self.from(raw, declared)
          parsed = JSON.parse(raw["arguments"].to_s)
          tool, mapped, = Nexus::ToolDeclarations.resolve_call(declared, raw["name"], Hash.try_convert(parsed) || {})
          new(name: raw["name"], tool: tool, arguments: mapped)
        rescue JSON::ParserError
          new(name: raw["name"], tool: raw["name"], arguments: nil)
        end

        def task? = tool == "delegate_task"
        # A task is in the background unless the resolved call says `wait: true`.
        def background? = task? && !arguments.nil? && arguments["wait"] != true
        def text = arguments.nil? ? "" : JSON.generate(arguments)
        # One mapped argument, nil when the call carried none or unparseable JSON.
        def argument(key) = arguments.nil? ? nil : arguments[key]

        # THE CONVERSATION VERBS: `to` is WHERE — a conversation, the label `spawn` gave it or its
        # public id, on `send`/`status`/`cancel` — and `agent` is WHO, a principal: `spawn`'s
        # answerer (absent for a subagent) and `send`'s optional addressee inside the conversation.
        def spawn? = tool == "spawn"
        def send? = tool == "send"
        def status? = tool == "status"
        def cancel? = tool == "cancel"
        def to = arguments.nil? ? nil : arguments["to"]
        def agent = arguments.nil? ? nil : arguments["agent"]
        def steer? = send? && !arguments.nil? && arguments["steer"] == true
      end

      # `declared` is the set's function definitions (alias facts included). `fixture` is the
      # project a draw's reads are answered from (relative path → bytes; none = an empty project):
      # a two-step objective carries every file its text names, so a scout's read of one is
      # answered and never contradicts the premise it is scored on. `scored_first` marks an
      # objective whose right answer IS reads — G0's reads, the control's greps, TT3's `find` —
      # scored on its first message whatever that holds: answering its reads would score the
      # model's summary instead of its calls. EVERY objective's score leads with the door the
      # message went through (`Door#fields`), so a control's over-reach reads on the same scale as
      # a door objective's choice; the scorer's own properties follow.
      Objective = Data.define(:id, :slug, :text, :scorer, :fixture, :scored_first) do
        def initialize(fixture: {}, scored_first: false, **members) = super

        def score(raw_calls, declared:)
          calls = raw_calls.map { |raw| Call.from(raw, declared) }
          Door.kind(calls).fields.merge(scorer.call(calls, declared), "called" => calls.map(&:name).tally)
        end

        # THE DRAWS OF A RUN, one count for every objective (no per-objective knob): the count, and
        # the indices numbered from the run's first.
        def samples(env = ENV) = Objectives.samples(env)

        def indices(env = ENV)
          first = Objectives.first_sample(env)
          first...(first + samples(env))
        end
      end

      CONFIGS = %w[config/app.yml config/db.yml config/cache.yml].freeze

      module_function

      # `E2E_BENCH_SAMPLES` draws per objective (three unset), numbered from
      # `E2E_BENCH_SAMPLE_FIRST` (one unset): a job split by sample halves numbers its half after
      # the other's, so two directories of one cell never share an index. Anything but a positive
      # integer refuses before a call is paid.
      def samples(env = ENV) = positive(env, "E2E_BENCH_SAMPLES", 3)
      def first_sample(env = ENV) = positive(env, "E2E_BENCH_SAMPLE_FIRST", 1)

      def positive(env, name, default)
        written = env[name].to_s
        count = written.empty? ? default : Integer(written, 10)
        count.positive? ? count : raise(ArgumentError, "#{name} must be a positive integer, got #{written.inspect}")
      end

      GATE_0 = Objective.new(
        id: "G0", slug: "two-calls-in-one-message", scored_first: true,
        text: "Read lib/alpha.rb, lib/bravo.rb and lib/charlie.rb and tell me which of them defines a method called `run`.",
        scorer: lambda do |calls, _declared|
          { "pass" => calls.length >= 2, "calls_in_message" => calls.length }
        end
      )

      OBJECTIVE_2 = Objective.new(
        id: "T2", slug: "background-suite",
        text: "Run the whole test suite with `bin/rails test` — it takes twenty minutes and I do not want to wait on it. " \
              "Meanwhile run `bin/rubocop app` and fix every offence it reports.",
        scorer: lambda do |calls, _declared|
          suite = calls.select { |call| call.task? && call.text.match?(/rails test|test suite|suite/i) }
          background = suite.any?(&:background?)
          lint_direct = calls.any? { |call| call.name == "bash" && call.text.include?("rubocop") }
          one_suite = suite.length <= 1
          no_process = calls.none? { |call| call.name == "start_process" }
          { "pass" => background && lint_direct && one_suite && no_process,
            "suite_in_background" => background, "lint_direct" => lint_direct,
            "one_task_for_the_suite" => one_suite, "no_start_process" => no_process }
        end
      )

      CONTROL = Objective.new(
        id: "T5", slug: "grep-three-control", scored_first: true,
        text: "Which of #{CONFIGS.join(", ")} set `debug` to true?",
        scorer: lambda do |calls, _declared|
          task_zero = calls.none?(&:task?)
          fan = calls.length >= 2
          { "pass" => task_zero && fan, "task_zero" => task_zero,
            "two_calls_in_message" => fan }
        end
      )

      # THE SP ROWS: the `spawn`/`send`/`status`/`cancel` texts are NEW model-facing bytes, measured
      # here by property and never tuned. SP0 a subagent spawn with no `agent` when told to hand
      # work to an agent one can keep talking to; SP1 `agent` naming the peer when the lead lists
      # it; SP2 `send` with `steer: true` when told an agent is going wrong (the reach AND the
      # flag); SP3 IS the task-vs-spawn line — two cells, a one-shot review is a `task` (SP3A) and a
      # persistent reviewer a `spawn` (SP3B); SP4 no `status` polling in the message that started
      # the spawn. The label rides SP2 and the public id SP5 (both spellings have benchmark cells).
      SP0 = Objective.new(
        id: "SP0", slug: "subagent-no-agent",
        text: "Hand the failing test suite in this project to a fresh agent you can keep talking to: it should run " \
              "`bin/rails test`, fix what fails and tell you what it changed. I will have follow-up questions for that agent later.",
        scorer: lambda do |calls, _declared|
          spawns = calls.select(&:spawn?)
          spawned = spawns.any?
          no_agent = spawned && spawns.none? { |call| call.agent.to_s.strip != "" }
          one_spawn = spawns.length <= 1
          no_task = calls.none?(&:task?)
          { "pass" => spawned && no_agent && one_spawn && no_task,
            "spawned" => spawned, "no_agent" => no_agent, "one_spawn" => one_spawn, "no_task" => no_task }
        end
      )

      # THE FILES THE DELEGATION ROWS NAME: the session file SP1's reviewer is pointed at, and the
      # `patch.diff` SP3A, SP3B and TT2 have reviewed, which patches that file — its pre-image
      # beside it. Small and plain: these rows score the delegation, never a finding in them.
      SESSION_FILE = "lib/auth/session.rb".freeze
      SESSION = <<~'RUBY'.freeze
        module Auth
          class Session
            def initialize(store)
              @store = store
            end

            def find(token)
              @store.where("token = '#{token}'").first
            end
          end
        end
      RUBY
      PATCH = <<~'DIFF'.freeze
        diff --git a/lib/auth/session.rb b/lib/auth/session.rb
        --- a/lib/auth/session.rb
        +++ b/lib/auth/session.rb
        @@ -7,5 +7,9 @@ module Auth
             def find(token)
               @store.where("token = '#{token}'").first
             end
        +
        +    def expired?(session)
        +      session.created_at < Time.now - 3600
        +    end
           end
         end
      DIFF
      REVIEWED = { "patch.diff" => PATCH, SESSION_FILE => SESSION }.freeze

      SP1_PEER = "lark".freeze

      SP1 = Objective.new(
        id: "SP1", slug: "peer-by-handle", fixture: { SESSION_FILE => SESSION },
        text: "Agents in this workspace: @lark (security reviewer — reviews diffs for injection and secrets), " \
              "@quill (docs writer). Have the security reviewer look at lib/auth/session.rb and report every finding " \
              "as file:line; I do not need to wait for it.",
        scorer: lambda do |calls, _declared|
          spawns = calls.select(&:spawn?)
          spawned = spawns.any?
          agent_names_the_peer = spawns.any? { |call| call.agent.to_s.delete_prefix("@") == SP1_PEER }
          no_task = calls.none?(&:task?)
          { "pass" => spawned && agent_names_the_peer && no_task,
            "spawned" => spawned, "agent_names_the_peer" => agent_names_the_peer, "no_task" => no_task }
        end
      )

      SP2_LABEL = "migrator".freeze
      # The two config files SP2's premise names, as the move finds them.
      SP2_FILES = {
        "lib/config/legacy.rb" => "module Config\n  class Legacy\n    def self.load(path) = YAML.load_file(path)\n  end\nend\n",
        "lib/config/loader.rb" => "module Config\n  class Loader\n    def self.load(path) = YAML.safe_load_file(path)\n  end\nend\n",
      }.freeze

      SP2 = Objective.new(
        id: "SP2", slug: "steer-going-wrong", fixture: SP2_FILES,
        text: "The agent you spawned under the label `migrator` to move the config loader is rewriting the wrong " \
              "file — it is editing lib/config/legacy.rb instead of lib/config/loader.rb. Correct it right now, " \
              "before it goes further.",
        scorer: lambda do |calls, _declared|
          sends = calls.select(&:send?)
          sent = sends.any?
          steered = sends.any?(&:steer?)
          to_is_the_label = sends.any? { |call| call.to == SP2_LABEL }
          no_cancel = calls.none?(&:cancel?)
          { "pass" => sent && steered && to_is_the_label && no_cancel,
            "sent" => sent, "steered" => steered, "to_is_the_label" => to_is_the_label, "no_cancel" => no_cancel }
        end
      )

      SP3A = Objective.new(
        id: "SP3A", slug: "one-shot-review-is-a-task", fixture: REVIEWED,
        text: "Have another agent review the diff in `patch.diff` for correctness, once, and report its findings " \
              "as file:line. One pass — nothing after that.",
        scorer: lambda do |calls, _declared|
          delegated = calls.any? { |call| call.task? || call.spawn? }
          task_not_spawn = calls.any?(&:task?) && calls.none?(&:spawn?)
          { "pass" => delegated && task_not_spawn, "delegated" => delegated, "task_not_spawn" => task_not_spawn }
        end
      )

      SP3B = Objective.new(
        id: "SP3B", slug: "persistent-reviewer-is-a-spawn", fixture: REVIEWED,
        text: "Set up a reviewer agent for this branch: it reviews `patch.diff` now, and over the next hour I will " \
              "keep sending it new diffs to review and asking it about earlier ones. Report its first findings as file:line.",
        scorer: lambda do |calls, _declared|
          delegated = calls.any? { |call| call.task? || call.spawn? }
          spawn_not_task = calls.any?(&:spawn?) && calls.none?(&:task?)
          { "pass" => delegated && spawn_not_task, "delegated" => delegated, "spawn_not_task" => spawn_not_task }
        end
      )

      MEANWHILE_TOOLS = %w[bash grep read ls glob].freeze

      SP4 = Objective.new(
        id: "SP4", slug: "no-status-polling",
        text: "Hand the suite `bin/rails test` to a fresh agent you can keep talking to; it will take twenty minutes. " \
              "While it runs, count the files under lib/ and answer with the number.",
        scorer: lambda do |calls, _declared|
          spawned = calls.any?(&:spawn?)
          no_status = calls.none?(&:status?)
          worked_meanwhile = calls.any? { |call| MEANWHILE_TOOLS.include?(call.name) }
          { "pass" => spawned && no_status, "spawned" => spawned, "no_status" => no_status, "worked_meanwhile" => worked_meanwhile }
        end
      )

      # This objective distinguishes a `status` tool call from a task-result envelope's `status`
      # attribute in the same message. The call must address the conversation, not the task key or
      # the attribute value; record each confusion separately.
      SP5_CONVERSATION = "3f0c9b2e-5a71-4d5e-9c0d-7a1b2c3d4e5f".freeze
      SP5_ATTRIBUTE_WORDS = %w[r2t1 canceled].freeze

      SP5 = Objective.new(
        id: "SP5", slug: "status-beside-task-result",
        text: "<task_result task=\"r2t1\" status=\"canceled\" conversation=\"#{SP5_CONVERSATION}\">\n" \
              "The review of lib/auth was interrupted before it finished.\n" \
              "</task_result>\n\n" \
              "That reviewer is the agent you spawned for lib/auth. Is anything still running in its conversation " \
              "right now? Find out and tell me.",
        scorer: lambda do |calls, _declared|
          statuses = calls.select(&:status?)
          status_called = statuses.any?
          to_is_the_conversation = statuses.any? { |call| call.to == SP5_CONVERSATION }
          confused = statuses.any? { |call| SP5_ATTRIBUTE_WORDS.include?(call.to.to_s) }
          no_cancel = calls.none?(&:cancel?)
          { "pass" => status_called && to_is_the_conversation && !confused && no_cancel,
            "status_called" => status_called, "to_is_the_conversation" => to_is_the_conversation,
            "confused_with_the_attribute" => confused, "no_cancel" => no_cancel }
        end
      )

      # THE TOOL-TEXT ROWS (TT1–TT5): five model-facing shapes written as designed and left to the
      # paid window — never hand-tuned. Each text is a plain request that names neither the tool nor
      # its parameter, so the row measures whether the model reaches for the shape from the tool's
      # own description; each scorer reads the call's ARGUMENTS (never a correlate), and a shape the
      # kernel or the runner would refuse is its own column. TT1 `ask` with the alternatives in
      # `options` as data (a prompt that lists them in its words is `prompt_only`; `multi: true` is
      # the wrong shape for one pick; a shape the kernel refuses by sentence — a stray key, an
      # empty prompt, non-string options, a non-boolean multi — is `refused_shape` and never data);
      # TT2 `model` on `spawn`/`send`/`delegate_task` equals the catalog id the person named. This
      # scores authored selection, not the executed model identity; TT3 the runner's
      # `find` rather than `bash` running find/fd/ls -R/a glob; TT4 ONE `edit` whose `edits[]`
      # carries the changes as oldText/newText pairs (three calls, a `write` of the whole file, or
      # claude-code's `old_string` pair — `refused_shape`, the runner's own schema refusal, which
      # never passes — are the near-misses); TT5 `send` with `deliver_in` (the delay the person
      # gave) and not `deliver_at`, the kernel's delay grammar beside as `kernel_shape`.
      TT1_TARGETS = %w[staging canary production].freeze

      # The alternatives found among `strings`, case-blind.
      def targets_among(strings) = TT1_TARGETS.select { |target| strings.any? { |s| s.to_s.downcase.include?(target) } }

      # The model's `options`, normalized once where it is read: a list, else none.
      def ask_options(call) = Array.try_convert(call.argument("options")) || []

      # Every entry a string (a list of none is one).
      def strings?(list) = !list.nil? && list.all? { |entry| String.try_convert(entry) }

      # The kernel refuses an `ask` by sentence (`AgentRuns::Asks::Run#refusal_for`):
      # a key beyond prompt/options/multi (`FIELDS`), an empty prompt (`EMPTY_PROMPT`), an
      # `options` that is not all strings (claude-code's `{label, description}` objects,
      # `OPTIONS_INVALID`), a `multi` that is not a boolean (`MULTI_INVALID`). A MIRROR, clause for
      # clause, of a private instance method on an app service this harness does not load; it
      # stands until the kernel exposes that refusal as a callable predicate (a nexus change, the
      # kernel package's), and `test_tt1_wants_the_alternatives_as_ask_options_not_in_the_prompt`
      # pins every clause.
      TT1_ASK_FIELDS = %w[prompt options multi].freeze

      def ask_refused?(call)
        return true if call.arguments.nil? || (call.arguments.keys - TT1_ASK_FIELDS).any?
        return true if String.try_convert(call.argument("prompt")).to_s.strip.empty?

        options = call.argument("options")
        return true unless options.nil? || strings?(Array.try_convert(options))

        ![nil, true, false].include?(call.argument("multi"))
      end

      TT1 = Objective.new(
        id: "TT1", slug: "ask-options-as-data",
        text: "Deploy this build with `bin/deploy <target>`. There are three targets — staging, canary and production — " \
              "and which one is my call, not yours: get my pick first, then deploy there.",
        scorer: lambda do |calls, _declared|
          asks = calls.select { |call| call.tool == "ask" }
          refused = asks.any? { |call| ask_refused?(call) }
          with_data = asks.select { |call| !ask_refused?(call) && targets_among(ask_options(call)).length >= 2 }
          prompt_only = asks.any? { |call| ask_options(call).empty? && targets_among([call.argument("prompt")]).length >= 2 }
          single_choice = with_data.none? { |call| call.argument("multi") == true }
          { "pass" => asks.length == 1 && with_data.any? && single_choice,
            "ask_called" => asks.any?, "options_as_data" => with_data.any?,
            "options_count" => asks.map { |call| ask_options(call).length }.max || 0,
            "prompt_only" => prompt_only, "single_choice" => single_choice, "refused_shape" => refused }
        end
      )

      TT2_REVIEWER = "openrouter/z-ai/glm-5.3".freeze

      TT2 = Objective.new(
        id: "TT2", slug: "reviewer-by-catalog-id", fixture: REVIEWED,
        text: "Have `#{TT2_REVIEWER}` — a stronger reviewer than you — review the diff in `patch.diff` for " \
              "correctness and report its findings as file:line. Start it now; I will read the findings when they arrive.",
        scorer: lambda do |calls, _declared|
          named = calls.select { |call| (call.spawn? || call.send? || call.task?) && call.argument("model").to_s.strip != "" }
          first = named.first
          is_the_id = named.any? { |call| call.argument("model") == TT2_REVIEWER }
          { "pass" => is_the_id, "tool" => first&.tool, "model_named" => !first.nil?,
            "model_value" => first&.argument("model"), "model_is_the_id" => is_the_id,
            "model_on_task" => calls.any? { |call| call.task? && call.argument("model").to_s.strip != "" },
            "delegated" => calls.any? { |call| call.spawn? || call.send? || call.task? } }
        end
      )

      # A bash that searches by name: find, fd, tree, a recursive ls, or a glob.
      TT3_BASH_SEARCH = /\bfind\b|\bfd\b|\btree\b|\bls\b[^|;&]*\s-[a-zA-Z]*R|\*/

      TT3 = Objective.new(
        id: "TT3", slug: "find-over-bash-search", scored_first: true,
        text: "Which files under lib/ end in _job.rb? List them by path.",
        scorer: lambda do |calls, _declared|
          finds = calls.select { |call| call.tool == "find" }
          bash_find = calls.any? { |call| call.tool == "bash" && TT3_BASH_SEARCH.match?(call.argument("command").to_s) }
          pattern = finds.first&.argument("pattern")
          { "pass" => finds.any? && !bash_find, "find_called" => finds.any?, "bash_find" => bash_find,
            "pattern" => pattern, "pattern_names_the_suffix" => pattern.to_s.include?("_job.rb") }
        end
      )

      TT4_FILE = "config/settings.rb".freeze
      TT4_LINES = ["TIMEOUT = 30", "RETRIES = 3", "LOG_LEVEL = :info"].freeze
      # The file's whole content, as the text states it and the fixture holds it.
      TT4_CONTENT = "module Settings\n  #{TT4_LINES.join("\n  ")}\nend\n".freeze

      # The model's `edits`, normalized once where it is read: a list, else none.
      def edit_entries(call) = Array.try_convert(call.argument("edits")) || []

      def edit_pair?(entry)
        pair = Hash.try_convert(entry)
        !pair.nil? && strings?(pair.values_at("oldText", "newText"))
      end

      # THE RUNNER'S OWN SCHEMA LAYER decides a refused edit: rho's `InputSchema.refusal` over the
      # compiled validator its registry holds for `edit` — the check `TaskRun#admit` runs before the
      # handler (and the emulator runs for a read). Unparseable arguments never reach it.
      def edit_refused?(call)
        call.arguments.nil? || !Rho::Runner::InputSchema.refusal(edit_validator, call.arguments).nil?
      end

      def edit_validator
        DeclaredSet.registry.entries.find { |entry| entry.name == Rho::Runner::Tools::Edit::NAME }.validator
      end

      TT4 = Objective.new(
        id: "TT4", slug: "three-edits-in-one-call", fixture: { TT4_FILE => TT4_CONTENT },
        text: "In `#{TT4_FILE}`, whose whole content is\n\n```ruby\n#{TT4_CONTENT}```\n\n" \
              "make three changes: the timeout becomes 60, the retries 5, the log level :warn. Nothing else changes.",
        scorer: lambda do |calls, _declared|
          edits = calls.select { |call| call.tool == "edit" }
          first = edits.first.nil? ? [] : edit_entries(edits.first)
          multi_edit_shape = edits.length == 1 && first.length >= 2 && first.all? { |entry| edit_pair?(entry) }
          write_instead = calls.any? { |call| call.tool == "write" }
          refused_shape = edits.any? { |call| edit_refused?(call) }
          covers = TT4_LINES.all? { |line| first.any? { |entry| Hash.try_convert(entry)&.fetch("oldText", nil).to_s.include?(line) } }
          { "pass" => multi_edit_shape && !write_instead && !refused_shape, "edit_calls" => edits.length, "edits_in_first" => first.length,
            "multi_edit_shape" => multi_edit_shape, "covers_the_three" => covers,
            "write_instead" => write_instead, "refused_shape" => refused_shape }
        end
      )

      # The kernel's delay grammar (`Conversations::Inputs::DeliverAt::IN_SHAPE`,
      # an app service this harness does not load): `90s`, `20m`, `2h`, `1d`.
      TT5_IN_SHAPE = /\A\d{1,9}[smhd]\z/
      TT5_SLEEP = /\bsleep\b/

      TT5 = Objective.new(
        id: "TT5", slug: "deliver-in-not-at",
        text: "Remind me in 20 minutes to restart the staging worker. Just the reminder — do nothing about the worker now.",
        scorer: lambda do |calls, _declared|
          sends = calls.select(&:send?)
          timed = sends.find { |call| !call.argument("deliver_in").nil? }
          deliver_at = sends.any? { |call| !call.argument("deliver_at").nil? }
          value = timed&.argument("deliver_in")
          slept = calls.any? { |call| %w[bash start_process].include?(call.tool) && TT5_SLEEP.match?(call.argument("command").to_s) }
          { "pass" => !timed.nil? && !deliver_at, "send_called" => sends.any?, "deliver_in" => !timed.nil?,
            "deliver_at" => deliver_at, "value" => value, "kernel_shape" => TT5_IN_SHAPE.match?(value.to_s),
            "sleep_instead" => slept }
        end
      )

      # The door objectives reopen this module and are built on `Objective`: loaded here, before
      # `ALL` lists them.
      require_relative "door_objectives"

      ALL = [GATE_0, OBJECTIVE_2, CONTROL, SP0, SP1, SP2, SP3A, SP3B, SP4, SP5, TT1, TT2, TT3, TT4, TT5, *DOOR].freeze

      def find(id) = ALL.find { |objective| objective.id == id } || raise(ArgumentError, "no objective #{id}")
      def ids = ALL.map(&:id)

      # Classify a stored round using the same canonical call names as a live draw.
      def door(raw_calls, declared:) = Door.kind(raw_calls.map { |raw| Call.from(raw, declared) })
    end
  end
end
