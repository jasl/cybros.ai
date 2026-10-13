require "yaml"
require_relative "manual_client"

module E2E
  module DeferredToolsDiagnostic
    MODEL = "deepseek/deepseek-flash".freeze
    COST_STOP_USD = 2.0
    OUTPUT_TOKENS = 2048

    module_function

    def validate!(env = ENV)
      ManualClient.validate!(env, key_names: ["DEEPSEEK_API_KEY"])
    end

    def model_overrides(nexus_root:)
      fragment = YAML.safe_load_file(File.join(nexus_root, "config/model_catalog/60_deepseek.yml"))
      row = fragment.fetch("models").fetch(MODEL)
      row.fetch("capabilities").fetch("generation_parameters").fetch("max_output_tokens").merge!(
        "default" => OUTPUT_TOKENS, "maximum" => OUTPUT_TOKENS
      )
      row.fetch("capabilities").fetch("reasoning")["default_enabled"] = false
      { MODEL => row }
    end
  end
end
