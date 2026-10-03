module CybrosAgent
  module Api
    # The hosted replay feed's wire grammar, one map for both hosts: a
    # conversation's page and a standalone loop's are the same shape, the
    # resource naming which host narrated.
    module EventProjections
      include Parsing

      SHAPES = {
        # Not `page`: a replay page carries a head the keyset lists have no
        # equivalent of, and folding it into the shared Page would give
        # every other list a member that is always nil.
        ConversationEventPage => {
          items: [:shapes, ConversationEvent, "events"],
          next_after: [:nullable_string, "pagination", "next_after"],
          watermark: [:integer, "pagination", "watermark"],
        },
        ConversationEvent => {
          public_id: :string,
          sequence: :integer,
          cursor: :string,
          # VERBATIM, unknown values included: a follower that refused an
          # unfamiliar type would break on the deploy that adds one.
          type: :string,
          resource_type: [:string, "resource", "type"],
          resource_public_id: [:string, "resource", "public_id"],
          occurred_at: :string,
          payload: :json,
        },
        # A frame off the host's `progress` feed, the one feed
        # whose envelope is `{frame}` rather than `{event}`: the key and the
        # stamps by name, `type` verbatim, and everything else as the
        # payload — so a frame type this gem predates is carried whole.
        # `executor_public_id` by presence: the kernel's own frames name no
        # executor (only `step_claimed` does).
        ProgressFrame => {
          type: :string,
          agent_loop_public_id: :optional_string,
          conversation_public_id: :optional_string,
          task_key: :optional_string,
          tool_name: :optional_string,
          process_id: :optional_string,
          executor_public_id: :optional_string,
          at: :string,
          payload: ->(hash) { json_snapshot(hash.except(*ProgressFrame.members.map(&:to_s))) },
        },
      }.freeze
    end
  end
end
