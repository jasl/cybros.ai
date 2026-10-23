class ConversationsController < Work::BaseController
  def show
    @conversation = find_visible_conversation
    options = Conversations::History::Parameters.read(params.permit(:around_turn_public_id, :after_position, :before_position).to_h)
    @page = Conversations::Reader.new(@conversation, user: acting_user).page(**options.slice(:around_turn_public_id, :after_position, :before_position))
    @current_run = Run.visible_to(acting_user).joins(:variant)
      .where(variants: { turn_id: @conversation.active_turn_id }).order(created_at: :desc, public_id: :desc).first if @conversation.active_turn_id
    @usage = ModelUsageSummary.public_projection(subject_kind: "conversation", subject_id: @conversation.id)
    @source_id = Conversation.readable_source_public_ids([@conversation.id], user: acting_user)[@conversation.id]
    @parent = Conversation.visible_to(acting_user).find_by(public_id: @conversation.parent_conversation_public_id) if @conversation.subagent?
    @memory_bindings = memory_bindings(@conversation.effective_memory_context, agent: @conversation.answering_agent)
    @memory_execution = @conversation.active_turn.variants.live.where(status: Variant::ACTIVE_STATUSES).order(position: :desc).first if @conversation.active_turn
    if @memory_execution
      # A missing historical capture means no memory, never today's defaults.
      @execution_memory_bindings = memory_bindings(@memory_execution.memory_context || { "bindings" => [] },
        agent: @memory_execution.execution_agent, execution: true)
    end
    ids = (@memory_bindings + Array(@execution_memory_bindings)).filter_map { |binding| binding.fetch(:collection_public_id) }
    @memory_collections = MemoryCollections::Access.new(by: acting_user).scope.where(public_id: ids).index_by(&:public_id)
  rescue Conversations::History::Parameters::Invalid
    render_error(:parameter_invalid, t("conversation_console.invalid_history"), status: :bad_request)
  end

  private

    def memory_bindings(configuration, agent:, execution: false)
      MemoryDocuments::Context.new(workspace: @conversation.workspace, conversation: @conversation,
        principal: acting_user, configuration: configuration, agent: agent, execution: execution)
        .management_projection.fetch(:bindings)
    end
end
