require "securerandom"
require_relative "ops/run_routes"
require_relative "ops/events"
require_relative "ops/skill_routes"
require_relative "ops/uploads"
require_relative "ops/files"
require_relative "ops/inference_requests"
require_relative "ops/models"
require_relative "ops/conversations"
require_relative "ops/conversation_history"
require_relative "ops/workspaces"
require_relative "ops/memory"
require_relative "ops/persona"
require_relative "ops/schedules"

module Rho
  module Extensions
    # THE OPERATOR PLANE'S ROUTES: what the page,
    # rho-dev, the harness and `Rho::Core`'s run primitives call — the
    # run read, watched, repaired, paused and deleted; the standalone
    # author; direct inference requests; the uploads and the files. Model discovery
    # also has a product CLI verb. The other surfaces are routes alone:
    # the verbs that once sat beside them (`watch`, `retry`, `approve`, …)
    # are rho-dev's, a development gem a home names, so a product install
    # carries the capability and none of the debugging spellings.
    module Ops
      NAME = "rho.ops".freeze

      # How often a call_tool re-reads its one task while it waits.
      TOOL_CALL_POLL_SECONDS = 1.0

      # A relayed request's answer: the run it ran as, and the task read.
      ToolCallResult = Data.define(:public_id, :detail)

      # A rewind's answer: the child, the turn it forked at with
      # its position, and the SDK's per-Runner restoration outcome (a Hash keyed by `status`).
      RewoundFacts = Data.define(:conversation, :forked_from, :position, :restoration)
      # A regenerate's answer: the turn, the new candidate (nil when the
      # door refused after a restore), and the per-Runner restoration outcome (with
      # `door_refused` when a race after the restore lost the door).
      RegeneratedFacts = Data.define(:turn, :variant, :restoration, :replayed)

      def self.register(api)
        RunRoutes.register(api)
        Events.register(api)
        SkillRoutes.register(api)
        InferenceRequests.register(api)
        Uploads.register(api)
        Files.register(api)
        Models.register(api)
        Conversations.register(api)
        ConversationHistory.register(api)
        Workspaces.register(api)
        Memory.register(api)
        Persona.register(api)
        JobRoutes.register(api)
      end

      # THE RELAY REQUEST: a tool call addressed to ONE runner
      # as a one-task standalone run — the SDK's composition (create →
      # start → poll → stop), answered whole once the task is terminal. The
      # shell is the same list `rho do` authors, re-cut to the seed's own
      # origin (`RunDeclaration.request_rules`): without it `rm -rf /` relayed
      # to rho's runner would dispatch where only the floor stands. The run
      # is never `remember`ed — `rho runs` lists what this daemon follows,
      # and a tool-call run has no local follower; `--server` is the kernel's truth and a
      # one-node run with a tool deliverable reads as the call_tool it is.
      #
      # NO LOCAL ARM, on purpose: the rules that judge a call_tool live in the
      # kernel's stage alone, so a request to this machine's own runner
      # takes the same road — a short-circuit here would be the one path on
      # which a guarded command reaches a handler unjudged. The two READS
      # (`Processes.list`/`log`, the files route) short-circuit instead:
      # a read of this daemon's own table or disk carries no rule.
      #
      # Blocks for the answer: the row's own deadline (the step's clock,
      # else the runner's announced park) plus the sweep's minute bounds it.
      # Answers a `ToolCallResult`, or the member plane's own `Refusal`.
      def self.call_tool(ctx, runner, tool, input, timeout_ms = nil, idempotency_key: SecureRandom.uuid)
        ctx.member_plane do |client, workspace_public_id|
          context = ctx.runs_for(client, workspace_public_id).start_tool_call(
            runner_executor_public_id: runner, tool: tool, input: input, timeout_ms: timeout_ms,
            approval_rules: Rho::RunDeclaration.request_rules(guard: ctx.config.plugin_enabled?("rho.guard"), roots: Rho.protected_roots(ctx.home)),
            idempotency_key: idempotency_key
          )
          ToolCallResult.new(public_id: context.run_public_id, detail: context.wait_for_tool_result(poll: TOOL_CALL_POLL_SECONDS))
        end
      end

      # Fork history, then restore each retained checkpoint on its original
      # Runner through the SDK. Local process guards protect the actual root
      # being restored. The result preserves each Runner's outcome; changing
      # the host's default never redirects historical restoration.
      def self.rewind(ctx, conversation_id, turn_ref, keep_checkpoints: false, title: nil, idempotency_key: SecureRandom.uuid, workspace_public_id: nil)
        ctx.member_plane(host_public_id: conversation_id, **{ workspace_public_id: workspace_public_id }.compact) do |client, workspace_public_id|
          chat = client.workspace(workspace_public_id).conversation(conversation_id)
          conversation = chat.fetch
          guard = local_guard(ctx, conversation)
          next guard if guard

          resolved = resolve_turn(chat.turns, turn_ref)
          next turn_not_found(turn_ref, conversation_id) if resolved.nil?

          turn_public_id, position = resolved
          args = { turn_public_id: turn_public_id, idempotency_key: idempotency_key, restore_checkpoints: !keep_checkpoints,
                   approval_rules: Rho::RunDeclaration.request_rules(guard: ctx.config.plugin_enabled?("rho.guard"), roots: Rho.protected_roots(ctx.home)),
                   restore_guard: restore_guard(ctx) }
          args[:title] = title unless title.nil?
          rewound = chat.rewind(**args)
          RewoundFacts.new(conversation: rewound.conversation.public_id, forked_from: turn_public_id,
            position: position, restoration: rewound.restoration)
        end
      end

      # Restoration precedes regeneration because the input door starts new
      # work. Every required Runner must restore successfully, unless the
      # caller explicitly keeps checkpoints. Partial outcomes and a later
      # input-door refusal remain visible so recovery uses the recorded facts.
      def self.regenerate(ctx, conversation_id, turn_ref, idempotency_key:, keep_checkpoints: false, model: nil, workspace_public_id: nil)
        ctx.member_plane(host_public_id: conversation_id, **{ workspace_public_id: workspace_public_id }.compact) do |client, workspace_public_id|
          workspace = client.workspace(workspace_public_id)
          chat = workspace.conversation(conversation_id)
          # A known acceptance skips every preparatory effect. POST still
          # checks the caller's complete intent; GET alone cannot bless a
          # changed turn or model as a replay. Other read failures are unknown.
          if regeneration_receipt(chat, idempotency_key)
            resolved = turn_ref.match?(/\A\d+\z/) ? resolve_turn(chat.turns, turn_ref) : [turn_ref]
            next turn_not_found(turn_ref, conversation_id) if resolved.nil?

            next door(chat, resolved.first, model, { status: "unchanged" }, idempotency_key)
          end
          conversation = chat.fetch
          resolved = resolve_turn(chat.turns, turn_ref)
          next turn_not_found(turn_ref, conversation_id) if resolved.nil?

          turn_public_id, = resolved
          guard = regenerate_guard(ctx, workspace, chat, conversation, turn_public_id)
          next guard if guard

          active = chat.turns.variants(turn_public_id).active
          if active&.details_pruned_at
            next Rho::Daemon::Refusal.new(status: 409, code: "execution_details_pruned",
              message: "execution details for this turn were removed by the retention policy; start a new turn")
          end
          outcome, refusal = restore_before_door(ctx, chat, active&.runner_effects, keep_checkpoints)
          next refusal if refusal

          door(chat, turn_public_id, model, outcome, idempotency_key)
        end
      end

      def self.regeneration_receipt(chat, idempotency_key)
        chat.turns.regeneration_receipt(idempotency_key: idempotency_key)
      rescue CybrosAgent::Api::NotFound
        nil
      end

      # ---- the pieces the two verbs share ----

      def self.local_guard(ctx, conversation)
        if conversation.busy?
          return Rho::Daemon::Refusal.new(status: 409, code: "conversation_busy",
            message: "a turn is running; stop it first")
        end

        process = ctx.live_process_in(local_root(ctx, conversation))
        return nil if process.nil?

        Rho::Daemon::Refusal.new(status: 409, code: "process_live",
          message: "#{process} is live in that root; stop it first")
      end

      # An environment move does not move old checkpoints. Check the root
      # the resolved store will restore, including after a cache miss.
      def self.restore_guard(ctx)
        ->(runner, captured) do
          next nil unless ctx.own_runner?(runner) && captured.store

          store = ctx.environments.checkpoint_stores(captured.store).first
          "process_live" if store && ctx.live_process_in(store.root)
        end
      end

      def self.regenerate_guard(ctx, workspace, chat, conversation, turn_public_id)
        guard = local_guard(ctx, conversation)
        return guard if guard

        tail = newest_turns(chat.turns, limit: 1).items.last
        unless tail && tail.public_id == turn_public_id
          return Rho::Daemon::Refusal.new(status: 409, code: "branch_required",
            message: "turn #{turn_public_id} is not the tail; regenerate branches only the tail (rewind to it first)")
        end

        needs_attention?(workspace, chat.turns.variants(turn_public_id).active) &&
          Rho::Daemon::Refusal.new(status: 409, code: "run_needs_attention",
            message: "this turn's run needs attention; adjudicate it first (retry or stop)") || nil
      end

      def self.needs_attention?(workspace, active)
        return false unless active&.run_backed?

        workspace.runs.fetch(active.run_public_id).status == "needs_attention"
      rescue CybrosAgent::Api::Error
        false
      end

      # Each checkpoint belongs to its original Runner. Preserve partial outcomes
      # in the refusal so an operator can see which environments were restored.
      def self.restore_before_door(ctx, chat, effects, keep_checkpoints)
        return [{ status: "untouched", runners: [] }, nil] if effects.nil? || effects.untouched?
        return [{ status: "kept", runners: [] }, nil] if keep_checkpoints

        outcome = chat.restore_checkpoints(effects,
          poll: TOOL_CALL_POLL_SECONDS, restore_guard: restore_guard(ctx),
          approval_rules: Rho::RunDeclaration.request_rules(guard: ctx.config.plugin_enabled?("rho.guard"), roots: Rho.protected_roots(ctx.home)))
        return [outcome, nil] if outcome[:status] == "restored"

        [nil, Rho::Daemon::Refusal.new(status: 409, code: "restore_failed",
          message: "checkpoint restoration #{outcome.fetch(:status)}; no regeneration was started", extra: { restoration: outcome })]
      end

      def self.door(chat, turn_public_id, model, outcome, idempotency_key)
        args = model.nil? ? {} : { model: model }
        regeneration = chat.turns.regenerate(turn_public_id, idempotency_key: idempotency_key, **args)
        RegeneratedFacts.new(turn: turn_public_id, variant: regeneration.variant&.public_id, restoration: outcome,
          replayed: regeneration.replayed?)
      rescue CybrosAgent::Api::Conflict => error
        RegeneratedFacts.new(turn: turn_public_id, variant: nil, restoration: outcome.merge(door_refused: error.code), replayed: false)
      end

      # The turn as a public id, or a bare integer read as a position:
      # `[public_id, position]`, or nil for a turn this conversation lacks.
      # Neither read depends on how deep the conversation is: a position
      # is ONE row of the index's window, an id walks the index newest-
      # first a page at a time.
      def self.resolve_turn(turns, ref)
        row = ref.to_s.match?(/\A\d+\z/) ? turn_at(turns, Integer(ref)) : turn_by_id(turns, ref)
        row && [row.public_id, row.position]
      end

      # The row after `position - 1` (the first row for 0): the index's
      # `after_position` is exclusive, so the one-row window lands on the
      # position itself when the conversation has it.
      def self.turn_at(turns, position)
        window = position.zero? ? turns.list(limit: 1) : turns.list(after_position: position - 1, limit: 1)
        window.items.find { |turn| turn.position == position }
      end

      def self.turn_by_id(turns, public_id)
        page = newest_turns(turns)
        loop do
          found = page.items.find { |turn| turn.public_id == public_id }
          return found if found || page.items.length < TURN_PAGE

          page = turns.list(before_position: page.before_position, limit: TURN_PAGE)
        end
      end

      # The NEWEST page: the index's window is `before_position`, exclusive
      # and descending, so a window before the position ceiling is the
      # tail of the conversation whatever its depth.
      def self.newest_turns(turns, limit: TURN_PAGE)
        turns.list(before_position: TURN_POSITION_CEILING, limit: limit)
      end

      def self.turn_not_found(turn_ref, conversation_id)
        Rho::Daemon::Refusal.new(status: 404, code: "turn_not_found",
          message: "no turn #{turn_ref} in #{conversation_id}")
      end

      # The conversation's own runner root when it is THIS daemon's runner
      # (a process this daemon started runs there) — the conversation's
      # RECORD in its store when it has one,
      # the daemon default otherwise; nil for a remote runner or an unbound
      # conversation, so the process guard never false-fires.
      def self.local_root(ctx, conversation)
        runner = conversation.default_runner&.executor_public_id
        return nil unless runner && ctx.own_runner?(runner)

        ctx.environments.binding_for(conversation.public_id, runner: runner)&.root || ctx.environment.root
      end

      # One page of the turns index — its own ceiling (`TurnsController::MAX_LIMIT`;
      # a larger window is the kernel's `parameter_invalid`) — and the
      # largest position the index's window accepts (`TurnsController`'s
      # `window_position` range), before which the newest page lies.
      TURN_PAGE = 100
      TURN_POSITION_CEILING = 2_147_483_647
    end
  end
end
