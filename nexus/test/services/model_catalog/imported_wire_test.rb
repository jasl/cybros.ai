require "test_helper"

class ModelCatalog::ImportedWireTest < ActiveSupport::TestCase
  test "every shipped chat row compiles its default thinking and tool round without credentials or IO" do
    candidate = ModelCatalog::FileBase.compile(root: Rails.root.join("config/model_catalog"), override_dir: nil)
    count = 0
    candidate.models.each do |ref, model|
      provider = candidate.providers.fetch(ref.split("/", 2).first)
      profile = ModelCatalog::ProfileBuilder.call(model_ref: ref, provider: provider, model: model)
      next unless profile.workload == "text_generation"

      count += 1
      options = {}
      maximum = profile.generation_parameters["max_output_tokens"]&.default
      options[:max_output_tokens] = maximum if maximum
      reasoning = model.dig("capabilities", "reasoning")
      if reasoning
        selected, refusal = Nexus::EffectiveReasoning.derive(reasoning, nil)
        assert_nil refusal, ref
        options[:reasoning_enabled] = selected.enabled
        options[:reasoning_effort] = selected.effort if selected.effort
      end
      client = SimpleInference::Client.new(execution_profile: profile, base_url: "https://fixture.example")
      request = client.responses.compile(model: profile.model_pin, stream: true,
        input: [{ role: "user", content: "Read the fixture." }],
        tools: [{ type: "function", name: "read", parameters: { type: "object", properties: {} } }], **options)
      assert request.path.start_with?("/"), ref
      refute_empty JSON.parse(request.payload), ref
    rescue SimpleInference::Error => error
      flunk "#{ref}: #{error.class}: #{error.message}"
    end
    assert_equal 1092, count
  end
end
