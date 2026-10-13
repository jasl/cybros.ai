module AgentRuns
  module Steers
    # A steer lands as a message in the request the next model task seals; if
    # two model tasks are about to run, "next" names neither and the steer
    # stays bound.
    class ConsumeAtCheckpoint
      class << self
        def for(agent_run:, node:)
          new(agent_run: agent_run, node: node)
        end
      end

      def initialize(agent_run:, node:)
        @agent_run = agent_run
        @node = node
      end

      # EVERY bound steer drains at one boundary, in queue order — a user
      # correcting themselves twice gets both corrections, as consecutive
      # user messages, in the order typed. The rows are locked under the
      # loop lock: an edit lands before the peek reads, and a cancel either
      # precedes it or finds the row consumed.
      def peek
        return [] unless mainline_model_task? && unambiguous_boundary?

        @agent_run.steering_inputs
          .includes(:speaker, content_bodies: [{ content_body_entries: :content_fragment },
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
          AgentRun::Narration.record(@agent_run, [{ type: "input_materialized", payload: landed }])
        end
      end

      private

        def landing(input)
          {
            "input_public_id" => input.public_id,
            "queue_position" => input.queue_position,
            "run_public_id" => @agent_run.public_id,
            "task_key" => @node.node_key,
            "turn_public_id" =>
              (@agent_run.conversation_turn.public_id unless @agent_run.standalone?),
          }.compact
        end

        # Only the mainline drains: a delegate's branch — the compaction
        # summarizer included — is not the conversation.
        def mainline_model_task? = @node.continuation_source != Tasks::Compile::BRANCH

        def unambiguous_boundary?
          return false unless @node.provider_id.present?
          # A live continuation is the conversation's own next round, so a
          # background branch does not make "next" ambiguous; a settled
          # mainline answers nothing, or no client-authored task could ever drain a steer.
          if (live = live_mainline_nodes).any?
            return live == [@node.id]
          end

          # Nothing mid-flight: a steer must not arrive for a round that
          # is already talking to a provider.
          return false if running_model_nodes.any?

          ready_model_nodes == [@node.id]
        end

        # The mainline's NEXT round is the one unambiguous boundary: a live
        # mainline round no other live mainline round precedes. A chain authored
        # ahead of time is one candidate at a time, not several.
        def live_mainline_nodes
          live = @agent_run.mainline_nodes.where(status: AgentRunTask::LIVE_STATUSES).pluck(:id)
          behind = AgentRunEdge.where(from_node_id: live, to_node_id: live).pluck(:to_node_id)
          live - behind
        end

        def model_scope
          @agent_run.agent_run_tasks.where(type: AgentRunTasks::ModelTask.sti_name)
        end

        def running_model_nodes = model_scope.where(status: "running").pluck(:id)

        def ready_model_nodes
          model_scope.where(status: "queued", remaining_dependencies: 0)
            .order(:created_at, :id).pluck(:id)
        end
    end
  end
end
