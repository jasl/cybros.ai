require "test_helper"
require "tmpdir"

class ModelCatalog::ModelInheritanceTest < ActiveSupport::TestCase
  test "one shared definition composes with independent routes and their prices" do
    catalog = compile(
      definitions: { "example-text" => shared_definition },
      models: {
        "example/first" => { "inherit" => "example-text", "model_id" => "first", "pricing" => pricing("1") },
        "example/second" => { "inherit" => "example-text", "model_id" => "second", "pricing" => pricing("2") },
      }
    )

    assert_equal %w[example/first example/second], catalog.models.keys.sort
    assert_equal "first", profile(catalog, "example/first").model_pin
    assert_equal "second", profile(catalog, "example/second").model_pin
    assert_equal "1", catalog.models.fetch("example/first").dig("pricing", "schedule", "rates", "input_per_mtok")
    assert_equal "2", catalog.models.fetch("example/second").dig("pricing", "schedule", "rates", "input_per_mtok")
    assert_equal %w[low medium high], catalog.models.fetch("example/first").dig("capabilities", "reasoning", "efforts")
    refute catalog.models.fetch("example/first").key?("inherit")
    refute catalog.models.fetch("example/first").key?("model_identity")
    assert_equal({ "inherit" => "example-text", "model_id" => "first", "pricing" => pricing("1") },
      catalog.authored_models.fetch("example/first"))
    assert_predicate catalog.authored_models.fetch("example/first"), :frozen?
    assert_predicate catalog.model_definitions.fetch("example-text").fetch("capabilities"), :frozen?
    assert_equal({ "maximum" => 64_000, "default" => 1024 },
      catalog.model_definitions.fetch("example-text").dig("capabilities", "generation_parameters", "max_output_tokens"))
  end

  test "author fields merge before parameter defaults with arrays false and null replacing the base" do
    catalog = compile(definitions: { "example-text" => shared_definition }, models: {
      "example/model" => {
        "inherit" => "example-text", "token_counter" => nil, "input_modalities" => [], "tool_calls" => false,
        "reasoning" => { "efforts" => %w[low high] },
        "generation_parameters" => {
          "max_output_tokens" => { "maximum" => 4096 }, "verbosity" => { "default" => nil },
        },
      },
    })
    row = catalog.models.fetch("example/model")
    controls = row.dig("capabilities", "generation_parameters")

    assert_equal 1024, controls.fetch("max_output_tokens").fetch("default")
    assert_equal 4096, controls.fetch("max_output_tokens").fetch("maximum")
    assert_nil controls.fetch("verbosity").fetch("default")
    assert_equal %w[low high], row.dig("capabilities", "reasoning", "efforts")
    assert_equal "low", row.dig("capabilities", "reasoning", "default_effort")
    assert_empty profile(catalog).input_modalities
    refute profile(catalog).capability_enabled?("tool_calls")
    assert_nil profile(catalog).token_counter
    authored = catalog.authored_models.fetch("example/model")
    assert_equal "example-text", authored.fetch("inherit")
    assert_nil authored.fetch("token_counter")
    assert_equal({ "maximum" => 4096 }, authored.dig("capabilities", "generation_parameters", "max_output_tokens"))
    refute authored.key?("generation_parameters")
  end

  test "a route limits block replaces the complete deployment window" do
    [
      { "combined_input_output_tokens" => 32_768 },
      { "input_tokens" => 32_768, "output_tokens" => 4096 },
      {},
    ].each do |limits|
      catalog = compile(definitions: { "example-text" => shared_definition }, models: {
        "example/model" => { "inherit" => "example-text", "limits" => limits },
      })
      assert_equal limits, catalog.models.fetch("example/model").dig("capabilities", "limits")
      assert_equal 64_000, profile(catalog).generation_parameters.fetch("max_output_tokens").maximum
    end

    catalog = compile(definitions: { "example-text" => shared_definition }, models: {
      "example/model" => { "inherit" => "example-text", "capabilities" => { "limits" => {} }, "reasoning" => {} },
    })
    assert_equal "low", catalog.models.fetch("example/model").dig("capabilities", "reasoning", "default_effort")
    assert_nil profile(catalog).local_safety_limits.combined_input_output_tokens
  end

  test "explicit null clears nullable facts and is not a deletion marker for limits" do
    catalog = compile(definitions: { "example-text" => shared_definition }, models: {
      "example/model" => { "inherit" => "example-text", "reasoning" => nil },
    })
    assert_nil catalog.models.fetch("example/model").dig("capabilities", "reasoning")

    assert_raises(ModelCatalog::CompileError) do
      compile(definitions: { "example-text" => shared_definition }, models: {
        "example/model" => { "inherit" => "example-text", "limits" => { "input_tokens" => nil } },
      })
    end
  end

  test "every shared definition is validated even when no route uses it" do
    invalid = [
      { "inherit" => "other" },
      { "pricing" => pricing("1") },
      { "api_format" => "openai_responses" },
      { "wire_options" => { "responses_path" => "/responses" } },
      { "service_tiers" => ["priority"] },
      { "reasoning_replay" => { "format" => "responses_reasoning" } },
      { "limits" => { "input_tokens" => -1 } },
      { "input_modalities" => ["unknown"] },
      { "output_modalities" => ["unknown"] },
      { "reasoning" => { "efforts" => ["unknown"] } },
      { "generation_parameters" => { "temperature" => { "kind" => "unknown" } } },
      { "generation_parameters" => { "invented" => { "kind" => "integer" } } },
      { "token_counter" => { "kind" => "huggingface" } },
    ]
    invalid.each do |definition|
      assert_raises(ModelCatalog::CompileError, definition.inspect) do
        compile(definitions: { "unused" => definition }, models: {})
      end
    end
  end

  test "unknown and malformed inheritance refuses the file candidate" do
    ["missing", nil, [], " example-text", "provider/model"].each do |reference|
      assert_raises(ModelCatalog::CompileError) do
        compile(definitions: { "example-text" => shared_definition }, models: {
          "example/model" => { "inherit" => reference },
        })
      end
    end
  end

  test "definition names and their top-level collection have a closed authoring shape" do
    [nil, [], { "" => {} }, { "Provider/Model" => {} }, { "a" * 257 => {} }, { "valid" => [] }].each do |definitions|
      error = assert_raises(ModelCatalog::CompileError) { compile(definitions: definitions, models: {}) }
      assert_match(/model_definitions must be a mapping|model definition name|entry must be a mapping/, error.message)
    end
  end

  test "wire-neutral definitions still validate every composed route against its own protocol" do
    definition = { "input_modalities" => ["image"], "reasoning" => { "efforts" => ["xhigh"] } }
    unused = compile(definitions: { "example-text" => definition }, models: {})
    assert_equal ["xhigh"], unused.model_definitions.fetch("example-text").dig("capabilities", "reasoning", "efforts")

    assert_raises(ModelCatalog::CompileError) do
      compile(definitions: { "example-text" => definition },
        models: { "example/model" => { "inherit" => "example-text" } }, format: "gemini_generate_content")
    end
  end

  test "file tiers replace definitions and routes wholesale before inheritance expands" do
    Dir.mktmpdir do |root|
      Dir.mktmpdir do |overrides|
        write(root, "10_base.yml", "model_definitions" => { "example-text" => shared_definition },
          "providers" => provider_definition, "models" => {
            "example/model" => { "inherit" => "example-text", "pricing" => pricing("1") },
          })
        write(overrides, "10_models.yml", "model_definitions" => {
          "example-text" => { "limits" => { "input_tokens" => 64_000 } },
        })
        write(overrides, "10_models.production.yml", "model_definitions" => {
          "example-text" => { "limits" => { "input_tokens" => 32_768 } },
        }, "models" => { "example/model" => { "inherit" => "example-text" } })

        catalog = ModelCatalog::FileBase.compile(root: root, override_dir: overrides, env: "production")
        assert_equal({ "limits" => { "input_tokens" => 32_768 } }, catalog.models.fetch("example/model").fetch("capabilities"))
        refute catalog.models.fetch("example/model").key?("pricing")

        write(root, "20_duplicate.yml", "model_definitions" => { "example-text" => {} })
        error = assert_raises(ModelCatalog::CompileError) do
          ModelCatalog::FileBase.compile(root: root, override_dir: overrides)
        end
        assert_includes error.message, "duplicate model_definition"
      end
    end
  end

  test "database authoring retains inheritance and replaces the prior route as a whole" do
    catalog = compile(definitions: { "example-text" => shared_definition }, models: {
      "example/model" => { "display_name" => "Old route", "pricing" => pricing("1") },
    })
    snapshot = ModelCatalog::Snapshot.new(**catalog.to_h)
    account = accounts(:cybros)
    authored = { "inherit" => "example-text", "limits" => { "combined_input_output_tokens" => 32_768 } }

    ModelCatalog.stub(:current, snapshot) do
      result = ModelProviders::UpsertModelOverride.call(account: account, provider_id: "example",
        model_ref: "example/model", model: authored, expected_lock_version: nil, validate_definition: true)
      assert_predicate result, :done?
      assert_equal authored, result.policy.reload.override_entries.fetch("example/model").fetch("model")
      effective = ModelSelection::Resolver.effective_catalog(account, snapshot)
      row = effective.models.fetch("example/model")
      assert_equal({ "combined_input_output_tokens" => 32_768 }, row.dig("capabilities", "limits"))
      refute row.key?("display_name")
      refute row.key?("pricing")
      assert_equal "low", row.dig("capabilities", "reasoning", "default_effort")

      invalid = ModelProviders::UpsertModelOverride.call(account: account, provider_id: "example",
        model_ref: "example/model", model: { "inherit" => "absent" },
        expected_lock_version: result.policy.lock_version, validate_definition: true)
      assert_equal :invalid, invalid.outcome
      assert_equal authored, result.policy.reload.override_entries.fetch("example/model").fetch("model")

      reset = ModelProviders::ResetModelOverride.call(account: account, provider_id: "example",
        model_ref: "example/model", expected_lock_version: result.policy.lock_version)
      assert_predicate reset, :done?
      assert_equal catalog.models.fetch("example/model"), ModelSelection::Resolver.effective_catalog(account, snapshot).models.fetch("example/model")
    end
  end

  test "a stale database inheritance entry is ignored independently from valid siblings" do
    catalog = compile(definitions: { "example-text" => shared_definition }, models: { "example/model" => {} })
    snapshot = ModelCatalog::Snapshot.new(**catalog.to_h)
    account = accounts(:cybros)
    ModelProviderConfig.create!(account: account, provider_id: "example", model_overrides: {
      "schema_version" => ModelProviderConfig::OVERRIDES_SCHEMA_VERSION,
      "entries" => {
        "example/model" => { "op" => "upsert", "model" => { "inherit" => "retired" } },
        "example/second" => { "op" => "upsert", "model" => { "inherit" => "example-text" } },
      },
    })

    effective = ModelSelection::Resolver.effective_catalog(account, snapshot)
    assert_equal catalog.models.fetch("example/model"), effective.models.fetch("example/model")
    assert_equal "low", effective.models.fetch("example/second").dig("capabilities", "reasoning", "default_effort")
  end

  private

    def shared_definition
      {
        "token_counter" => { "kind" => "huggingface", "tokenizer_id" => "example/text" },
        "input_modalities" => ["image"],
        "limits" => { "combined_input_output_tokens" => 128_000, "output_tokens" => 64_000, "effective_input_tokens" => 100_000 },
        "reasoning" => { "efforts" => %w[low medium high], "default_effort" => "low", "disable_supported" => true },
        "generation_parameters" => { "max_output_tokens" => { "maximum" => 64_000, "default" => 1024 }, "verbosity" => {} },
      }
    end

    def pricing(rate)
      { "account_unit" => "USD", "schedule" => { "kind" => "catalog_only", "rates" => {
        "input_per_mtok" => rate, "output_per_mtok" => rate,
      } } }
    end

    def compile(definitions:, models:, format: "openai_responses")
      Dir.mktmpdir do |root|
        write(root, "10_base.yml", "providers" => provider_definition(format), "model_definitions" => definitions, "models" => models)
        ModelCatalog::FileBase.compile(root: root, override_dir: nil)
      end
    end

    def provider_definition(format = "openai_responses")
      { "example" => { "base_url" => "https://example.test", "api_format" => format } }
    end

    def write(root, name, contents)
      File.write(File.join(root, name), { "schema_version" => ModelCatalog::FileBase::SCHEMA_VERSION }.merge(contents).to_yaml)
    end

    def profile(catalog, ref = "example/model")
      ModelCatalog::ProfileBuilder.call(model_ref: ref, provider: catalog.providers.fetch("example"), model: catalog.models.fetch(ref))
    end
end
