module AgentRuns
  module TaskWaits
    # Dispatch receipts are not completion. Follow generation ownership to the
    # final leaves, and a spawn to its original request rather than today's child head.
    class Observe
      Result = Data.define(:text, :data, :error)

      class << self
        def call(node) = new(node).call

        def missing
          Result.new(text: "The task is no longer available.",
            data: { "status" => "unavailable", "error" => { "key" => "wait_target_not_found" } }, error: true)
        end
      end

      def initialize(node)
        @node = node
      end

      def call
        return nil unless @node.terminal?
        return spawned_reply if @node.status == "completed" && @node.tool_call? && @node.tool_name == "spawn" &&
          !@node.output_summary.fetch("is_error", false)

        rows = [@node, *ExpansionOwnership.descendants(@node)]
        ids = rows.map(&:id)
        consumed = AgentRunEdge.where(from_node_id: ids, to_node_id: ids, structural: true)
          .distinct.pluck(:from_node_id).to_set
        sinks = rows.reject { |node| consumed.include?(node.id) }
        return nil unless sinks.all?(&:terminal?)

        tips = TaskResultProjection.tips(@node.agent_run, sinks)
        tips = [@node] if tips.empty?
        ActiveRecord::Associations::Preloader.new(
          records: tips, associations: { output_body: { content_body_entries: :content_fragment } }
        ).call
        results = tips.map { |node| TaskResultProjection.call(node).merge("task" => node.node_key) }
        Result.new(text: tips.map { |tip| TaskResultEnvelope.for(tip, boundary: true) }.join("\n\n"),
          data: identity.merge("status" => "completed", "results" => results),
          error: results.any? { |result| result["status"] != "completed" || result["is_error"] })
      end

      private

        def identity = { "run_public_id" => @node.agent_run.public_id, "task" => @node.node_key }

        def spawned_reply
          child = @node.spawned_conversation
          return self.class.missing if child.nil? || child.tombstoned?

          turn = Delegations.original_turn(child, @node)
          if turn.nil?
            pending = child.conversation_inputs.exists?(sender_run_public_id: @node.agent_run.public_id,
              sender_task_key: @node.node_key)
            return pending ? nil : self.class.missing
          end

          variant = Delegations.answering_variant(turn)
          execution = variant&.agent_run
          if execution
            if execution.delivered?
              reply(child, "completed", execution.deliverable_node&.output_body&.effective_text)
            elsif execution.terminal?
              reply(child, execution.status, "The original delegated execution ended #{execution.status}.")
            end
          elsif (invocation = variant&.model_invocation)&.terminal?
            direct_reply(child, invocation)
          end
        end

        # The WORK's status, as the paired result reads it: a declined
        # answer completed its call and failed the reply.
        def direct_reply(child, invocation)
          if invocation.undecided?
            nil
          elsif invocation.declined?
            reply(child, "failed", RefusalSentence.for_reply(invocation))
          elsif invocation.finish_error?
            reply(child, "failed", invocation.failure_detail)
          else
            reply(child, invocation.status, invocation.content_bodies.find_by(role: "response")&.effective_text)
          end
        end

        def reply(child, status, text)
          text = text.presence || "(the delegated execution ended #{status} with no text)"
          Result.new(text: TaskResultEnvelope.child_reply(call_key: @node.node_key,
            status: status, conversation_public_id: child.public_id, body: text),
            data: identity.merge("status" => status, "conversation" => child.public_id, "output" => text),
            error: status != "completed")
        end
    end
  end
end
