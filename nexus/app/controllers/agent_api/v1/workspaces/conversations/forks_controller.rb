# Fork over HTTP: idempotent on the SOURCE conversation, the child
# rendered through the caller's current scope.
class AgentAPI::V1::Workspaces::Conversations::ForksController <
      AgentAPI::V1::Workspaces::Conversations::BaseController
  include AgentAPI::V1::WorkspaceScoped

  def create
    key = required_idempotency_key
    return if performed?

    conversation = find_listable_conversation(@workspace)

    envelope = create_envelope
    outcome = ConversationCommandReceipt::Idempotent.call(
      account: current_account,
      workspace: @workspace,
      acting_user: acting_user,
      operation: :fork,
      idempotency_key: key,
      request_digest: ConversationCommandReceipt.digest_for(
        operation: :fork, envelope: envelope
      ),
      host: conversation,
    ) do
      result = ::Conversations::Fork.call(::Conversations::Fork::Command.new(
        conversation: conversation,
        turn_public_id: envelope["turn_public_id"],
        variant_public_id: envelope["variant_public_id"],
        acting_user: acting_user,
        title: envelope["title"],
        side: envelope.fetch("side", false),
      ))
      if result.accepted?
        child = result.value
        ConversationCommandReceipt::Idempotent::Success.new(
          status: 201,
          body: {
            conversation: AgentAPI::ConversationPresenter.full(child),
            # THE WORLD AT THE FORK POINT: a derived fact about the
            # SOURCE's rows at and below its head, which the fork does not
            # change — so it is read here, after `Fork` returned and
            # outside the source's row lock, and inside the receipt block
            # so a replay answers the same value off the receipt body.
            world: ::Conversations::WorldAt.call(conversation: conversation, position: fork_point(child)),
          },
          host: conversation,
        )
      else
        result
      end
    end

    # A replay renders only through the caller's current scope: the child
    # concealed since is 404.
    render_idempotent_outcome(outcome) do |receipt|
      Conversation.visible_to(acting_user, workspace: @workspace)
        .exists?(public_id: receipt.response_body.dig("conversation", "public_id"))
    end
  end

  private

    # The child's head is one past its point — the adopted turn's position
    # on a plain fork, the parent's newest settled turn on a side.
    def fork_point(child) = child.timeline_position_head - 1

    # A side fork names no turn — its point is the parent's newest
    # settled turn — and a turn sent beside `side` is not read; the
    # envelope still digests what was sent, so a replay with another
    # shape is the family's mismatch. A plain fork owes its turn (400).
    def create_envelope
      fields = params.expect(fork: [:turn_public_id, :variant_public_id, :title, :side])
      side = ActiveModel::Type::Boolean.new.cast(fields[:side]) || false
      {
        "turn_public_id" => side ? fields[:turn_public_id] : fields.require(:turn_public_id),
        "variant_public_id" => fields[:variant_public_id],
        "title" => fields[:title],
        "side" => (true if side),
      }.compact
    end
end
