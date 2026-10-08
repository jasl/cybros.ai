require "test_helper"
require "tmpdir"

# THE SAMPLES ARE THE DOCUMENTATION, and documentation has two ways to fail.
#
# It can stop being true — their predecessor shipped three of these
# (`config.d/models.yml.sample`, `providers.yml.sample`,
# `model_selectors.yml.sample`) and this rewrite had quietly lost them: the
# override MECHANISM survived, the teaching did not.
#
# And it can DO something. Copying a sample is the intended way to start one,
# so a sample whose body is live changes the catalog the moment it is copied:
# these three added two fake providers, three models, and two selectors —
# and because an overlay entry replaces WHOLESALE, the selectors it added
# silently took over the ones the repository shipped at the time.
#
# So the body is commented out and this pins both halves: copying changes
# nothing, and uncommenting still compiles.
class ModelCatalog::ConfigSamplesTest < ActiveSupport::TestCase
  # Every sample in config.d: one per catalog section, which is the whole
  # convention. A fourth that merged all three into one file sat outside this
  # guard and was deleted — a directory with two conventions is how the
  # teaching got lost in the first place.
  SAMPLES = %w[providers models model_selectors].freeze
  SHIPPED_ROOT = Rails.root.join("config/model_catalog")

  # What an operator ends up with after doing it by hand: the file as shipped,
  # with the comment prefix dropped from the example. The examples are written
  # so this leaves valid YAML — their own explanatory lines are indented
  # INSIDE the commented block, so they survive as YAML comments.
  def uncommented(name)
    "schema_version: #{ModelCatalog::FileBase::SCHEMA_VERSION}\n" +
      body(name).lines.map { |line| line.sub(/\A# ?/, "") }.join
  end

  # Everything below the one live line. The header above it is prose about
  # the file itself and is not part of the example.
  def body(name)
    text = File.read(Rails.root.join("config.d/#{name}.yml.sample"))
    text.split(/^schema_version:.*\n/, 2).fetch(1)
  end

  def compile(override_dir)
    ModelCatalog::FileBase.compile(
      root: SHIPPED_ROOT, override_dir: override_dir, env: "development"
    )
  end

  def with_overrides(contents)
    Dir.mktmpdir do |dir|
      contents.each { |name, text| File.write(File.join(dir, "#{name}.yml"), text) }
      yield compile(dir)
    end
  end

  # THE HALF THE OWNER ASKED FOR. Copying all three verbatim must leave the
  # catalog exactly as shipped — not merely "still valid". Compare the actual
  # published data so nothing was added, dropped or replaced.
  test "copying the samples verbatim changes nothing at all" do
    shipped = compile(nil)
    copied = SAMPLES.to_h do |name|
      [name, File.read(Rails.root.join("config.d/#{name}.yml.sample"))]
    end

    with_overrides(copied) do |candidate|
      assert_equal shipped.providers, candidate.providers,
        "a sample that changes the catalog on copy ships deployment decisions nobody made"
      assert_equal shipped.models, candidate.models
      assert_equal shipped.selectors, candidate.selectors
    end
  end

  # The repository ships no selector, so the sample's names define nothing
  # until an operator uncomments them. This used to pin the opposite — that
  # copying did not clobber the shipped `interactive_chat` — and the fact it
  # protected is better stated directly.
  test "a verbatim copy leaves the catalog with no selector at all" do
    assert_empty compile(nil).selectors

    with_overrides(
      "model_selectors" => File.read(Rails.root.join("config.d/model_selectors.yml.sample"))
    ) do |candidate|
      assert_empty candidate.selectors
    end
  end

  # THE OTHER HALF: the examples must still be true. Uncommenting is a
  # mechanical prefix strip, so this exercises the same bytes an operator
  # would end up with.
  test "uncommenting the samples compiles, and every option they show still means something" do
    with_overrides(SAMPLES.to_h { |name| [name, uncommented(name)] }) do |candidate|
      # The one-line model entry is the round's headline: a deployment adds a
      # model by naming it, and inherits everything its provider's wire
      # decides.
      assert_equal({}, candidate.models.fetch("local/example-text"))

      # The bare-string selector candidate is the predecessor's shorthand,
      # restored — and it mixes with the mapping form in one list.
      assert_equal [{ "model" => "local/qwen3.8-flash-next" }, { "model" => "local/qwen3.8-27b" }],
        candidate.selectors.fetch("interactive_chat")
      assert_equal [{ "model" => "local/qwen3.6-35b-a3b" }], candidate.selectors.fetch("scheduled_tasks")
      assert_equal [{ "model" => "local/qwen3.5-9b" }], candidate.selectors.fetch("visual_recognition")
      assert_equal [{ "model" => "local/example-options", "reasoning_enabled" => true, "reasoning_effort" => "low" },
                    { "model" => "local/example-text" }],
        candidate.selectors.fetch("summarization")

      # And the fully-stated entries reach a composed profile, which is the
      # real proof that every option they show still does something.
      profile = ModelCatalog::ProfileBuilder.call(
        model_ref: "local/example-options",
        provider: candidate.providers.fetch("local"),
        model: candidate.models.fetch("local/example-options")
      )
      assert_equal "example-text-model", profile.model_pin
      assert_equal "none", profile.credential_lane
      assert_equal 131_072, profile.local_safety_limits.input_tokens
      # Asserted on the compiled ENTRY as well as the profile: 3600 is also the
      # text_generation default, so the profile fact alone would hold whether
      # or not the sample still shows the option.
      assert_equal 3_600, candidate.models.fetch("local/example-options").fetch("deadline_seconds")
      assert_equal 3_600, profile.total_execution_deadline_seconds
      assert_equal %w[low medium high], profile.reasoning_options.fetch("efforts")
      # The sample's one feature line is the opt-out; the wire supplies the rest.
      refute profile.capability_enabled?("tool_calls"), "the sample opts out of tools"
      assert profile.capability_enabled?("streaming"), "the chat wire streams; no line needed"
      assert profile.capability_enabled?("prompt_caching"), "the chat wire caches a stable prefix; no line needed"
      assert profile.generation_parameters.key?("output_format"), "the chat wire carries response_format"
      assert_equal %w[image], profile.input_modalities

      # The example provider states every optional provider fact. It carries no
      # model, so nothing composes against it — these read the compiled entry,
      # which is what proves the compiler still recognizes each key rather
      # than dropping it on the floor.
      example = candidate.providers.fetch("example")
      assert_equal 4, example.fetch("concurrency_limit")
      assert_equal({ "text_generation" => 2 }, example.fetch("workload_concurrency_limits"))
      assert_equal %w[standard priority], example.fetch("service_tiers")
      assert_equal "An Example Provider", example.fetch("display_name")
      assert_equal "cost_in_usd_ticks", example.fetch("native_cost_contract").fetch("amount_field")

      # And the contract is only PROVEN by a lane that uses it, so the same
      # block is composed onto a model to show it reaches a profile.
      priced = ModelCatalog::ProfileBuilder.call(
        model_ref: "example/probe", provider: example, model: {}
      )
      assert_equal "USD", priced.native_cost_contract.unit

      # The format override is what lets one provider serve a second wire.
      image = ModelCatalog::ProfileBuilder.call(
        model_ref: "local/example-image",
        provider: candidate.providers.fetch("local"),
        model: candidate.models.fetch("local/example-image")
      )
      assert_equal "image_generation", image.workload
    end
  end

  test "the local Qwen examples use explicit server windows and exact wire ids" do
    ids = {
      "local/qwen3.8-flash-next" => "Qwen/Qwen3.8-Flash-Next",
      "local/qwen3.8-27b" => "Qwen/Qwen3.8-27B",
      "local/qwen3.6-35b-a3b" => "Qwen/Qwen3.6-35B-A3B",
      "local/qwen3.5-9b" => "Qwen/Qwen3.5-9B",
    }
    counters = {
      "local/qwen3.8-flash-next" => "Qwen/Qwen3.8-Flash-Next",
      "local/qwen3.8-27b" => "Qwen/Qwen3.8-Flash-Next",
      "local/qwen3.6-35b-a3b" => "Qwen/Qwen3.5-9B",
      "local/qwen3.5-9b" => "Qwen/Qwen3.5-9B",
    }
    with_overrides(SAMPLES.to_h { |name| [name, uncommented(name)] }) do |candidate|
      provider = candidate.providers.fetch("local")
      assert_equal 1, provider.fetch("concurrency_limit")
      ids.each do |ref, wire_id|
        profile = ModelCatalog::ProfileBuilder.call(model_ref: ref, provider: provider,
          model: candidate.models.fetch(ref))

        assert_equal wire_id, profile.model_pin
        assert_equal "huggingface", profile.token_counter.kind
        assert_equal counters.fetch(ref), profile.token_counter.tokenizer_id
        assert_equal "openai_compatible_chat", profile.adapter_profile
        assert_equal "qwen3_5", profile.wire_options[:prompt_format]
        assert_equal "chat_template_kwargs", profile.wire_options[:reasoning_control]
        assert_equal "none", profile.credential_lane
        assert_equal 32_768, profile.local_safety_limits.combined_input_output_tokens
        assert_equal 4_096, profile.local_safety_limits.output_tokens
        assert_equal(ref == "local/qwen3.5-9b" ? %w[image] : [], profile.input_modalities)
        reasoning = candidate.models.fetch(ref).dig("capabilities", "reasoning")
        selected, refusal = Nexus::EffectiveReasoning.derive(reasoning, nil)
        assert_nil refusal
        assert_equal true, reasoning.fetch("disable_supported")
        assert_equal(ref != "local/qwen3.5-9b", selected.enabled)
        if %w[local/qwen3.8-flash-next local/qwen3.8-27b].include?(ref)
          assert_equal %w[low medium xhigh], profile.reasoning_options.fetch("efforts")
          assert_equal "low", selected.effort
        else
          assert_empty profile.reasoning_options, "a switch-only model has no effort vocabulary"
          assert_nil selected.effort
        end
      end
    end
  end

  # The strip is only mechanical if nothing in the body is live. A stray
  # uncommented line would take effect on copy AND would have been invisible
  # to the digest test if it happened to be a no-op today.
  test "no sample carries a live line below its schema version" do
    SAMPLES.each do |name|
      live = body(name).lines.reject { |line| line.strip.empty? || line.start_with?("#") }

      assert_empty live, "#{name}.yml.sample has uncommented content below schema_version"
    end
  end
end
