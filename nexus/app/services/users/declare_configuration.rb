module Users
  # The Profile's whole declaration crosses two boundaries: the model owns
  # its stored shape and slot invariants; the catalog resolver judges each
  # newly named model — the default one, and the fallback a declined step
  # re-runs on — against this Account's provider policy and credentials.
  class DeclareConfiguration
    # The two catalog refs, each naming ONE model the account runs.
    MODEL_REFS = %i[default_model fallback_model].freeze

    def self.call(user:, tool_definitions:, approval_mode:, approval_rules:, prompt_mechanism:,
                  prompt_template:, compaction_policy:, default_model: nil, lifecycle_hooks: nil,
                  fallback_model: nil, kernel_tools: nil, runner_executor_public_ids: nil,
                  runner_tool_names: nil, replacing_prompt_documents: false)
      return Outcome.new(outcome: :not_agent, user: user) unless user.agent_member?

      user.assign_attributes(
        tool_definitions: canonical_tool_definitions(tool_definitions),
        kernel_tools: kernel_tools, runner_executor_public_ids: runner_executor_public_ids,
        runner_tool_names: runner_tool_names,
        approval_mode: approval_mode, approval_rules: approval_rules.presence,
        prompt_mechanism: prompt_mechanism,
        prompt_template: prompt_template, compaction_policy: compaction_policy,
        default_model: default_model.presence, lifecycle_hooks: lifecycle_hooks,
        fallback_model: fallback_model.presence
      )
      # DeclareProfile replaces and validates both documents before its transaction
      # commits. Its new template must not be judged against the old slot's macros.
      context = :profile_declaration if replacing_prompt_documents
      refusals = MODEL_REFS.filter_map { |field| ref_refusal(user, field) }
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
    def self.ref_refusal(user, field)
      ref = user.public_send(field)
      refusal = ModelSelection.ref_refusal(account: user.account, ref: ref) if ref.present? && user.attribute_changed?(field)
      [field, refusal] if refusal
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
