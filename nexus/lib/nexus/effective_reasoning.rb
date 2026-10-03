module Nexus
  # The closed reasoning value: explicit nullable fields, never a one-of union, because a provider may require `mode`
  # and `effort` together. `enabled` says what Nexus selected: true (an effort or a reasoning-on lane), false ("none"),
  # nil (provider default).
  EffectiveReasoning = Data.define(
    :enabled, :effort, :mode, :budget_tokens, :summary_policy, :context_policy
  ) do
    # The one derivation over a catalog reasoning block: compile-time selector
    # validation and accept-time resolution both call it, so the two sides cannot
    # disagree. Returns [value, refusal]; exactly one is nil.
    def self.derive(reasoning, effort)
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

      if effort.nil?
        # A reasoning-on-by-default lane carries the provider's own effort:
        # selected-on with none, and the lowerer omits the field.
        return [nil, :missing_reasoning_effort] unless reasoning["default_enabled"]
      elsif !efforts.include?(effort)
        return [nil, :unsupported_reasoning_effort]
      end

      [
        new(
          # "none" is an explicit member of some vocabularies (the DeepSeek
          # lane's documented disable value): selecting it DISABLES reasoning
          # rather than enabling it at a phantom level.
          enabled: effort != "none",
          effort: effort,
          # A durable field is something Nexus selected; nothing selects a mode, a
          # summary policy or a token budget today — every lane lowers from effort
          # alone.
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
