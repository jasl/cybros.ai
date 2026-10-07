require "yaml"
require_relative "manual_client"
require_relative "provider_lanes"

module E2E
  module ToolDiscoverySmoke
    OUTPUT_TOKENS = 4096
    COST_STOP_USD = 3.0
    TURN_SECONDS = 300
    CODING_MODEL = "deepseek/deepseek-flash".freeze
    ARMS = %w[eager_direct deferred].freeze
    ACCESSORS = %w[tool_search tool_call nexus.tools.search nexus.tools.call].freeze
    DISCOVERY_PREFIX = "Some tool schemas are available through tool discovery.".freeze
    FIXTURE = File.expand_path("../fixtures/tool_discovery_smoke", __dir__)
    Cell = Data.define(:model, :kind, :arm) do
      def id = [model, kind, arm].join(":")
    end

    module_function

    def models
      bench = YAML.safe_load_file(File.expand_path("../evals/bench.yml", __dir__))
      (bench.fetch("tiers").values + bench.fetch("named_only").values).flatten.uniq
    end

    def cells
      models.flat_map { |model| ARMS.map { |arm| Cell.new(model: model, kind: "read", arm: arm) } } +
        ARMS.map { |arm| Cell.new(model: CODING_MODEL, kind: "coding", arm: arm) }
    end

    def validate!(env = ENV)
      ManualClient.validate!(env, key_names: ProviderLanes.provider_keys_for(models).values)
    end

    def model_overrides
      models.to_h do |model|
        row = ProviderLanes.catalog.fetch("models").fetch(model)
        capabilities = row.fetch("capabilities")
        parameters = capabilities.fetch("generation_parameters")
        limit = parameters.fetch("max_output_tokens").merge("default" => OUTPUT_TOKENS, "maximum" => OUTPUT_TOKENS)
        [model, row.merge("capabilities" => capabilities.merge(
          "generation_parameters" => parameters.merge("max_output_tokens" => limit)))]
      end
    end

    def definitions_for(arm, definitions)
      return definitions if arm == "deferred"

      eager = definitions.reject { |entry| accessor?(entry) }.map { |entry| entry.except("defer_loading") }
      raise "the eager control must remove exactly two discovery accessors" unless definitions.length - eager.length == 2

      eager
    end

    def documents_for(arm, documents)
      return documents if arm == "deferred"

      system = documents.fetch("system_prompt")
      discovery, rest = system.fetch("content").split("\n\n", 2)
      raise "the expected discovery guideline was not the first paragraph" unless discovery.start_with?(DISCOVERY_PREFIX) && rest

      documents.merge("system_prompt" => system.merge("content" => rest))
    end

    def accessor?(entry)
      ACCESSORS.include?(entry["canonical"]) || ACCESSORS.include?(entry.dig("function", "name"))
    end

    # These fresh, short conversations do not compact. Read the last history
    # once: provider ids can repeat in later rounds, so ids are not run keys.
    # Code's expanded children are Runner tasks, not new model-authored calls.
    def model_calls(sealed_requests)
      calls_in(sealed_requests.last).drop(calls_in(sealed_requests.first).length)
    end

    def calls_in(request)
      return [] if request.nil?

      request.fetch("entries").filter_map { |entry| entry.fetch("payload") if entry["type"] == "tool_call_item" }
    end
  end
end
