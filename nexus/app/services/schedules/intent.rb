module Schedules
  # Schedule authoring captures the ordinary execution configuration.
  # Editing timing or words keeps that capture; choosing another answerer replaces it.
  class Intent
    def self.declaration(conversation, answerer:)
      return if answerer.nil?

      if conversation.answering_user_id == answerer.id && conversation.agent_configuration
        conversation.agent_configuration
      else
        AgentConfiguration.capture(answerer)
      end
    end

    def self.from_task(node)
      run = node.run
      round = Runs::KernelTool.round_of(node)
      return Conversations::Outcome.refused(:calling_round_unavailable) unless round

      declaration = run.agent_configuration.with_tools(round.tool_definitions, approval_mode: run.approval_mode)
      Conversations::Outcome.accepted({
        "answering_user" => run.answering_user,
        "agent_configuration" => declaration,
        "provider_id" => round.provider_id, "model_ref" => round.model_ref,
        "reasoning_effort" => round.reasoning_effort, "reasoning_enabled" => round.reasoning_enabled,
        "model_selection" => round.model_selection, "fallback_models" => round.fallback_models,
        "configuration" => round.request_options, "approval_mode" => run.approval_mode,
        "tool_names" => Nexus::ToolDeclarations.names(round.tool_definitions),
        "source_run_public_id" => run.public_id, "source_task_key" => node.node_key,
      })
    end

    def self.resolve(conversation:, fields:, by:, job: nil, model_controls: nil)
      attributes = fields.except("model", "model_selection", "fallback_models", "answering_user_public_id", "expected_lock_version")
      answerer = job&.answering_user || conversation.answering_user
      if fields.key?("answering_user_public_id")
        resolved = ::Conversations::TurnPrincipals.resolve(host: conversation, author: by,
          address: fields["answering_user_public_id"])
        return resolved unless resolved.accepted?

        attributes["answering_user"] = answerer = resolved.value.answerer
      end
      changed_answerer = job && answerer.id != job.answering_user_id
      captured = ::Conversations::AnswerEngine.captured?(conversation, addressee: answerer)
      if job.nil? || changed_answerer
        attributes["agent_configuration"] = declaration(conversation, answerer: answerer)
        selection = ::Conversations::AnswerEngine.selection(conversation, addressee: answerer)
        attributes.merge!(selection.to_h.stringify_keys) if selection
      end
      if fields.key?("model")
        provider, model, effort, enabled = model_controls
        changed_model = false
        if fields["model"]["model"].present?
          attributes.merge!("provider_id" => provider, "model_ref" => model)
          changed_model = job.nil? || provider != job.provider_id || model != job.model_ref
        end
        # A new model starts from its own defaults; a control-only edit keeps
        # the saved reference and the other control, including explicit false.
        attributes["reasoning_effort"] = effort if changed_model || !effort.nil?
        attributes["reasoning_enabled"] = enabled if changed_model || !enabled.nil?
      end
      if fields.key?("rule")
        attributes["rule"] = Schedule::Rule.parse(fields["rule"]).to_h
      end
      explicit_model = fields.dig("model", "model").present?
      if fields["model_selection"]
        attributes["model_selection"] = fields["model_selection"]
      elsif job.nil? || changed_answerer || explicit_model
        reference = "#{attributes["provider_id"] || job&.provider_id}/#{attributes["model_ref"] || job&.model_ref}"
        attributes["model_selection"] = if explicit_model
          ModelSelectionIntent.explicit(reference)
        elsif captured
          ::Conversations::AnswerEngine.captured_intent(conversation, addressee: answerer) || ModelSelectionIntent.default(reference)
        else
          ModelSelectionIntent.default(reference)
        end
      end
      if job.nil? || changed_answerer || fields.key?("fallback_models")
        attributes["fallback_models"] = fields["fallback_models"] ||
          (job.agent_configuration&.fallback_models if job && !changed_answerer) ||
          (captured ? conversation.fallback_models || conversation.agent_configuration.fallback_models : answerer.fallback_models) || []
      end
      ::Conversations::Outcome.accepted(attributes)
    end
  end
end
