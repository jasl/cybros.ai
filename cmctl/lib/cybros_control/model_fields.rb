module CybrosControl
  # Both terminal surfaces edit a few common fields while retaining the
  # administrator's other model metadata from the configuration read.
  module ModelFields
    def self.apply(current, model_id: nil, display_name: nil, input_tokens: nil, output_tokens: nil,
                   tool_calls: nil, pricing: nil, clear_pricing: false)
      definition = current.dup
      definition["model_id"] = model_id unless model_id.nil?
      definition["display_name"] = display_name unless display_name.nil?
      if !input_tokens.nil? || !output_tokens.nil? || !tool_calls.nil?
        capabilities = definition.fetch("capabilities", {}).dup
        if !input_tokens.nil? || !output_tokens.nil?
          limits = capabilities.fetch("limits", {}).dup
          limits["input_tokens"] = input_tokens unless input_tokens.nil?
          limits["output_tokens"] = output_tokens unless output_tokens.nil?
          capabilities["limits"] = limits
        end
        capabilities["tool_calls"] = tool_calls unless tool_calls.nil?
        definition["capabilities"] = capabilities
      end
      if clear_pricing
        definition.delete("pricing")
      elsif pricing
        definition["pricing"] = pricing
      end
      definition
    end

    def self.prices(current, unit:, input:, output:)
      pricing = current["pricing"] || {}
      # An inherited catalog can use a different unit from this account.
      # Its other rates cannot be relabeled as the newly supplied currency.
      pricing = {} unless pricing["account_unit"] == unit
      schedule = pricing.fetch("schedule", {})
      rates = schedule.fetch("rates", {}).merge("input_per_mtok" => input, "output_per_mtok" => output)
      pricing.merge("account_unit" => unit, "schedule" => schedule.merge("kind" => "catalog_only", "rates" => rates))
    end
  end
end
