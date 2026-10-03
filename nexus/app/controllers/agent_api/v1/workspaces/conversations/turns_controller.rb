# The timeline read: a position window through the ONE shared funnel —
# inherited entries included, concealment enforced by the funnel, content
# batched so a page is a bounded number of queries, not one per turn.
class AgentAPI::V1::Workspaces::Conversations::TurnsController <
      AgentAPI::V1::Workspaces::Conversations::BaseController
  include AgentAPI::V1::WorkspaceScoped

  DEFAULT_LIMIT = 20
  MAX_LIMIT = 100

  def index
    conversation = find_listable_conversation(@workspace)

    entries = conversation.timeline.entries(
      surface: :timeline,
      include_hidden: cast_boolean(params[:include_hidden]),
      after_position: window_position(:after_position),
      before_position: window_position(:before_position),
      limit: limit
    )

    render json: {
      turns: AgentAPI::ConversationPresenter.turn_entries(entries),
      pagination: {
        before_position: entries.first&.position,
        after_position: entries.last&.position,
      },
    }
  end

  def update
    conversation = find_listable_conversation(@workspace)
    fields = params.permit(turn: %i[visibility concealed]).fetch(:turn)

    result = ::Conversations::Turns::SetViewState.call(
      ::Conversations::Turns::SetViewState::Command.new(
        conversation: conversation,
        turn_public_id: params.fetch(:public_id),
        acting_user: acting_user,
        visibility: fields[:visibility],
        concealed: boolean_param(fields, :concealed),
      )
    )

    if result.accepted?
      render json: { turn: {
        public_id: result.value.turn.public_id,
        inherited: result.value.inherited?,
      } }
    else
      render_refusal(result.outcome)
    end
  end

  def destroy
    conversation = find_listable_conversation(@workspace)

    result = ::Conversations::Turns::HardDelete.call(
      ::Conversations::Turns::HardDelete::Command.new(
        conversation: conversation,
        turn_public_id: params.fetch(:public_id),
        acting_user: acting_user,
      )
    )

    if result.accepted?
      head :no_content
    elsif result.outcome == :descendant_pinned
      render_error(:descendant_pinned,
        "A fork still reads this turn: #{result.value}", status: :conflict)
    else
      render_refusal(result.outcome)
    end
  end

  private

    def boolean_param(fields, name) = cast_boolean(fields[name])

    def window_position(name)
      value = params[name]
      return nil if value.nil?

      bounded_integer(value, name, range: 0..2_147_483_647)
    end

    def limit = limit_param(default: DEFAULT_LIMIT, max: MAX_LIMIT)
end
