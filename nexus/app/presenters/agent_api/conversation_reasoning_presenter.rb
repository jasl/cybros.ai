module AgentAPI
  # Display text already sealed by the producing invocation. Native replay
  # material has a different body role and never enters this projection.
  class ConversationReasoningPresenter
    DEFAULT_LIMIT = 20
    MAX_LIMIT = 100

    def self.call(...) = new(...).call

    def initialize(variant:, before: 0, limit: DEFAULT_LIMIT)
      @variant = variant
      @before = before
      @limit = limit
    end

    def call
      items = @variant.agent_run ? loop_items : direct_items
      { items: items, pagination: { next_before: @next_before, has_older: @has_older || false } }
    end

    private

      def loop_items
        scope = @variant.agent_run.agent_run_tasks
          .where(type: AgentRunTasks::ModelTask.sti_name)
          .where.not(transcript_visibility: "hidden")
          .where.not(selected_model_invocation_id: nil)
          .order(id: :desc)
        scope = scope.where(id: ...@before) if @before.positive?
        rows = scope.limit(@limit + 1).to_a
        @has_older = rows.length > @limit
        rows = rows.first(@limit)
        @next_before = AgentRunTask::TranscriptCursor.encode(rows.last.id) if @has_older

        invocations = ModelInvocation.where(id: rows.map(&:selected_model_invocation_id)).index_by(&:id)
        bodies = ContentBody.preload_for_render(
          ContentBody.where(model_invocation_id: invocations.keys, role: "reasoning")
        ).index_by(&:model_invocation_id)
        rows.reverse.filter_map do |node|
          invocation = invocations[node.selected_model_invocation_id]
          # Collection may finish between these lock-free reads. The next
          # request sees the owner's pruned marker; missing history is omitted.
          item(invocation, bodies[invocation.id]).merge(task_key: node.node_key) if invocation
        end
      end

      def direct_items
        body = @variant.content_bodies.find_by(role: "reasoning")
        if @variant.model_invocation_id || body
          [item(@variant, body)]
        else
          []
        end
      end

      def item(model, body)
        text = body&.effective_text.presence
        {
          model: {
            provider_id: model.provider_id,
            model_ref: model.model_ref,
            reasoning_effort: model.reasoning_effort, reasoning_enabled: model.reasoning_enabled,
          }.compact,
          available: text.present?,
          text: text,
        }.compact
      end
  end
end
