require "securerandom"
require_relative "ops/loop_routes"
require_relative "ops/events"
require_relative "ops/skill_routes"
require_relative "ops/uploads"
require_relative "ops/files"
require_relative "ops/one_shots"
require_relative "ops/models"
require_relative "ops/conversations"
require_relative "ops/conversation_history"
require_relative "ops/workspaces"
require_relative "ops/memory"
require_relative "ops/scheduled_jobs"

module Rho
  module Extensions
    # THE OPERATOR PLANE'S ROUTES: what the page,
    # rho-dev, the harness and `Rho::Core`'s loop primitives call — the
    # loop read, watched, repaired, paused and deleted; the standalone
    # author; the one-shot lane; the uploads and the files. Model discovery
    # also has a product CLI verb. The other surfaces are routes alone:
    # the verbs that once sat beside them (`watch`, `retry`, `approve`, …)
    # are rho-dev's, a development gem a home names, so a product install
    # carries the capability and none of the debugging spellings.
    module Ops
      NAME = "rho.ops".freeze

      # How often a relay re-reads its one task while it waits.
      RELAY_POLL_SECONDS = 1.0

      # A relayed request's answer: the loop it ran as, and the task read.
      Relayed = Data.define(:public_id, :detail)

      # A rewind's answer: the child, the turn it forked at with
      # its position, and the SDK's world OUTCOME (a Hash keyed by `status`).
      RewoundFacts = Data.define(:conversation, :forked_from, :position, :world)
      # A regenerate's answer: the turn, the new candidate (nil when the
      # door refused after a restore), and the world outcome (with
      # `door_refused` when a race after the restore lost the door).
      RegeneratedFacts = Data.define(:turn, :variant, :world)

      def self.register(api)
        LoopRoutes.register(api)
        Events.register(api)
        SkillRoutes.register(api)
        OneShots.register(api)
        Uploads.register(api)
        Files.register(api)
        Models.register(api)
        Conversations.register(api)
        ConversationHistory.register(api)
        Workspaces.register(api)
        Memory.register(api)
        JobRoutes.register(api)
      end

      # THE RELAY REQUEST: a tool call addressed to ONE runner
      # as a one-task standalone loop — the SDK's composition (create →
      # start → poll → stop), answered whole once the task is terminal. The
      # shell is the same list `rho do` authors, re-cut to the seed's own
      # origin (`LoopRequest.request_rules`): without it `rm -rf /` relayed
      # to rho's runner would dispatch where only the floor stands. The loop
      # is never `remember`ed — `rho loops` lists what this daemon follows,
      # and a request is not a run; `--server` is the kernel's truth and a
      # one-node loop with a tool deliverable reads as the relay it is.
      #
      # NO LOCAL ARM, on purpose: the rules that judge a relay live in the
      # kernel's stage alone, so a request to this machine's own runner
      # takes the same road — a short-circuit here would be the one path on
      # which a guarded command reaches a handler unjudged. The two READS
      # (`Processes.list`/`log`, the files route) short-circuit instead:
      # a read of this daemon's own table or disk carries no rule.
      #
      # Blocks for the answer: the row's own deadline (the step's clock,
      # else the runner's announced park) plus the sweep's minute bounds it.
      # Answers a `Relayed`, or the member plane's own `Refusal`.
      def self.relay(ctx, runner, tool, input, timeout_ms = nil, idempotency_key: SecureRandom.uuid)
        ctx.member_plane do |client, workspace_public_id|
          context = ctx.loops_for(client, workspace_public_id).request(
            runner_executor_public_id: runner, tool: tool, input: input, timeout_ms: timeout_ms,
            approval_rules: Rho::LoopRequest.request_rules(roots: Rho.protected_roots(ctx.home)),
            idempotency_key: idempotency_key
          )
          Relayed.new(public_id: context.agent_loop_public_id, detail: context.request_result(poll: RELAY_POLL_SECONDS))
        end
      end

      # REWIND: the SDK's composition behind the daemon's member
      # credential — fork at the turn, read the fork answer's `world`,
      # restore on the child's bound runner, poll. The local guards are
      # rho's: an active turn of THIS conversation, and a live
      # process this daemon started in the conversation's own runner root;
      # they refuse BEFORE any fork. The restore's rules are the ones `rho
      # do` authors, re-addressed to the seed's origin — the relay's shell.
      def self.rewind(ctx, conversation_id, turn_ref, keep_world: false, title: nil, idempotency_key: SecureRandom.uuid, workspace_public_id: nil)
        ctx.member_plane(host_public_id: conversation_id, **{ workspace_public_id: workspace_public_id }.compact) do |client, workspace_public_id|
          chat = client.workspace(workspace_public_id).conversation(conversation_id)
          conversation = chat.fetch
          guard = local_guard(ctx, conversation)
          next guard if guard

          resolved = resolve_turn(chat.turns, turn_ref)
          next turn_not_found(turn_ref, conversation_id) if resolved.nil?

          turn_public_id, position = resolved
          args = { turn_public_id: turn_public_id, idempotency_key: idempotency_key, world: !keep_world,
                   approval_rules: Rho::LoopRequest.request_rules(roots: Rho.protected_roots(ctx.home)),
                   restore_guard: restore_guard(ctx) }
          args[:title] = title unless title.nil?
          rewound = chat.rewind(**args)
          RewoundFacts.new(conversation: rewound.conversation.public_id, forked_from: turn_public_id,
            position: position, world: rewound.world)
        end
      end

      # REGENERATE, restore-first: the door starts the model, so
      # the world is put back BEFORE the door. rho reads the deck and the
      # conversation and refuses what the door would and the read can see —
      # not the tail (`branch_required`, the door's own word), an active
      # turn, the active variant's loop `needs_attention` — then, unless
      # `--keep-world`, restores the active variant's checkpoint and calls
      # the door; a door that refuses AFTER the restore (a race) answers
      # with the undo so the recovery is one printed line. The kernel judges
      # nothing about the world; rho's policy does.
      def self.regenerate(ctx, conversation_id, turn_ref, keep_world: false, model: nil, workspace_public_id: nil)
        ctx.member_plane(host_public_id: conversation_id, **{ workspace_public_id: workspace_public_id }.compact) do |client, workspace_public_id|
          workspace = client.workspace(workspace_public_id)
          chat = workspace.conversation(conversation_id)
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
          outcome, refusal = restore_before_door(ctx, chat, conversation, active&.world, keep_world)
          next refusal if refusal

          door(chat, turn_public_id, model, outcome)
        end
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
          Rho::Daemon::Refusal.new(status: 409, code: "loop_needs_attention",
            message: "this turn's loop needs attention; adjudicate it first (retry or stop)") || nil
      end

      def self.needs_attention?(workspace, active)
        return false unless active&.loop_backed?

        workspace.agent_loops.fetch(active.agent_loop_public_id).status == "needs_attention"
      rescue CybrosAgent::Api::Error
        false
      end

      # `[outcome, refusal]`: the world is put back, or the reason it was
      # not. `untouched`/`kept` restore nothing; the restore itself is the
      # SDK's one composition (`ConversationContext#restore_world`, the
      # half `rewind` runs behind its fork) on the conversation's bound
      # runner, under the rules `rho do` authors re-addressed to the seed's
      # origin. An unrestorable world with no `--keep-world` is rho's own
      # refusal, the door never called; the outcome is the SDK's Hash
      # (`restored` with its `undo` and the paths it could not reach).
      def self.restore_before_door(ctx, chat, conversation, world, keep_world)
        return [{ status: "untouched" }, nil] if world.nil? || world.untouched?
        return [{ status: "kept" }, nil] if keep_world

        outcome = chat.restore_world(world, runner: conversation.runner&.executor_public_id,
          poll: RELAY_POLL_SECONDS, restore_guard: restore_guard(ctx),
          approval_rules: Rho::LoopRequest.request_rules(roots: Rho.protected_roots(ctx.home)))
        case outcome[:status]
        when "restored" then [outcome, nil]
        when "unavailable" then [nil, world_unavailable]
        else
          [nil, Rho::Daemon::Refusal.new(status: 409, code: "restore_failed",
            message: "the restore #{outcome[:reason]}#{outcome[:undo] ? " (undo #{outcome[:undo]})" : ""}; nothing was regenerated")]
        end
      end

      def self.door(chat, turn_public_id, model, outcome)
        args = model.nil? ? {} : { model: model }
        regeneration = chat.turns.regenerate(turn_public_id, **args)
        RegeneratedFacts.new(turn: turn_public_id, variant: regeneration.variant&.public_id, world: outcome)
      rescue CybrosAgent::Api::Conflict => error
        RegeneratedFacts.new(turn: turn_public_id, variant: nil, world: outcome.merge(door_refused: error.code))
      end

      def self.world_unavailable
        Rho::Daemon::Refusal.new(status: 409, code: "world_unavailable",
          message: "this turn's loop changed the world and no checkpoint can restore it; " \
                   "pass --keep-world to regenerate on the world as it is")
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
        runner = conversation.runner&.executor_public_id
        return nil unless runner && ctx.own_runner?(runner)

        ctx.environments.binding_for(conversation.public_id)&.root || ctx.environment.root
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
