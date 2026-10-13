module ModelInvocations
  # The first admitted attempt starts the execution's clock. Retries and
  # automatic replacements inherit its remaining time from existing rows.
  # A new model step or an independent regeneration starts its own clock.
  module ExecutionDeadline
    module_function

    def for(invocation)
      ModelInvocationAttempt.where(model_invocation_id: invocation_ids(invocation)).minimum(:deadline_at)
    end

    def invocation_ids(invocation)
      case invocation.purpose
      when ModelInvocation::INFERENCE_REQUEST_PURPOSE
        ModelInvocation.where(inference_request_id: invocation.inference_request_id).select(:id)
      when ModelInvocation::AGENT_RUN_TASK_PURPOSE
        match = AgentRuns::ApplyStepResult::KEY_PATTERN.match(invocation.internal_creation_key)
        node_id, generation = match.captures.map(&:to_i)
        keys = (0..generation).map { |value| "agent_run_task:#{node_id}:#{value}" }
        ModelInvocation.where(agent_run_id: invocation.agent_run_id, internal_creation_key: keys).select(:id)
      when ModelInvocation::CONVERSATION_REPLY_PURPOSE
        reply_chain(invocation)
      else
        raise ArgumentError, "unknown invocation purpose: #{invocation.purpose}"
      end
    end

    def reply_chain(invocation)
      variant = ConversationTurnVariant.find_by(model_invocation_id: invocation.id)
      return [invocation.id] if variant.nil?

      variant.execution_chain.filter_map(&:model_invocation_id)
    end
  end
end
