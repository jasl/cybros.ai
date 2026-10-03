module Conversations
  module Compaction
    # Compact because somebody asked: the kernel picks no threshold, but a
    # caller may. A door onto `Arm`, not a second implementation — only the
    # trigger differs. Idle, the host is a `compaction_summary` turn; with
    # a loop-backed reply running, the host is that reply's backing loop
    # and the arm reaches it under conv → loop, the ladder's order.
    class Request
      Command = Data.define(:conversation, :acting_user, :model, :reasoning_effort) do
        def initialize(model: nil, reasoning_effort: nil, **) = super
      end

      # What the door answers on either host: the turn — the summary turn
      # between turns, the running reply mid-turn — and, mid-turn, the
      # round repaired and the summarizer authored for it.
      Compacted = Data.define(:turn, :task, :summary_task_key) do
        def initialize(task: nil, summary_task_key: nil, **) = super
      end

      LOOP_HOST_STATUSES = %w[running paused].freeze

      def self.call(command) = new(command).call

      def initialize(command)
        @command = command
      end

      # Under the drain's own lock, re-read uncached: the arm claims
      # `active_turn` and a position, which under a running reply or from a
      # stale copy would collide with work still settling.
      def call
        @conversation = @command.conversation
        # A compaction REWRITES the history: the door's standing is the row's
        # write predicate, as on every write verb — `read` is refused by name
        # before the lock; `none` never reaches the door.
        return Outcome.refused(:not_authorized) unless @conversation.writable_by?(@command.acting_user)

        @conversation.with_lock do
          active = ApplicationRecord.uncached do
            @conversation.conversation_turns.active.order(:position).last
          end
          next arm_round(active) if active

          # Before the model: on an empty conversation "nothing to compact"
          # is the useful answer.
          precondition = Arm.refusal_for(@conversation)
          next Outcome.refused(precondition) if precondition

          selection, refusal = resolve_selection
          next Outcome.refused(refusal) if refusal

          arm(selection)
        end
      end

      private

        # The arm's own outcome is this verb's: the turn it armed, or why not.
        def arm(selection)
          armed = Arm.call(
            conversation: @conversation, selection: selection,
            trigger: Trigger.manual(user: @command.acting_user)
          )
          return armed unless armed.accepted?

          Outcome.accepted(Compacted.new(turn: armed.value))
        end

        # THE MANUAL DOOR MID-TURN: the spine's newest QUEUED round is the
        # one whose request is not yet sealed, compacted through the loop's
        # own verb so the loop vocabulary answers and the loop lock is
        # taken inside this one. `conversation_busy` only for a direct
        # reply in flight — one sealed request nothing can shrink — or the
        # kernel's own summary already running.
        def arm_round(active)
          agent_loop = backing_loop(active)
          return Outcome.refused(:conversation_busy) if agent_loop.nil?

          round = agent_loop.spine_nodes.where(status: "queued").order(:id).last
          return Outcome.refused(:task_not_queued) if round.nil?

          result = AgentLoops::Tasks::Compact.call(AgentLoops::Tasks::Compact::Command.new(
            agent_loop: agent_loop, task_key: round.node_key, acting_user: @command.acting_user
          ))
          return Outcome.refused(result.outcome) unless result.accepted?

          Outcome.accepted(Compacted.new(
            turn: active, task: result.node, summary_task_key: result.summary_task_key
          ))
        end

        def backing_loop(active)
          return nil if active.kind == Arm::SUMMARY_KIND

          agent_loop = active.active_variant&.agent_loop
          agent_loop if agent_loop && LOOP_HOST_STATUSES.include?(agent_loop.status)
        end

        # A caller names a model to run the summary somewhere cheaper;
        # unnamed, it inherits the newest variant's, the one choice needing no configuration.
        def resolve_selection
          model = @command.model.presence || inherited_model
          return [nil, :model_selection_missing] if model.blank?

          resolved = ModelSelection.resolve(
            account: @conversation.account,
            workload: "text_generation",
            submitted: Nexus::SubmittedModelSelection.new(
              model: model,
              reasoning_effort: @command.reasoning_effort.presence || inherited_effort
            ),
            configuration: OneShots::CoerceConfiguration.call({}),
            port: ModelSelection::Resolver.new
          )
          resolved.resolved? ? [resolved.selection, nil] : [nil, resolved.refusal]
        end

        def newest_variant
          return @newest_variant if defined?(@newest_variant)

          @newest_variant = ConversationTurnVariant
            .joins(:conversation_turn)
            .where(conversation_turns: { conversation_id: @conversation.id })
            .where.not(provider_id: nil)
            .order(id: :desc)
            .first
        end

        def inherited_model
          return nil if current_model.nil?

          "#{current_model.provider_id}/#{current_model.model_ref}"
        end

        def current_model
          return @current_model if defined?(@current_model)

          @current_model = AgentLoops::CurrentModel.for_variant(newest_variant) if newest_variant
        end

        def inherited_effort = current_model&.reasoning_effort
    end
  end
end
