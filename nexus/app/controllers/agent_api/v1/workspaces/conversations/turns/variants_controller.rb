# The variant deck: read a reachable turn's live candidates, conceal or
# restore one of a LOCAL turn's own. The deck's listing is `.live` — a
# concealed row's content_preview never rides a payload.
# @auth [MemberBearer]
class AgentAPI::V1::Workspaces::Conversations::Turns::VariantsController <
      AgentAPI::V1::Workspaces::Conversations::BaseController
  include AgentAPI::V1::WorkspaceScoped

  # @oas_include
  # @summary List variants
  # @tags Member, variants
  # @parameter conversation_public_id(path) [!String] Public UUIDv7. format: (uuid)
  # @parameter turn_public_id(path) [!String] Public UUIDv7. format: (uuid)
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
  # @response_ref (200) #/components/responses/AgentApiV1WorkspacesConversationsTurnsVariantsIndex
  def index
    conversation = find_listable_conversation(@workspace)
    reach = ::Conversations::TurnReach.resolve(
      conversation: conversation, turn_public_id: params.fetch(:turn_public_id)
    )
    raise ActiveRecord::RecordNotFound if reach.nil?

    turn = reach.turn
    # The normative read rule, here too: a LOCAL row's own concealment
    # conceals; an INHERITED row's effective state is the OVERRIDE's —
    # the shared row's view columns are never consulted.
    if reach.inherited?
      override = conversation.turn_overrides
        .find_by(turn_id: turn.id)
      raise ActiveRecord::RecordNotFound if override&.deleted_at
    elsif turn.deleted?
      raise ActiveRecord::RecordNotFound
    end
    variants = turn.variants.live.order(:position).preload(:origin_variant)
    # Both roles in one read, as the turns page reads them: each
    # candidate's content and, on a reply turn, the seed it carries —
    # `prompt_text` and its pictures ride the deck by presence.
    bodies = ContentBody.preload_for_render(
      ContentBody.where(variant_id: variants.map(&:id), role: %w[content prompt])
    )
      .group_by(&:role)
      .transform_values { |rows| rows.index_by(&:variant_id) }
    contents = bodies.fetch("content", {})
    prompts = bodies.fetch("prompt", {})

    loops = AgentAPI::ConversationPresenter.loop_blocks(variants.map(&:id))

    render json: {
      variants: variants.map { |variant|
        AgentAPI::ConversationPresenter.variant(
          variant, body: contents[variant.id], active: turn.active_variant_id == variant.id,
          loop: loops[variant.id], prompt: prompts[variant.id]
        )
      },
      turn: { public_id: turn.public_id, inherited: reach.inherited? },
    }
  end

  # @oas_include
  # @summary Read variants
  # @tags Member, variants
  # @parameter conversation_public_id(path) [!String] Public UUIDv7. format: (uuid)
  # @parameter public_id(path) [!String] Public UUIDv7. format: (uuid)
  # @parameter turn_public_id(path) [!String] Public UUIDv7. format: (uuid)
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
  # @response_ref (200) #/components/responses/AgentApiV1WorkspacesConversationsTurnsVariantsShow
  def show
    conversation = find_listable_conversation(@workspace)
    result = ::Conversations::Reader.new(conversation, user: acting_user).variant(
      turn_public_id: params.fetch(:turn_public_id), variant_public_id: params.fetch(:public_id))
    render json: { variant: result.variant,
      turn: { public_id: result.entry.turn.public_id, inherited: result.entry.inherited } }
  end

  # @oas_include
  # @summary Update variants
  # @tags Member, variants
  # @parameter conversation_public_id(path) [!String] Public UUIDv7. format: (uuid)
  # @parameter public_id(path) [!String] Public UUIDv7. format: (uuid)
  # @parameter turn_public_id(path) [!String] Public UUIDv7. format: (uuid)
  # @parameter workspace_public_id(path) [!String] Public UUIDv7. format: (uuid)
  # @request_body_ref #/components/requestBodies/AgentApiV1WorkspacesConversationsTurnsVariantsUpdate
  # @response_ref (400) #/components/responses/APIError
  # @response_ref (401) #/components/responses/APIError
  # @response_ref (403) #/components/responses/APIError
  # @response_ref (404) #/components/responses/APIError
  # @response_ref (409) #/components/responses/APIError
  # @response_ref (413) #/components/responses/APIError
  # @response_ref (422) #/components/responses/APIError
  # @response_ref (429) #/components/responses/APIError
  # @response_ref (500) #/components/responses/ServerError
  # @response_ref (200) #/components/responses/AgentApiV1WorkspacesConversationsTurnsVariantsUpdate
  def update
    conversation = find_listable_conversation(@workspace)
    fields = params.expect(variant: [:concealed])
    concealed = cast_boolean(fields[:concealed])

    result = ::Conversations::Variants::SetViewState.call(
      ::Conversations::Variants::SetViewState::Command.new(
        conversation: conversation,
        turn_public_id: params.fetch(:turn_public_id),
        variant_public_id: params.fetch(:public_id),
        acting_user: acting_user,
        concealed: concealed,
      )
    )

    if result.accepted?
      render json: {
        variant: AgentAPI::ConversationPresenter.variant(
          result.value.reload,
          body: result.value.content_bodies.find_by(role: "content"),
          active: false,
          loop: AgentAPI::ConversationPresenter.loop_block(result.value),
          prompt: result.value.content_bodies.find_by(role: "prompt")
        ),
      }
    else
      render_refusal(result.outcome)
    end
  end
end
