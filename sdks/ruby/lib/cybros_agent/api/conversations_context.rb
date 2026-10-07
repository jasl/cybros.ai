module CybrosAgent
  module Api
    # One Workspace's nested Conversation COLLECTION: create, find, and the
    # two listings. Everything that acts on ONE conversation lives on
    # `conversation(public_id)` — the deep surface (inputs, turns, the
    # variant deck, the feeds) does not read well as a flat method list
    # with three identifiers per call.
    #
    # THE TWO LISTINGS ARE NOT A FILTER FLAG. `list` is the WORKING
    # surface: unarchived, top-level. `archived` is the recycle bin. And
    # subagent followers appear in neither — they surface through
    # `children` on their parent, because a follower nobody opened is
    # plumbing, not a conversation the caller started. SIDE conversations
    # are hidden from the working list too — a child row a UI may
    # hide — and `list(side: true)` is the one way to see them.
    class ConversationsContext
      include ConversationProjections
      include ConversationHistoryProjections
      include Fields

      attr_reader :workspace_public_id

      # The wire's spelling of "sides only".
      SIDE_FLAG = "1".freeze

      def initialize(dispatch:, workspace_public_id:)
        @dispatch = dispatch
        @workspace_public_id = required_string_snapshot(workspace_public_id, "workspace_public_id")
      end

      def list(after: nil, limit: nil, side: UNSET)
        params = query(after:, limit:, side: (SIDE_FLAG if side == true))
        page(ConversationSummary, @dispatch.call(path, params: params), "conversations")
      end

      # The recycle bin's own view — same shape, opposite filter.
      def archived(after: nil, limit: nil)
        answer = @dispatch.call("#{path}/archived", params: query(after:, limit:))
        page(ConversationSummary, answer, "conversations")
      end

      def search(query:, archived: nil, include_auxiliary: nil, limit: nil, after: nil)
        path = "#{Workspaces::PATH}/#{path_segment(@workspace_public_id, "workspace_public_id")}/conversation_search"
        shape(ConversationSearchPage, @dispatch.call(path,
          params: query(query:, archived:, include_auxiliary:, limit:, after:)))
      end

      # Creation demands the caller's own Idempotency-Key — the SDK never
      # silently mints one, because a retry the caller cannot recognize as
      # a retry is how one conversation becomes two.
      #
      # A replay retains the original 201 and body; the response header
      # identifies the stored answer.
      #
      # `default_runner_executor_public_id` names the runner-kind executor the
      # host's runner-tool calls are addressed to from birth; omitted, the
      # host is unbound — the kernel infers no runner; an ineligible id is
      # 422 `runner_not_eligible`.
      #
      # `answering_user_public_id` names the Agent that ANSWERS the
      # conversation — whose engine replies to every head, whoever posts it;
      # omitted, the caller answers its own conversation; an ineligible id
      # (not an agent profile of the account that may write in the
      # workspace) is 422 `answerer_not_eligible`. Both ride the
      # idempotency envelope.
      #
      # `access` is THE CARRIER AT BIRTH: `{default:, entries:}` —
      # the level of everyone the entries do not name (`full | read |
      # none`; omitted, `full`) and the named entries, each
      # `{user_public_id:, level:}` in the order given (array order is the
      # request's identity: a re-ordered replay is a different request).
      # The creator and the answerer are full by derivation and may not be
      # named; a principal that is not eligible — those two, the system
      # user, an unknown id, an id named twice — is 422
      # `principal_not_eligible`, one code; an unknown level is 422
      # `validation_failed`. Read the ids off `workspace.principals`.
      # `memory_context` replaces the default memory roots with named
      # bindings; nil keeps the default, and `{bindings: []}` disables them.
      def create(idempotency_key:, title: UNSET, metadata: UNSET, billing_subject: UNSET,
                 default_runner_executor_public_id: UNSET, answering_user_public_id: UNSET, access: UNSET,
                 memory_context: UNSET)
        required_string(idempotency_key, "idempotency_key")
        body = fields(title:, metadata:, billing_subject:, default_runner_executor_public_id:,
          answering_user_public_id:, access: field(access) { |carrier| access_body(carrier) }, memory_context:)

        created(
          @dispatch.call_accepting(
            path, method: :post, body: { "conversation" => body },
            headers: { "Idempotency-Key" => idempotency_key },
            success: 201
          )
        )
      end

      def fetch(public_id)
        shape(Conversation, @dispatch.call(conversation_path(public_id)), "conversation")
      end

      # ONE CONVERSATION'S OWN SURFACE. Reachable from here and from the
      # workspace both, because a caller that already holds a public_id has
      # no reason to list first.
      def conversation(public_id)
        ConversationContext.new(
          dispatch: @dispatch, workspace_public_id: @workspace_public_id,
          public_id: public_id
        )
      end

      private

        def created(result)
          Created.new(conversation: shape(Conversation, result.body, "conversation"), replayed: result.replayed)
        end

        def path
          "#{Workspaces::PATH}/#{path_segment(@workspace_public_id, "workspace_public_id")}/conversations"
        end

        def conversation_path(public_id)
          "#{path}/#{path_segment(public_id, "public_id")}"
        end

      # What `create` answers: the conversation, and whether the server
      # recognized this Idempotency-Key from an earlier request.
      Created = Data.define(:conversation, :replayed) do
        def replayed? = replayed

        def public_id = conversation.public_id
        def title = conversation.title
      end
    end
  end
end
