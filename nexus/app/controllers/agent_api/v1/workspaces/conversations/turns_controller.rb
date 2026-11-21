# The timeline read: a position window through the ONE shared funnel —
# inherited entries included, concealment enforced by the funnel, content
# batched so a page is a bounded number of queries, not one per turn.
# @auth [MemberBearer]
class AgentAPI::V1::Workspaces::Conversations::TurnsController <
      AgentAPI::V1::Workspaces::Conversations::BaseController
  include AgentAPI::V1::WorkspaceScoped

  DEFAULT_LIMIT = 20
  MAX_LIMIT = 100

  # @oas_include
  # @summary List turns
  # @tags Member, turns
  # @parameter conversation_public_id(path) [!String] Public UUIDv7. format: (uuid)
  # @parameter workspace_public_id(path) [!String] Public UUIDv7. format: (uuid)
  # @response_ref (400) #/components/responses/APIError
  # @response_ref (401) #/components/responses/APIError
  # @response_ref (403) #/components/responses/APIError
  # @response_ref (404) #/components/responses/APIError
  # @response_ref (409) #/components/responses/APIError
  # @response_ref (413) #/components/responses/APIError
  # @response_ref (422) #/components/responses/APIError
  # @response_ref (429) #/components/responses/APIError
  # @response_ref (500) #/components/responses/ServerError
  # @response_ref (200) #/components/responses/AgentApiV1WorkspacesConversationsTurnsIndex
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

  # @oas_include
  # @summary Read turns
  # @tags Member, turns
  # @parameter conversation_public_id(path) [!String] Public UUIDv7. format: (uuid)
  # @parameter public_id(path) [!String] Public UUIDv7. format: (uuid)
  # @parameter workspace_public_id(path) [!String] Public UUIDv7. format: (uuid)
  # @response_ref (400) #/components/responses/APIError
  # @response_ref (401) #/components/responses/APIError
  # @response_ref (403) #/components/responses/APIError
  # @response_ref (404) #/components/responses/APIError
  # @response_ref (409) #/components/responses/APIError
  # @response_ref (413) #/components/responses/APIError
  # @response_ref (422) #/components/responses/APIError
  # @response_ref (429) #/components/responses/APIError
  # @response_ref (500) #/components/responses/ServerError
  # @response_ref (200) #/components/responses/AgentApiV1WorkspacesConversationsTurnsShow
  def show
    conversation = find_listable_conversation(@workspace)
    entry = conversation.timeline.entry(public_id: params.fetch(:public_id),
      include_hidden: cast_boolean(params[:include_hidden]))
    raise ActiveRecord::RecordNotFound if entry.nil?

    render json: { turn: AgentAPI::ConversationPresenter.turn_entries([entry]).sole }
  end

  # @oas_include
  # @summary Update turns
  # @tags Member, turns
  # @parameter conversation_public_id(path) [!String] Public UUIDv7. format: (uuid)
  # @parameter public_id(path) [!String] Public UUIDv7. format: (uuid)
  # @parameter workspace_public_id(path) [!String] Public UUIDv7. format: (uuid)
  # @request_body_ref #/components/requestBodies/AgentApiV1WorkspacesConversationsTurnsUpdate
  # @response_ref (400) #/components/responses/APIError
  # @response_ref (401) #/components/responses/APIError
  # @response_ref (403) #/components/responses/APIError
  # @response_ref (404) #/components/responses/APIError
  # @response_ref (409) #/components/responses/APIError
  # @response_ref (413) #/components/responses/APIError
  # @response_ref (422) #/components/responses/APIError
  # @response_ref (429) #/components/responses/APIError
  # @response_ref (500) #/components/responses/ServerError
  # @response_ref (200) #/components/responses/AgentApiV1WorkspacesConversationsTurnsUpdate
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

  # @oas_include
  # @summary Destroy turns
  # @tags Member, turns
  # @parameter conversation_public_id(path) [!String] Public UUIDv7. format: (uuid)
  # @parameter public_id(path) [!String] Public UUIDv7. format: (uuid)
  # @parameter workspace_public_id(path) [!String] Public UUIDv7. format: (uuid)
  # @response_ref (204) #/components/responses/AgentApiV1WorkspacesConversationsTurnsDestroy
  # @response_ref (400) #/components/responses/APIError
  # @response_ref (401) #/components/responses/APIError
  # @response_ref (403) #/components/responses/APIError
  # @response_ref (404) #/components/responses/APIError
  # @response_ref (409) #/components/responses/APIError
  # @response_ref (413) #/components/responses/APIError
  # @response_ref (422) #/components/responses/APIError
  # @response_ref (429) #/components/responses/APIError
  # @response_ref (500) #/components/responses/ServerError
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
