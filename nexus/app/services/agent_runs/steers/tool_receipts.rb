module AgentRuns
  module Steers
    # A pending call's first consumption belongs to the model that read it.
    # Its frozen receipt keeps later replay from moving the eventual result
    # backwards into that request. The original task remains the result owner.
    module ToolReceipts
      ROLE = "tool_receipts".freeze

      module_function

      def record(node, calls, pending:)
        pending_by_call = pending.group_by { |task| TaskResultEnvelope.call_key(task) }
        items = calls.filter_map do |call|
          tasks = pending_by_call[call.node_key]
          next unless tasks

          output = "The tool call is still pending. Its tasks are " + tasks.map do |task|
            "#{task.node_key} (#{TaskProjection.public_status(task.status)})"
          end.join(", ") + ". No result is available yet. The same work continues; its actual result " \
            "will be delivered later. Do not restart it merely because this receipt has no result."
          RoundReplay::Pairing.item(call_id: call.tool_call_id, name: call.called_name, output: output)
        end
        return if items.empty?

        result = ContentBodies::Replace.call(owner: node, role: ROLE,
          entries: Nexus::InputEntries.for(items), seal: true)
        raise ArgumentError, "the pending tool receipts could not be kept: #{result.refusal}" unless result.accepted?
      end

      def for_consumer(node)
        items(node.content_bodies.find_by(role: ROLE))
      end

      # Only a minted consumer has read its receipt. Resolve by its first
      # source, scoped to the run; call ids may repeat in later rounds.
      def by_source(rounds)
        return {} if rounds.empty?

        sources = rounds.index_by { |round| [round.agent_run_id, round.node_key] }
        consumers = AgentRunTasks::ModelTask.where(agent_run_id: rounds.map(&:agent_run_id).uniq)
          .where.not(selected_model_invocation_id: nil)
          .where("input_from_node_keys[1] IN (?)", rounds.map(&:node_key)).index_by(&:id)
        ContentBody.where(agent_run_task_id: consumers.keys, role: ROLE)
          .includes(content_body_entries: :content_fragment).each_with_object({}) do |body, result|
            consumer = consumers.fetch(body.agent_run_task_id)
            source = sources[[consumer.agent_run_id, consumer.input_from_node_keys.first]]
            result[source.id] = items(body) if source
          end
      end

      def items(body)
        return {} unless body

        Nexus::InputEntries.from(entries: body.content_body_entries.map { |entry| entry.content_fragment.payload },
          workload: "text_generation").index_by { |item| item.payload.fetch("call_id") }
      end
    end
  end
end
