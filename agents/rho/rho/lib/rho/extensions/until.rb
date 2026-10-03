require_relative "../until"

module Rho
  module Extensions
    # The acceptance check: a shell command whose exit status is the whole verdict.
    # `:turn_author` validates the policy and joins its paragraph to the
    # turn's lead; `:turn_follow`, fired once the turn's backing loop is
    # known, hangs the check — a `bash` TOOL step the kernel addresses to
    # the host's bound runner, own or elsewhere — and its hold below the
    # kernel's first round, and builds the gate that reads the verdict off
    # the settled row.
    module Until
      NAME = "rho.until".freeze

      # The two flags on `run`, the one conversation verb a product home
      # has, through the one fold (`Rho::Until.fold`; rho-dev's `do`
      # declares the same two and calls the same fold). The desc names no
      # verb: the product home `run` ships on has none for a second message.
      FLAGS = {
        until: { type: :string,
                 desc: "A shell command run on the conversation's runner when the model ends its turn; " \
                       "exit 0 completes the loop, anything else hands the model the output and another " \
                       "attempt (the next message lands with the next check)" },
        attempts: { type: :numeric, default: Rho::Until::DEFAULT_ATTEMPTS,
                    desc: "How many times the --until command may run before the loop stops and reports" },
      }.freeze
      CONVERSATION_VERB = "run".freeze

      def self.register(api)
        api.register_flags(CONVERSATION_VERB, **FLAGS) do |body, options|
          Rho::Until.fold(body, until: options[:until], attempts: options[:attempts])
        end
        api.on(:turn_author) { |draft, ctx| author(draft, ctx) }
        api.on(:turn_follow) do |loop_public_id, notes, ctx|
          notes[NAME] && follow(loop_public_id, notes[NAME], ctx)
        end
      end

      # The paragraph joins the lead — the developer-role entry every round
      # of the turn opens with. The seed the policy keeps is the model step's
      # surface every `work-N` round copies: round 1 is the kernel's, minted
      # from the profile's declaration narrowed by the input's tool names,
      # so the seed is the
      # TURN's surface — the resolved model, the draft's tools, the
      # profile's declared compaction — and carries no instructions (the paragraph rides the lead, not the round).
      def self.author(draft, ctx)
        policy = policy_for(draft.body, draft.environment, ctx)
        return draft if policy.nil?
        return policy if policy in Rho::Daemon::Refusal

        paragraph = Rho::Until.paragraph(command: policy.command, attempts: policy.attempts,
          directory: policy.directory)
        draft.with(
          lead: [draft.lead, paragraph].reject(&:empty?).join("\n\n"),
          notes: draft.notes.merge(NAME => policy.with(seed: seed(draft, ctx.compaction_policy)).to_h.merge("loop_public_id" => nil))
        )
      end

      # `compaction` is the daemon's DECLARED policy — the settings',
      # downgraded where this address cannot serve it (the same reader the profile declaration uses) — so a check's round compacts
      # the way the turn's rounds do and never names a delegate nobody
      # announced.
      def self.seed(draft, compaction)
        seed = { "model" => { "model" => draft.body.fetch("model") },
                 "compaction" => compaction }
        # The kernel refuses `tools: []` as a typo'd intent.
        seed["tools"] = draft.tools unless draft.tools.empty?
        seed
      end

      # THE DIRECTORY IS FROZEN HERE — `rho env` may move the root between
      # rounds, and the check must run where the model was told it runs —
      # AND IT IS A CLAIM, NOT A CHECK: the check runs where the tree is.
      # Own runner (the Draft carries an environment): the local working
      # directory or root. A runner elsewhere (no environment): the
      # person's `--dir`, a path they assert exists where the runner is;
      # else the root that runner ANNOUNCED; else nothing, and bash runs
      # in the runner's root. A wrong path is bash's own "Working
      # directory does not exist" on the row, and the loop is given back
      # with that sentence.
      def self.policy_for(body, environment, ctx)
        given = body["until"]
        return nil if given.nil?
        return Rho::Daemon::Refusal.malformed("until must be an object with a command") unless given.is_a?(Hash)

        command = given["command"].to_s
        return Rho::Daemon::Refusal.malformed("until.command is required") if command.strip.empty?

        attempts = Integer(given.fetch("attempts", Rho::Until::DEFAULT_ATTEMPTS), exception: false)
        unless attempts&.between?(1, Rho::Until::MAX_ATTEMPTS)
          return Rho::Daemon::Refusal.malformed("until.attempts must be between 1 and #{Rho::Until::MAX_ATTEMPTS}")
        end

        if environment
          Rho::Until::Policy.new(command: command, attempts: attempts, runner: nil, seed: {},
            directory: environment.working_directory || environment.root)
        else
          runner = ctx.runner_selection(body)
          asserted = body["working_directory"].to_s
          directory = asserted.empty? ? ctx.remote_runner(runner)&.environment&.dig("root") : asserted
          Rho::Until::Policy.new(command: command, attempts: attempts, runner: runner, seed: {}, directory: directory)
        end
      end

      # THE CHECK, AFTER THE FACT: the kernel authored `r1`, so the check
      # and its hold are placed after it through the loop's own door once
      # the loop exists, while `r1` still runs (a step hangs below a live
      # round) — tolerant of a loop that settled first (round 1 without a
      # call completes in a second on a fake), which is a turn that simply
      # completes, logged, with no gate. A re-adoption replays the same key
      # and the kernel answers the standing receipt.
      def self.follow(loop_public_id, note, ctx)
        return nil if note["loop_public_id"] && note["loop_public_id"] != loop_public_id

        policy = nil
        hung = ctx.member_plane(host_public_id: loop_public_id) do |client, workspace_public_id|
          loops = ctx.loops_for(client, workspace_public_id)
          note = bind(loop_public_id, loops, client.workspace(workspace_public_id), ctx) unless note["loop_public_id"]
          next false if note.nil?

          policy = Rho::Until::Policy.from_h(note)
          loops.agent_loop(loop_public_id).append(
            steps: Rho::Until.check_steps(1, command: policy.command, directory: policy.directory,
              timeout_seconds: clamp(ctx)),
            idempotency_key: Rho::Until.idempotency_key(loop_public_id, 1, "seed")
          )
          true
        end
        return nil unless hung == true

        gate(loop_public_id, policy, ctx)
      rescue CybrosAgent::Api::Conflict => error
        ctx.log&.warn("until.too_late", agent_loop: loop_public_id, code: error.code,
          detail: CybrosAgent::Redaction.call(error.message))
        nil
      end

      # Bind the first materialized loop before installing its check. A
      # conversation outlives this goal; later turns must never inherit it.
      # Old notes have no pending marker, so only an existing check/hold pair
      # proves that this loop is the one whose gate may be restored.
      def self.bind(loop_public_id, loops, workspace, ctx)
        host = ctx.host_of(loop_public_id, loops)
        return nil unless host.outlives_turn?

        hosted = host.context(workspace)
        document = Rho::HostPolicy.new(store: -> { hosted.store_entries },
          owner_public_id: ctx.own_user_public_id, host_public_id: host.public_id)
        snapshot = document.read
        note = snapshot&.notes&.fetch(NAME, nil)
        return nil if note.nil?
        return note["loop_public_id"] == loop_public_id ? note : nil if note["loop_public_id"]

        proven = if note.key?("loop_public_id")
          first_loop(hosted) == loop_public_id
        else
          (%w[check-1 hold-1] - loops.agent_loop(loop_public_id).fetch.tasks.map(&:key)).empty?
        end
        unless proven
          reason = note.key?("loop_public_id") ? "pending_loop_unproven" : "legacy_loop_unproven"
          ctx.log&.warn("until.not_restored", agent_loop: loop_public_id, reason: reason)
          return nil
        end

        updated = document.change(notes: snapshot.notes.merge(NAME => note.merge("loop_public_id" => loop_public_id)))
        ctx.remember(host, workspace: hosted.workspace_public_id, notes: updated.notes)
        updated.notes.fetch(NAME)
      rescue CybrosAgent::Error, Rho::StateError => error
        ctx.log&.warn("until.bind_failed", agent_loop: loop_public_id, error_class: error.class.name,
          detail: CybrosAgent::Redaction.call(error.message))
        nil
      end

      # Until is authored with a new conversation's first input. Its original
      # materialization remains the authority if binding failed, even when a
      # later turn or a regenerated variant is now active. Queue positions
      # are reused, so the proof needs contiguous replay from sequence 1;
      # a retained suffix cannot identify the conversation's first input.
      def self.first_loop(hosted)
        after = nil
        sequence = 0
        turn_public_id = nil
        loop do
          page = hosted.events(after: after, limit: 100)
          return nil if page.gap_after?(sequence)

          page.each do |item|
            payload = item.payload
            if item.type == "input_materialized" && payload["queue_position"] == 0
              turn_public_id = payload.fetch("turn_public_id")
            elsif turn_public_id && item.type == "turn_status" && payload["turn_public_id"] == turn_public_id
              return payload["agent_loop_public_id"]
            end
          end
          return nil if page.caught_up?

          after = page.next_after
          sequence = page.last_sequence
        end
      end

      def self.gate(loop_public_id, policy, ctx)
        Rho::Until::Gate.new(policy: policy, loop_public_id: loop_public_id, log: ctx.log,
          timeout_seconds: clamp(ctx))
      end

      # THE OPERATOR WHO SET THE GOAL BOUNDS ITS CHECK, on their own runner
      # or another's: the settings' bash timeout under the tool's ceiling.
      # (A runner's own default is for the model's calls.)
      def self.clamp(ctx)
        [ctx.config.bash_timeout_seconds, Rho::Runner::Tools::Bash::MAX_TIMEOUT_SECONDS].min
      end
    end
  end
end
