require "test_helper"
require "tmpdir"

class ModelCatalog::ModelDefinitionTest < ActiveSupport::TestCase
  test "compact descriptors compile into complete controls with ordinary profile defaults" do
    catalog = compile_model({ "generation_parameters" => {
      "max_output_tokens" => { "maximum" => 32_768 },
      "verbosity" => {},
      "temperature" => { "kind" => "number", "minimum" => 0.0, "maximum" => 2.0 },
    } })
    profile = profile_for(catalog)

    assert_empty profile.input_modalities
    assert_equal ["text"], profile.output_modalities
    cap = profile.generation_parameters.fetch("max_output_tokens")
    assert_equal "integer", cap.kind
    assert_equal 1, cap.minimum
    assert_equal 32_768, cap.maximum
    assert_nil cap.default
    assert_nil cap.allowed_values
    verbosity = profile.generation_parameters.fetch("verbosity")
    assert_equal "low", verbosity.default
    assert_equal %w[low medium high], verbosity.allowed_values
    temperature = profile.generation_parameters.fetch("temperature")
    assert_equal "number", temperature.kind
    assert_nil temperature.default
    assert_nil temperature.allowed_values

    normalized = catalog.models.fetch("example/model").dig("capabilities", "generation_parameters")
    normalized.each_value do |descriptor|
      assert_equal ModelCatalog::CatalogValidation::GENERATION_PARAMETER_KEYS.sort, descriptor.keys.sort
    end
  end

  test "explicit nulls and empty or false overrides survive defaults" do
    catalog = compile_model({
      "tool_calls" => false,
      "service_tiers" => [],
      "generation_parameters" => {
        "max_output_tokens" => { "minimum" => nil, "maximum" => nil, "default" => 0 },
        "verbosity" => { "default" => nil, "allowed_values" => ["high"] },
        "output_format" => false,
      },
    }, provider: { "service_tiers" => %w[standard priority] })
    profile = profile_for(catalog)

    cap = profile.generation_parameters.fetch("max_output_tokens")
    assert_nil cap.minimum
    assert_nil cap.maximum
    assert_equal 0, cap.default
    assert_nil profile.generation_parameters.fetch("verbosity").default
    assert_equal ["high"], profile.generation_parameters.fetch("verbosity").allowed_values
    refute profile.generation_parameters.key?("output_format")
    refute profile.capability_enabled?("tool_calls")
    assert_empty profile.service_tiers
  end

  test "presets fill a declared control without advertising an omitted one" do
    omitted = profile_for(compile_model({}))
    refute omitted.generation_parameters.key?("max_output_tokens")
    refute omitted.generation_parameters.key?("verbosity")

    declared = profile_for(compile_model({ "generation_parameters" => { "max_output_tokens" => {} } }))
    assert_equal 1, declared.generation_parameters.fetch("max_output_tokens").minimum
    assert_nil declared.generation_parameters.fetch("max_output_tokens").maximum

    speech = compile_model({}, provider: { "api_format" => "openai_audio_speech" })
    assert_equal ["audio"], profile_for(speech).output_modalities
    assert profile_for(speech).generation_parameters.key?("voice")
    cleared = compile_model({ "generation_parameters" => {} }, provider: { "api_format" => "openai_audio_speech" })
    assert_empty profile_for(cleared).generation_parameters
  end

  test "a replacement starts with conventions rather than inheriting the prior model fields" do
    Dir.mktmpdir do |root|
      Dir.mktmpdir do |overrides|
        write_fragment(root, "providers" => provider_definition, "models" => {
          "example/model" => { "generation_parameters" => { "max_output_tokens" => { "maximum" => 64 } } },
        })
        write_fragment(overrides, "models" => {
          "example/model" => { "generation_parameters" => { "max_output_tokens" => {} } },
        })
        catalog = ModelCatalog::FileBase.compile(root: root, override_dir: overrides)
        assert_nil profile_for(catalog).generation_parameters.fetch("max_output_tokens").maximum
      end
    end
  end

  test "file and database authoring compile the same compact definition and retain the authored override" do
    entry = { "generation_parameters" => { "max_output_tokens" => { "minimum" => 16, "maximum" => 128_000 } } }
    file_catalog = compile_model(entry)
    snapshot = ModelCatalog::Snapshot.new(providers: file_catalog.providers, models: {}, selectors: {})
    account = accounts(:cybros)

    ModelCatalog.stub(:current, snapshot) do
      result = ModelProviders::UpsertModelOverride.call(account: account, provider_id: "example",
        model_ref: "example/model", model: entry, expected_lock_version: nil, validate_definition: true)
      assert_predicate result, :done?
      assert_equal entry, result.policy.reload.override_entries.fetch("example/model").fetch("model")
      effective = ModelSelection::Resolver.effective_catalog(account, snapshot)
      assert_equal file_catalog.models.fetch("example/model"), effective.models.fetch("example/model")
      assert_equal profile_for(file_catalog).to_h, profile_for(effective).to_h

      invalid = ModelProviders::UpsertModelOverride.call(account: account, provider_id: "example",
        model_ref: "example/model", model: { "generation_parameters" => { "max_output_tokens" => { "maximum" => 0 } } },
        expected_lock_version: result.policy.lock_version, validate_definition: true)
      assert_equal :invalid, invalid.outcome
      assert_equal entry, result.policy.reload.override_entries.fetch("example/model").fetch("model")
    end
  end

  test "descriptor conventions keep explicit invalid declarations subject to validation" do
    [
      { "max_output_tokens" => { "minimum" => 16, "maximum" => 15 } },
      { "verbosity" => { "default" => "unknown" } },
      { "verbosity" => { "allowed_values" => [] } },
      { "temperature" => {} },
      { "max_output_tokens" => { "future_field" => 1 } },
    ].each do |parameters|
      assert_raises(ModelCatalog::CompileError) { compile_model({ "generation_parameters" => parameters }) }
    end
  end

  private

    def compile_model(entry, provider: {})
      Dir.mktmpdir do |root|
        write_fragment(root, "providers" => provider_definition(provider), "models" => { "example/model" => entry })
        ModelCatalog::FileBase.compile(root: root, override_dir: nil)
      end
    end

    def provider_definition(overrides = {})
      { "example" => { "base_url" => "https://example.test", "api_format" => "openai_responses" }.merge(overrides) }
    end

    def write_fragment(root, contents)
      File.write(File.join(root, "models.yml"), { "schema_version" => ModelCatalog::FileBase::SCHEMA_VERSION }.merge(contents).to_yaml)
    end

    def profile_for(catalog)
      ModelCatalog::ProfileBuilder.call(model_ref: "example/model", provider: catalog.providers.fetch("example"),
        model: catalog.models.fetch("example/model"))
    end
end
