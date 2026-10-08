require "test_helper"
require "tmpdir"

# C2-2 WP2: the strict catalog file base. Shipped fragments plus operator
# `config.d` overlays compile into ONE complete validated candidate; any
# missing, malformed, duplicate, or inconsistent input refuses compilation —
# there is no partial acceptance and no fallback.
class ModelCatalog::FileBaseTest < ActiveSupport::TestCase
  SCHEMA = ModelCatalog::FileBase::SCHEMA_VERSION

  def write(root, rel, content)
    path = File.join(root, rel)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
  end

  def base_fragment(providers: {}, models: {}, selectors: {})
    {
      "schema_version" => SCHEMA,
      "providers" => providers,
      "models" => models,
      "selectors" => selectors,
    }.to_yaml
  end

  # An authored text entry whose shared window distinguishes the catalog layers.
  def text_entry(window: 1_050_000)
    {
      "capabilities" => {
        "input_modalities" => ["image"],
        "output_modalities" => ["text"],
        "limits" => { "combined_input_output_tokens" => window, "output_tokens" => 1 },
      },
    }
  end

  def with_root
    Dir.mktmpdir("model-catalog-test") do |root|
      yield root
    end
  end

  test "compiles shipped fragments into one deeply frozen candidate" do
    with_root do |root|
      write(root, "10_openai.yml", base_fragment(
        providers: { "openai_api" => { "base_url" => "https://api.openai.com", "api_format" => "openai_responses", "concurrency_limit" => 8 } },
        models: { "openai_api/text" => text_entry }
      ))
      write(root, "20_anthropic.yml", base_fragment(providers: { "anthropic" => { "base_url" => "https://api.anthropic.com", "api_format" => "anthropic_messages", "concurrency_limit" => 8 } }))

      first = ModelCatalog::FileBase.compile(root: root)

      assert_equal %w[anthropic openai_api], first.providers.keys.sort
      assert_equal ["openai_api/text"], first.models.keys
      assert first.providers.keys.all?(&:frozen?)
      assert first.models.keys.all?(&:frozen?)
      assert_predicate first.selectors, :frozen?
    end
  end

  test "selectors retain their authored candidate order" do
    with_root do |root|
      write(root, "10_openai.yml", base_fragment(
        providers: { "openai_api" => { "base_url" => "https://api.openai.com", "api_format" => "openai_responses", "concurrency_limit" => 8 } },
        models: { "openai_api/text" => text_entry },
        selectors: {
          "interactive_chat" => [
            { "model" => "openai_api/text", "reasoning_effort" => nil },
          ],
        }
      ))

      with_selector = ModelCatalog::FileBase.compile(root: root)
      write(root, "20_selector.yml", base_fragment(
        selectors: {
          "summarization" => [
            { "model" => "openai_api/text", "reasoning_effort" => nil },
          ],
        }
      ))
      with_second_selector = ModelCatalog::FileBase.compile(root: root)

      assert_equal ["openai_api/text"],
        with_selector.selectors.fetch("interactive_chat").pluck("model")
      assert_predicate with_selector.selectors.fetch("interactive_chat"), :frozen?
      assert_equal %w[interactive_chat summarization], with_second_selector.selectors.keys.sort
    end
  end

  test "selectors are duplicate-checked in shipped files and replaced wholesale by config_d" do
    with_root do |root|
      write(root, "10_base.yml", base_fragment(
        providers: { "openai_api" => { "base_url" => "https://api.openai.com", "api_format" => "openai_responses", "concurrency_limit" => 8 } },
        models: { "openai_api/text" => text_entry },
        selectors: {
          "interactive_chat" => [
            { "model" => "openai_api/text", "reasoning_effort" => nil },
          ],
        }
      ))
      write(root, "20_duplicate.yml", base_fragment(
        selectors: {
          "interactive_chat" => [
            { "model" => "openai_api/text", "reasoning_effort" => nil },
          ],
        }
      ))

      error = assert_raises(ModelCatalog::CompileError) do
        ModelCatalog::FileBase.compile(root: root)
      end
      assert_includes error.message, "duplicate selector"

      FileUtils.rm(File.join(root, "20_duplicate.yml"))
      Dir.mktmpdir("config-d") do |overrides|
        write(overrides, "50_site.yml", base_fragment(
          selectors: {
            "interactive_chat" => [
              { "model" => "openai_api/text", "reasoning_effort" => nil },
              { "model" => "openai_api/text", "reasoning_effort" => nil },
            ],
          }
        ))

        candidate = ModelCatalog::FileBase.compile(root: root, override_dir: overrides)
        assert_equal 2, candidate.selectors.fetch("interactive_chat").length
      end
    end
  end

  test "a config_d overlay may add entries and replace a shipped entry wholesale" do
    with_root do |root|
      Dir.mktmpdir("config-d") do |overrides|
        write(root, "10_base.yml", base_fragment(
          providers: { "openai_api" => { "base_url" => "https://api.openai.com", "api_format" => "openai_responses", "concurrency_limit" => 8 } },
          models: { "openai_api/text" => text_entry(window: 100) }
        ))
        write(overrides, "50_site.yml", base_fragment(
          models: { "openai_api/text" => text_entry(window: 200) }
        ))

        candidate = ModelCatalog::FileBase.compile(root: root, override_dir: overrides)

        # Whole-entry replacement, never a recursive merge (the same rule the
        # DB overlay follows).
        assert_equal 200,
          candidate.models.fetch("openai_api/text").dig("capabilities", "limits", "combined_input_output_tokens")
      end
    end
  end

  test "the environment tier merges after the generic tier and only for the current environment" do
    with_root do |root|
      Dir.mktmpdir("config-d") do |overrides|
        write(root, "10_base.yml", base_fragment(
          providers: { "openai_api" => { "base_url" => "https://api.openai.com", "api_format" => "openai_responses", "concurrency_limit" => 8 } },
          models: { "openai_api/text" => text_entry(window: 100) }
        ))
        write(overrides, "50_site.yml", base_fragment(
          models: { "openai_api/text" => text_entry(window: 200) }
        ))
        write(overrides, "50_site.production.yml", base_fragment(
          models: { "openai_api/text" => text_entry(window: 300) }
        ))

        tier = lambda do |candidate|
          candidate.models.fetch("openai_api/text").dig("capabilities", "limits", "combined_input_output_tokens")
        end
        in_test = ModelCatalog::FileBase.compile(root: root, override_dir: overrides, env: "test")
        assert_equal 200, tier.call(in_test)

        in_production = ModelCatalog::FileBase.compile(root: root, override_dir: overrides, env: "production")
        assert_equal 300, tier.call(in_production)
      end
    end
  end

  # `config.d` IS FLAT, and a leftover ENVIRONMENT directory REFUSES rather
  # than being ignored. There used to be a `config.d/<env>/*.yml` tier; it was
  # nested, it outranked the flat tier, and a directory named for no
  # recognized environment slipped past the suffix refusal below entirely.
  # Deleting it broke no test — which is exactly why the rule has to be
  # stated, or a deployment that still has such a directory loses its most
  # specific overlay without a word.
  test "an environment subdirectory under config.d refuses compilation rather than being ignored" do
    with_root do |root|
      Dir.mktmpdir("config-d") do |overrides|
        write(root, "10_base.yml", base_fragment(
          providers: { "openai_api" => { "base_url" => "https://api.openai.com", "api_format" => "openai_responses", "concurrency_limit" => 8 } },
          models: { "openai_api/text" => text_entry(window: 100) }
        ))
        nested = File.join(overrides, "production")
        FileUtils.mkdir_p(nested)
        write(nested, "10_dir.yml", base_fragment(
          models: { "openai_api/text" => text_entry(window: 400) }
        ))

        error = assert_raises(ModelCatalog::CompileError) do
          ModelCatalog::FileBase.compile(root: root, override_dir: overrides, env: "production")
        end
        assert_includes error.message, "production"
        assert_includes error.message, "FLAT"
      end
    end
  end

  # THE OVERLAY DIRECTORY IS MOVABLE, which is how a harness hands this
  # process a catalog without writing into the checkout it is running from.
  # The predecessor carried this seam and the rewrite had dropped it; a path
  # from the environment is compiled and validated exactly like `config.d`.
  test "MODEL_CATALOG_OVERRIDE_DIR moves the overlay directory" do
    Dir.mktmpdir("elsewhere") do |elsewhere|
      File.write(File.join(elsewhere, "50_site.yml"), base_fragment(
        providers: { "openai_api" => { "base_url" => "https://elsewhere.example", "api_format" => "openai_responses" } }
      ))

      with_env("MODEL_CATALOG_OVERRIDE_DIR" => elsewhere) do
        assert_equal Pathname.new(elsewhere), ModelCatalog.send(:default_override_dir)
      end
      with_env("MODEL_CATALOG_OVERRIDE_DIR" => nil) do
        assert_equal Rails.root.join("config.d"), ModelCatalog.send(:default_override_dir)
      end
      with_env("MODEL_CATALOG_OVERRIDE_DIR" => "   ") do
        assert_equal Rails.root.join("config.d"), ModelCatalog.send(:default_override_dir),
          "blank is not a path; it is somebody forgetting to set one"
      end
    end
  end

  # And ONLY an environment directory. `config.d` is a mount point in a
  # deployed image: a Kubernetes projected volume materializes as `..data` and
  # a timestamped directory beside the files it links to, and an operator may
  # keep a `backup/`. Refusing those would be refusing to boot over a layout
  # that has nothing to do with the catalog.
  test "a subdirectory that is not an environment is left alone" do
    with_root do |root|
      Dir.mktmpdir("config-d") do |overrides|
        write(root, "10_base.yml", base_fragment(
          providers: { "openai_api" => { "base_url" => "https://api.openai.com", "api_format" => "openai_responses", "concurrency_limit" => 8 } },
          models: { "openai_api/text" => text_entry(window: 100) }
        ))
        %w[backup .idea ..2026_08_21_00_00_00.123].each do |name|
          FileUtils.mkdir_p(File.join(overrides, name))
        end
        File.symlink(File.join(overrides, "..2026_08_21_00_00_00.123"),
          File.join(overrides, "..data"))

        candidate = ModelCatalog::FileBase.compile(
          root: root, override_dir: overrides, env: "production"
        )
        assert_equal 100,
          candidate.models.fetch("openai_api/text")
            .dig("capabilities", "limits", "combined_input_output_tokens")
      end
    end
  end

  test "an unrecognized environment-looking suffix refuses compilation" do
    with_root do |root|
      Dir.mktmpdir("config-d") do |overrides|
        write(root, "10_base.yml", base_fragment(providers: { "openai_api" => { "base_url" => "https://api.openai.com", "api_format" => "openai_responses", "concurrency_limit" => 8 } }))
        write(overrides, "site.prodcution.yml", base_fragment)

        error = assert_raises(ModelCatalog::CompileError) do
          ModelCatalog::FileBase.compile(root: root, override_dir: overrides, env: "test")
        end
        assert_includes error.message, "prodcution"
      end
    end
  end

  test "a duplicate key within one layer refuses compilation" do
    with_root do |root|
      write(root, "10_a.yml", base_fragment(providers: { "openai_api" => { "base_url" => "https://api.openai.com", "api_format" => "openai_responses", "concurrency_limit" => 8 } }))
      write(root, "20_b.yml", base_fragment(providers: { "openai_api" => { "base_url" => "https://api.openai.com", "api_format" => "openai_responses", "concurrency_limit" => 8 } }))

      error = assert_raises(ModelCatalog::CompileError) do
        ModelCatalog::FileBase.compile(root: root)
      end
      assert_includes error.message, "openai_api"
      assert_includes error.message, "duplicate"
    end
  end

  test "a duplicate mapping key within one YAML file refuses instead of silently taking the last value" do
    with_root do |root|
      write(root, "10_duplicate.yml", <<~YAML)
        schema_version: #{SCHEMA}
        providers:
          openai_api: {}
          openai_api: {}
        models: {}
        selectors: {}
      YAML

      error = assert_raises(ModelCatalog::CompileError) do
        ModelCatalog::FileBase.compile(root: root)
      end
      assert_includes error.message, "duplicate mapping key"
      assert_includes error.message, "openai_api"
    end
  end

  test "malformed YAML, unknown top-level keys, and a wrong schema version refuse with the file named" do
    with_root do |root|
      write(root, "10_bad.yml", "schema_version: [unclosed")
      error = assert_raises(ModelCatalog::CompileError) { ModelCatalog::FileBase.compile(root: root) }
      assert_includes error.message, "10_bad.yml"
    end

    with_root do |root|
      write(root, "10_unknown.yml", { "schema_version" => SCHEMA, "surprise" => {} }.to_yaml)
      error = assert_raises(ModelCatalog::CompileError) { ModelCatalog::FileBase.compile(root: root) }
      assert_includes error.message, "surprise"
    end

    with_root do |root|
      write(root, "10_wrong.yml", { "schema_version" => "v0", "providers" => {} }.to_yaml)
      error = assert_raises(ModelCatalog::CompileError) { ModelCatalog::FileBase.compile(root: root) }
      assert_includes error.message, "schema_version"
    end
  end

  test "a missing fragment root or an empty fragment set refuses compilation" do
    error = assert_raises(ModelCatalog::CompileError) do
      ModelCatalog::FileBase.compile(root: "/nonexistent/model_catalog")
    end
    assert_includes error.message, "missing"

    with_root do |root|
      error = assert_raises(ModelCatalog::CompileError) { ModelCatalog::FileBase.compile(root: root) }
      assert_includes error.message, "no catalog fragments"
    end
  end

  test "a model ref must be namespaced by a declared provider" do
    with_root do |root|
      write(root, "10_base.yml", base_fragment(
        providers: { "openai_api" => { "base_url" => "https://api.openai.com", "api_format" => "openai_responses", "concurrency_limit" => 8 } },
        models: { "mystery/text" => {} }
      ))

      error = assert_raises(ModelCatalog::CompileError) { ModelCatalog::FileBase.compile(root: root) }
      assert_includes error.message, "mystery/text"
    end
  end

  # Operator provider declarations supply endpoints and capacity, while the implementation registry
  # owns wire behavior. The harness overrides the endpoint with its allocated local port. Capacity
  # limits must actually constrain admission: a per-workload ceiling cannot exceed the provider-wide
  # ceiling. The closed key set prevents configuration from acquiring executable implementation
  # choices.
  test "provider concurrency limits must bind and may only narrow" do
    [
      [{ "concurrency_limit" => 0 }, "positive integer"],
      [{ "concurrency_limit" => "8" }, "positive integer"],
      [{ "concurrency_limit" => 4, "workload_concurrency_limits" => { "text_generation" => 5 } },
       "at or under concurrency_limit"],
      [{ "concurrency_limit" => 4, "workload_concurrency_limits" => { "telepathy" => 1 } },
       "unknown workload"],
      [{ "concurrency_limit" => 4, "workload_concurrency_limits" => [] }, "must be a mapping"],
    ].each do |facts, message|
      Dir.mktmpdir do |root|
        write(root, "10_base.yml", base_fragment(
          providers: { "openai_api" => { "base_url" => "https://api.openai.com", "api_format" => "openai_responses" }.merge(facts) }
        ))
        error = assert_raises(ModelCatalog::CompileError) { ModelCatalog::FileBase.compile(root: root) }
        assert_includes error.message, message
      end
    end
  end

  # A ceiling an operator did not write is filled in conservatively rather
  # than refused: a provider entry should be two lines, and a deployment that
  # can take more concurrent work is the one that has something to say.
  test "a provider that declares no capacity gets the conservative ceiling" do
    Dir.mktmpdir do |root|
      write(root, "10_base.yml", base_fragment(
        providers: { "openai_api" => { "base_url" => "https://api.openai.com", "api_format" => "openai_responses" } }
      ))
      candidate = ModelCatalog::FileBase.compile(root: root)
      assert_equal ModelCatalog::FileBase::DEFAULT_CONCURRENCY_LIMIT,
        candidate.providers.fetch("openai_api").fetch("concurrency_limit")
    end
  end

  test "a provider must say which wire it speaks, and it must be one we adapted" do
    Dir.mktmpdir do |root|
      write(root, "10_base.yml", base_fragment(
        providers: { "openai_api" => { "base_url" => "https://api.openai.com" } }
      ))
      error = assert_raises(ModelCatalog::CompileError) { ModelCatalog::FileBase.compile(root: root) }
      assert_includes error.message, "missing required facts: api_format"
    end

    Dir.mktmpdir do |root|
      write(root, "10_base.yml", base_fragment(
        providers: { "openai_api" => { "base_url" => "https://api.openai.com", "api_format" => "telepathy" } }
      ))
      error = assert_raises(ModelCatalog::CompileError) { ModelCatalog::FileBase.compile(root: root) }
      assert_includes error.message, "names unknown api_format"
    end
  end

  # A workload with no entry of its own inherits the ceiling, so a newly
  # shipped workload is bounded from its first day rather than unbounded
  # until someone remembers it.
  test "an undeclared workload inherits the provider ceiling" do
    assert_equal 8, ModelCatalog.provider_concurrency_limit("openai_api")
    assert_equal 4, ModelCatalog.provider_concurrency_limit("openai_api", workload: "text_generation")
    assert_equal 6, ModelCatalog.provider_concurrency_limit("anthropic", workload: "text_generation")
    assert_equal 6, ModelCatalog.provider_concurrency_limit("anthropic", workload: "image_generation")
  end

  test "a provider declares its endpoint and no implementation fact" do
    with_root do |root|
      write(root, "10_base.yml", base_fragment(
        providers: { "openai_api" => {
          "base_url" => "https://api.openai.com", "protocol_route" => "responses_http_sse",
        } }
      ))

      error = assert_raises(ModelCatalog::CompileError) { ModelCatalog::FileBase.compile(root: root) }
      assert_includes error.message, "declares unknown facts: protocol_route"
    end
  end

  # The origin and the profile's relative wire path are two halves owned by
  # two sides; a trailing slash or an embedded query is how one side starts
  # carrying the other's.
  test "a configured provider endpoint must be an absolute origin with nothing trailing" do
    [
      "", "api.openai.com", "ftp://api.openai.com", "https://api.openai.com/",
      "https://api.openai.com?key=x", "https://api.openai.com#frag",
    ].each do |value|
      with_root do |root|
        write(root, "10_base.yml", base_fragment(providers: { "openai_api" => { "base_url" => value, "api_format" => "openai_responses", "concurrency_limit" => 8 } }))

        error = assert_raises(ModelCatalog::CompileError) { ModelCatalog::FileBase.compile(root: root) }
        assert_includes error.message, "base_url", "#{value.inspect} should have been refused"
      end
    end
  end

  test "a null provider endpoint compiles as unconfigured for its models" do
    with_root do |root|
      write(root, "10_base.yml", base_fragment(
        providers: { "custom" => {
          "base_url" => nil, "api_format" => "openai_responses", "concurrency_limit" => 8,
        } },
        models: { "custom/text" => text_entry }
      ))

      candidate = ModelCatalog::FileBase.compile(root: root)

      assert_nil candidate.providers.fetch("custom").fetch("base_url")
      assert candidate.models.key?("custom/text")
      assert_nil ModelCatalog.provider_base_url("custom", snapshot: candidate)
      assert_nil ModelCatalog.model_base_url("custom/text", snapshot: candidate)
    end
  end

  # The fixed prefix a provider's own routing needs is part of its origin,
  # because the profile's wire path cannot know it.
  test "a provider endpoint may carry the fixed prefix its routing needs" do
    with_root do |root|
      write(root, "10_base.yml", base_fragment(
        providers: { "openrouter" => { "base_url" => "https://openrouter.ai/api", "api_format" => "openrouter_chat", "concurrency_limit" => 8 } }
      ))

      candidate = ModelCatalog::FileBase.compile(root: root)
      assert_equal "https://openrouter.ai/api",
        candidate.providers.fetch("openrouter").fetch("base_url")
    end
  end

  test "the shipped production fragment tree compiles" do
    candidate = ModelCatalog::FileBase.compile
    assert_predicate candidate.providers, :present?
    assert_predicate candidate.models, :present?
  end

  private

    def with_env(pairs)
      previous = pairs.keys.to_h { |key| [key, ENV[key]] }
      pairs.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
      yield
    ensure
      previous.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    end
end
