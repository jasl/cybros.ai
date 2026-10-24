require_relative "../until"
require_relative "../until/recovery"

module Rho
  module Extensions
    # The acceptance check: a shell command whose exit status is the whole verdict.
    # `:turn_author` validates the policy and joins its paragraph to the
    # turn's lead and carries the check and hold on the input. Nexus accepts
    # them atomically with its first model round. `:turn_follow` binds the
    # original Run and builds the gate that reads the verdict.
    module Until
      NAME = "rho.until".freeze

      # The two flags on `run`, the one conversation verb a product home
      # has, through the one fold (`Rho::Until.fold`; rho-dev's `do`
      # declares the same two and calls the same fold). The desc names no
      # verb: the product home `run` ships on has none for a second message.
      FLAGS = {
        until: { type: :string,
                 desc: "A shell command run on the conversation's runner when the model ends its turn; " \
                       "exit 0 completes the run, anything else hands the model the output and another " \
                       "attempt (the next message lands with the next check)" },
        attempts: { type: :numeric, default: Rho::Until::DEFAULT_ATTEMPTS,
                    desc: "How many times the --until command may run before the run stops and reports" },
      }.freeze
      CONVERSATION_VERB = "run".freeze

      def self.register(api)
        api.register_flags(CONVERSATION_VERB, **FLAGS) do |body, options|
          Rho::Until.fold(body, until: options[:until], attempts: options[:attempts])
        end
        api.on(:turn_author) { |draft, ctx| author(draft, ctx) }
        api.on(:turn_follow) do |run_public_id, notes, ctx|
          notes[NAME] && follow(run_public_id, notes[NAME], ctx)
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
        steps = Rho::Until.check_steps(1,
          command: policy.command, directory: policy.directory, timeout_seconds: clamp(ctx),
          runner: policy.runner, executor_context: draft.body.fetch("executor_contexts").fetch(policy.runner))
        draft.with(
          lead: [draft.lead, paragraph].reject(&:empty?).join("\n\n"),
          steps: (draft.steps || []) + steps,
          notes: draft.notes.merge(NAME => policy.with(seed: seed(draft, ctx.compaction_policy)).to_h.merge("run_public_id" => nil))
        )
      end

      # `compaction` is the daemon's DECLARED policy — the settings',
      # downgraded where this address cannot serve it (the same reader the profile declaration uses) — so a check's round compacts
      # the way the turn's rounds do and never names a delegate nobody
      # announced.
      def self.seed(draft, compaction)
        seed = { "model" => { "model" => draft.body.fetch("model") },
                 "compaction" => compaction, "executor_contexts" => draft.body.fetch("executor_contexts") }
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
      # directory does not exist" on the row, and the run is given back
      # with that sentence.
      def self.policy_for(body, environment, ctx)
        given = body["until"]
        return nil if given.nil?

        given = Hash.try_convert(given)
        return Rho::Daemon::Refusal.malformed("until must be an object with a command") if given.nil?

        command = given["command"].to_s
        return Rho::Daemon::Refusal.malformed("until.command is required") if command.strip.empty?

        attempts = Integer(given.fetch("attempts", Rho::Until::DEFAULT_ATTEMPTS), exception: false)
        unless attempts&.between?(1, Rho::Until::MAX_ATTEMPTS)
          return Rho::Daemon::Refusal.malformed("until.attempts must be between 1 and #{Rho::Until::MAX_ATTEMPTS}")
        end

        runner = ctx.runner_selection(body)
        context = body.fetch("executor_contexts", {})[runner]
        root = context&.dig(Rho::Env::Environment::CONTEXT_KEY, "root")
        return Rho::Daemon::Refusal.malformed("until requires a concrete Runner and captured environment") unless runner && root

        directory = body["working_directory"].to_s
        directory = root if directory.empty?
        Rho::Until::Policy.new(command: command, attempts: attempts, runner: runner, seed: {}, directory: directory)
      end

      # The input already accepted the check and hold before its first model
      # round could complete. Re-adoption only restores the gate; its later
      # append resolves the hold within the existing authoring trust domain,
      # so the initial append receipt needs no separate recovery or storage.
      def self.follow(run_public_id, note, ctx)
        bound_run = note.fetch("run_public_id")
        return nil if bound_run && bound_run != run_public_id

        return gate(run_public_id, Rho::Until::Policy.from_h(note), ctx) if bound_run

        result = ctx.member_plane(host_public_id: run_public_id) do |client, workspace_public_id|
          workspace = client.workspace(workspace_public_id)
          run = workspace.run(run_public_id).fetch
          next unless run.turn&.conversation_public_id

          Rho::Until::Recovery.new(owner_public_id: ctx.own_user_public_id, timeout_seconds: clamp(ctx), log: ctx.log)
            .call(workspace: workspace, run_public_id: run_public_id, conversation_public_id: run.turn.conversation_public_id,
              turn_public_id: run.turn.public_id, advance: false)
        end
        result if result in Rho::Until::Gate
      rescue CybrosAgent::Error, Rho::StateError => error
        ctx.log&.warn("until.bind_failed", run: run_public_id, error_class: error.class.name,
          detail: CybrosAgent::Redaction.call(error.message))
        nil
      end

      def self.gate(run_public_id, policy, ctx)
        Rho::Until::Gate.new(policy: policy, run_public_id: run_public_id, log: ctx.log,
          timeout_seconds: clamp(ctx))
      end

      # THE OPERATOR WHO SET THE GOAL BOUNDS ITS CHECK, on their own runner
      # or another's: the settings' bash timeout under the tool's ceiling.
      # (A runner's own default is for the model's calls.)
      def self.clamp(ctx)
        [ctx.config.plugin_configuration("rho.coding").fetch("bash_timeout_seconds"), Rho::Env::Tools::Bash::MAX_TIMEOUT_SECONDS].min
      end
    end
  end
end
