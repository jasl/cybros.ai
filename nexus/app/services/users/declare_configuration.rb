module Users
  # The model owns declaration shape and slot invariants. The resolver
  # validates a changed default's catalog identity; admission later judges
  # live availability and the execution's captured recovery candidates.
  class DeclareConfiguration
    MODEL_REFS = { default_model: "text_generation", image_model: "image_generation" }.freeze

    def self.call(user:, tool_definitions:, approval_mode:, approval_rules:, prompt_mechanism:,
                  prompt_template:, compaction_policy:, default_model: nil, image_model: nil, lifecycle_hooks: nil,
                  fallback_models: nil, kernel_tools: nil, runner_executor_public_ids: nil,
                  runner_tool_names: nil, mcp_tools: nil, memory_context_limit: nil, conversation_reach: nil, delegation_catalog: nil,
                  replacing_prompt_documents: false)
      return Outcome.new(outcome: :not_agent, user: user) unless user.agent_member?

      user.assign_attributes(
        tool_definitions: canonical_tool_definitions(tool_definitions),
        kernel_tools: kernel_tools, runner_executor_public_ids: runner_executor_public_ids,
        runner_tool_names: runner_tool_names, mcp_tools: mcp_tools.nil? ? [] : mcp_tools,
        memory_context_limit: memory_context_limit, conversation_reach: conversation_reach,
        delegation_catalog: delegation_catalog,
        approval_mode: approval_mode, approval_rules: approval_rules.presence,
        prompt_mechanism: prompt_mechanism,
        prompt_template: prompt_template, compaction_policy: compaction_policy,
        default_model: default_model.presence, image_model: image_model.presence, lifecycle_hooks: lifecycle_hooks,
        fallback_models: fallback_models
      )
      # ConfigureAgent replaces and validates both documents before its transaction
      # commits. Its new template must not be judged against the old slot's macros.
      # Fresh named Agents retain normal create callbacks and have no old slots.
      context = :agent_configuration if replacing_prompt_documents && user.persisted?
      refusals = MODEL_REFS.filter_map { |field, workload| ref_refusal(user, field, workload) }
      if refusals.any?
        # Keep all shape errors beside the resolver's refusals, without a
        # second validation pass or a save of the refused declaration.
        user.valid?(context)
        refusals.each { |field, refusal| user.errors.add(field, :not_authorized, refusal: refusal) }
        return Outcome.new(outcome: :invalid, user: user)
      end

      Outcome.new(outcome: user.save(context: context) ? :declared : :invalid, user: user)
    end

    # A ref is judged when it changes: an unchanged one stands even after
    # the lane it names was turned off, so a re-declaration of the other
    # fields never fails on it.
    def self.ref_refusal(user, field, workload)
      ref = user.public_send(field)
      refusal = ModelSelection.ref_refusal(account: user.account, ref: ref, workload: workload) if ref.present? && user.attribute_changed?(field)
      # A configuration may name a temporarily unavailable route. Admission
      # reads current availability and can skip it through the captured list.
      [field, refusal] if refusal && !%i[model_hidden provider_disabled missing_credential reauthorization_required credential_unusable].include?(refusal)
    end
    private_class_method :ref_refusal

    # Store a canonical, rendered tool set. Invalid input stays intact so
    # the model's declaration grammar names the refusal at its usual field.
    def self.canonical_tool_definitions(value)
      entries = Array.try_convert(value)
      return value if entries.nil?

      Nexus::ToolDeclarations.render(Nexus::ToolDeclarations.canonical(entries)).presence
    end
    private_class_method :canonical_tool_definitions
  end
end
