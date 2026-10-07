module Nexus
  # The closed reasoning value: enablement and effort are independent choices.
  # A reasoning model defaults on unless its declaration says otherwise. Nil
  # enablement means the model has no declared reasoning capability.
  EffectiveReasoning = Data.define(
    :enabled, :effort, :mode, :budget_tokens, :summary_policy, :context_policy
  ) do
    # The one derivation over a catalog reasoning block: compile-time selector
    # validation and accept-time resolution both call it, so the two sides cannot
    # disagree. Returns [value, refusal]; exactly one is nil.
    def self.derive(reasoning, effort, enabled: nil)
      effort = effort.to_s.strip
      effort = nil if effort.empty?

      if reasoning.nil? || reasoning.empty?
        # No reasoning data: Nexus selects nothing. A submitted effort has no
        # declared vocabulary to be a member of, so it is refused rather than
        # silently dropped.
        return [nil, :unsupported_reasoning_effort] if effort

        return [absent, nil]
      end

      efforts = reasoning["efforts"] || []
      effort ||= reasoning["default_effort"]

      if effort && !efforts.include?(effort)
        return [nil, :unsupported_reasoning_effort]
      end

      enabled = reasoning.fetch("default_enabled", true) if enabled.nil?
      # A portable off request is best effort. Preserve the model's actual
      # enabled state when it cannot disable reasoning, rather than freezing
      # a false execution fact or sending an unsupported provider control.
      enabled = true if enabled == false && !reasoning.fetch("disable_supported", false)

      [
        new(
          enabled: enabled,
          effort: effort,
          # A durable field is something Nexus selected; nothing selects a mode, a
          # summary policy or a token budget today.
          mode: nil,
          budget_tokens: nil,
          summary_policy: nil,
          context_policy: reasoning["default_context"]
        ),
        nil,
      ]
    end

    def self.absent
      new(enabled: nil, effort: nil, mode: nil, budget_tokens: nil,
        summary_policy: nil, context_policy: nil)
    end

    def self.from_h(hash)
      hash.nil? ? absent : new(**hash.transform_keys(&:to_sym))
    end

    def to_h = super.transform_keys(&:to_s)
  end
end
