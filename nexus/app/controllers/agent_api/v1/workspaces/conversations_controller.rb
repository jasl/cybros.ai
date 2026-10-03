# The default list is the working surface: unarchived, top-level (followers
# surface through their parent, the bin has its own view), never a side
# (`?side=1` lists sides only; any other value is the default). Show stays
# browsable for archived rows; tombstones conceal as absence everywhere.
class AgentAPI::V1::Workspaces::ConversationsController <
      AgentAPI::V1::Workspaces::BaseController
  include AgentAPI::V1::WorkspaceScoped
  include AgentAPI::MemoryContextParameters

  SIDE_FLAG = "1".freeze

  def index
    scope = Conversation.visible_to(acting_user, workspace: @workspace)
      .unarchived.where(parent_conversation_id: nil)
      .includes(:active_turn, :answering_user)
    scope = params[:side] == SIDE_FLAG ? scope.sides : scope.working
    page = keyset_page(scope, columns: { public_id: :uuid })

    render json: {
      conversations: page.records.map { |c| AgentAPI::ConversationPresenter.basic(c) },
      pagination: { next_after: page.next_after },
    }
  end

  def show
    conversation = find_listable_conversation(@workspace, param: :public_id)

    render json: { conversation: AgentAPI::ConversationPresenter.full(conversation) }
  end

  def create
    key = required_idempotency_key
    return if performed?

    return unless reject_explicit_nulls(:conversation, %i[metadata])

    envelope = create_envelope
    return unless principals_distinct(envelope["access"])

    outcome = ConversationCommandReceipt::Idempotent.call(
      account: current_account,
      workspace: @workspace,
      acting_user: acting_user,
      operation: :conversation_create,
      idempotency_key: key,
      request_digest: ConversationCommandReceipt.digest_for(
        operation: :conversation_create, envelope: envelope
      ),
    ) do
      result = ::Conversations::Create.call(::Conversations::Create::Command.new(
        workspace: @workspace,
        creating_user: acting_user,
        title: envelope["title"],
        metadata: envelope["metadata"],
        billing_subject: envelope["billing_subject"],
        runner_executor_public_id: envelope["runner_executor_public_id"],
        answering_user_public_id: envelope["answering_user_public_id"],
        access: envelope["access"],
        memory_context: envelope["memory_context"],
      ))
      case result.outcome
      when :accepted
        ConversationCommandReceipt::Idempotent::Success.new(
          status: 201,
          body: { conversation: AgentAPI::ConversationPresenter.full(result.value) },
          host: result.value,
        )
      else
        result
      end
    end

    # Replay renders only through the caller's current scope: a tombstone
    # — or a level of `none` — conceals it like absence.
    render_idempotent_outcome(outcome) do |receipt|
      Conversation.visible_to(acting_user, workspace: @workspace).exists?(id: receipt.host_id)
    end
  end

  def update
    conversation = find_listable_conversation(@workspace, param: :public_id)
    return unless authorize_writable(conversation)
    return unless reject_explicit_nulls(:conversation, %i[metadata])

    if conversation.archived?
      return render_error(:conversation_archived,
        "Refused: conversation_archived", status: :conflict)
    end

    fields = params.expect(conversation: [:title, { metadata: {} }])
    changes = {}
    changes[:title] = fields[:title].to_s.strip.presence if fields.key?(:title)
    changes[:metadata] = fields[:metadata].to_h if fields.key?(:metadata)
    if changes.empty?
      return render_error(:validation_failed,
        "Provide title or metadata to update", status: :unprocessable_entity)
    end

    if conversation.update(changes)
      render json: { conversation: AgentAPI::ConversationPresenter.full(conversation) }
    elsif conversation.errors.any? { |e| e.type == Nexus::SizeBounds::REJECTION }
      render_error(:content_too_large,
        "Content exceeds the persisted size bounds", status: :content_too_large)
    else
      render_error(:validation_failed,
        conversation.errors.full_messages.join("; "), status: :unprocessable_entity)
    end
  end

  def destroy
    conversation = find_listable_conversation(@workspace, param: :public_id)
    return unless authorize_writable(conversation)

    result = ::Conversations::Tombstone.call(conversation: conversation)

    if result.accepted?
      head :no_content
    else
      render_refusal(result.outcome)
    end
  end

  private

    # Fetch-then-permit, not `expect`: a body with no typed fields is an
    # untitled conversation — the ordinary case — and `expect` 400s it. The
    # Idempotency-Key is the real gate; the envelope is optional decoration.
    def create_envelope
      fields = params.fetch(:conversation, {})
        .permit(:title, :billing_subject, :runner_executor_public_id, :answering_user_public_id, metadata: {},
          access: [:default, { entries: [:user_public_id, :handle, :level] }])
      {
        "title" => fields[:title],
        "billing_subject" => fields[:billing_subject],
        "metadata" => fields[:metadata]&.to_h || {},
        # The named runner and the named answerer are part of the request:
        # a replay naming another is the family's envelope mismatch.
        "runner_executor_public_id" => fields[:runner_executor_public_id],
        "answering_user_public_id" => fields[:answering_user_public_id],
        # THE ACCESS CARRIER rides the envelope too, in the request's own
        # entry order: array order is request identity on this surface,
        # so a re-ordered replay is a different request — and cannot
        # corrupt. Absent is nil, the one canonical absence.
        "access" => access_envelope(fields[:access]),
        "memory_context" => memory_context_parameter(params.fetch(:conversation, ActionController::Parameters.new)),
      }
    end

    def access_envelope(fields)
      return nil if fields.nil?

      {
        "default" => fields[:default],
        # Each entry as the caller spelled its principal — `user_public_id`
        # or `handle`; the spelling is part of the request.
        "entries" => Array(fields[:entries]).map do |entry|
          { "user_public_id" => entry[:user_public_id], "handle" => entry[:handle], "level" => entry[:level] }.compact
        end,
      }
    end

    # A principal named twice — by either spelling, so resolved — is
    # refused by name BEFORE the digest: the unique index would answer it
    # as a 500 inside the receipt wrapper, and no receipt should ever be
    # digested against a request that can never be admitted. The service
    # refuses it too, for every other caller; this is the boundary's own
    # answer.
    def principals_distinct(access)
      entries = Array(access&.fetch("entries"))
      return true unless ::Conversations::AccessPrincipals.repeated_principal?(
        account_id: current_account.id, entries: entries
      )

      render_error(:principal_not_eligible, "Refused: principal_not_eligible", status: :unprocessable_entity)
      false
    end
end
