module AgentLoops
  module Steers
    # A steer lands as a message in the request the next model task seals; if
    # two model tasks are about to run, "next" names neither and the steer
    # stays bound.
    class ConsumeAtCheckpoint
      class << self
        def for(agent_loop:, node:)
          new(agent_loop: agent_loop, node: node)
        end
      end

      def initialize(agent_loop:, node:)
        @agent_loop = agent_loop
        @node = node
      end

      # EVERY bound steer drains at one boundary, in queue order — a user
      # correcting themselves twice gets both corrections, as consecutive
      # user messages, in the order typed. The rows are locked under the
      # loop lock: an edit lands before the peek reads, and a cancel either
      # precedes it or finds the row consumed.
      def peek
        return [] unless spine_round? && unambiguous_boundary?

        @agent_loop.steering_inputs
          .includes(:speaker_actor, content_bodies: [{ content_body_entries: :content_fragment },
                                     { content_uploads: { file_attachment: :blob } }])
          .lock.reject do |input|
            body = input.content_body
            body.nil? || (body.effective_text.blank? && body.content_uploads.empty?)
          end
      end

      # The landing: the tail's rendered messages are kept as the round's
      # own `steers` body (what later history and the summarizer render),
      # the row is gone (its body with it), and the feed says which round
      # its words rode into.
      def commit(inputs, elements = [], uploads: [])
        Landed.record(@node, Array(elements), uploads: uploads)
        Array(inputs).each do |input|
          landed = landing(input)
          input.destroy!
          AgentLoop::Narration.record(@agent_loop, [{ type: "input_materialized", payload: landed }])
        end
      end

      private

        def landing(input)
          {
            "input_public_id" => input.public_id,
            "queue_position" => input.queue_position,
            "agent_loop_public_id" => @agent_loop.public_id,
            "task_key" => @node.node_key,
            "turn_public_id" =>
              (@agent_loop.conversation_turn.public_id unless @agent_loop.standalone?),
          }.compact
        end

        # Only the spine drains: a delegate's branch — the compaction
        # summarizer included — is not the conversation.
        def spine_round? = @node.continuation_source != Tasks::Compile::BRANCH

        def unambiguous_boundary?
          return false unless @node.provider_id.present?
          # A live continuation is the conversation's own next round, so a
          # background branch does not make "next" ambiguous; a settled
          # spine answers nothing, or no client-authored task could ever drain a steer.
          if (live = live_spine_nodes).any?
            return live == [@node.id]
          end

          # Nothing mid-flight: a steer must not arrive for a round that
          # is already talking to a provider.
          return false if running_model_nodes.any?

          ready_model_nodes == [@node.id]
        end

        # The spine's NEXT round is the one unambiguous boundary: a live
        # spine round no other live spine round precedes. A chain authored
        # ahead of time is one candidate at a time, not several.
        def live_spine_nodes
          live = @agent_loop.spine_nodes.where(status: AgentLoopNode::LIVE_STATUSES).pluck(:id)
          behind = AgentLoopEdge.where(from_node_id: live, to_node_id: live).pluck(:to_node_id)
          live - behind
        end

        def model_scope
          @agent_loop.agent_loop_nodes.where(type: AgentLoopNodes::ModelTask.sti_name)
        end

        def running_model_nodes = model_scope.where(status: "running").pluck(:id)

        def ready_model_nodes
          model_scope.where(status: "queued", remaining_dependencies: 0)
            .order(:created_at, :id).pluck(:id)
        end
    end
  end
end
