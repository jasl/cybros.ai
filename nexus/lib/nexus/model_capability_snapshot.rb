module Nexus
  ModelCapabilitySnapshot = Data.define(
    :input_modalities, :output_modalities, :limits,
    :prompt_caching, :streaming,
    :service_tiers, :reasoning_modes, :generation_parameters,
    :reasoning_replay
  ) do
    def self.from_h(hash)
      parameters = hash.fetch("generation_parameters").to_h do |name, parameter|
        [name.to_sym, ModelGenerationParameter.from_h(parameter)]
      end

      new(
        input_modalities: hash.fetch("input_modalities"),
        output_modalities: hash.fetch("output_modalities"),
        limits: ModelCapabilityLimits.from_h(hash.fetch("limits")),
        prompt_caching: hash.fetch("prompt_caching"),
        streaming: hash.fetch("streaming"),
        service_tiers: hash.fetch("service_tiers"),
        reasoning_modes: hash.fetch("reasoning_modes"),
        generation_parameters: parameters.freeze,
        # Absent reads as the default: a model with no replay format.
        reasoning_replay: ReasoningReplayCapability.from_h(hash["reasoning_replay"])
      )
    end

    def to_h
      {
        "input_modalities" => input_modalities,
        "output_modalities" => output_modalities,
        "limits" => limits.to_h,
        "prompt_caching" => prompt_caching,
        "streaming" => streaming,
        "service_tiers" => service_tiers,
        "reasoning_modes" => reasoning_modes,
        "generation_parameters" => generation_parameters.to_h do |name, parameter|
          [name.to_s, parameter.to_h]
        end,
        "reasoning_replay" => reasoning_replay.to_h,
      }
    end
  end
end
