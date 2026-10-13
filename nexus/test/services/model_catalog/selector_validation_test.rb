require "test_helper"
require "tmpdir"
require_relative "../../test_helpers/model_catalog_validation"

class ModelCatalog::SelectorValidationTest < ActiveSupport::TestCase
  include ModelCatalog::ValidationTestSupport

  test "a selector is a closed ordered list of exact text candidates and reviewed efforts" do
    Dir.mktmpdir do |root|
      entry = text_entry(
        "capabilities" => {
          "reasoning" => {
            "efforts" => %w[low medium],
            "default_effort" => "medium",
          },
        }
      )
      write_fragment(
        root,
        models: { "openai_api/text" => entry },
        selectors: {
          "interactive_chat" => [
            { "model" => "openai_api/text", "reasoning_effort" => "low" },
            { "model" => "openai_api/text" },
          ],
        }
      )

      selector = compile(root).selectors.fetch("interactive_chat")
      assert_equal %w[low], selector.filter_map { |candidate| candidate["reasoning_effort"] }
      assert_equal ["openai_api/text", "openai_api/text"], selector.pluck("model")
    end
  end

  test "malformed selector names, candidates, references, workloads, and efforts fail fast" do
    image_entry = {
      "api_format" => "openai_images",
      "capabilities" => closed_capabilities(
        output_modalities: ["image"], limits: { "result_count" => 1 }
      ),
    }
    reasoning_entry = text_entry(
      "capabilities" => {
        "reasoning" => { "efforts" => ["low"], "default_effort" => "low" },
      }
    )
    cases = [
      [{ "Bad Selector" => [{ "model" => "openai_api/text" }] }, "selector name"],
      [{ "empty" => [] }, "must not be empty"],
      [{ "scalar" => [42] }, "candidate 0 must be a mapping"],
      [{ "open" => [{ "model" => "openai_api/text", "fallback" => true }] }, "unknown keys"],
      [{ "missing" => [{ "reasoning_effort" => "low" }] }, "exact model ref"],
      [{ "unknown" => [{ "model" => "openai_api/not-present" }] }, "unknown model"],
      [{ "non_text" => [{ "model" => "openai_api/image" }] }, "text_generation"],
      [{ "bad_effort" => [{ "model" => "openai_api/text", "reasoning_effort" => "high" }] },
       "reasoning effort"],
    ]

    cases.each do |selectors, message|
      Dir.mktmpdir do |root|
        write_fragment(
          root,
          models: {
            "openai_api/text" => reasoning_entry,
            "openai_api/image" => image_entry,
          },
          selectors: selectors
        )

        error = assert_raises(ModelCatalog::CompileError) { compile(root) }
        assert_includes error.message, message
      end
    end
  end

  test "a selector without a catalog effort default leaves effort to the provider" do
    Dir.mktmpdir do |root|
      entry = text_entry(
        "capabilities" => { "reasoning" => { "efforts" => %w[low medium] } }
      )
      write_fragment(
        root,
        models: { "openai_api/text" => entry },
        selectors: { "interactive_chat" => [{ "model" => "openai_api/text" }] }
      )

      assert_equal [{ "model" => "openai_api/text" }], compile(root).selectors.fetch("interactive_chat")
    end
  end

  # The compile-time selector rule IS the accept-time derivation: a lane whose reasoning is declared
  # on-by-default needs no pinned effort, and the two sides cannot drift into disagreeing rules
  # again. Enablement is the catalog's default, separate from the profile vocabulary.
  test "a selector candidate on a default-enabled lane compiles without a pinned effort" do
    Dir.mktmpdir do |root|
      entry = {
        "capabilities" => {
          "input_modalities" => [],
          "output_modalities" => ["text"],
          "limits" => { "combined_input_output_tokens" => 1_000_000, "output_tokens" => 384_000 },
          "reasoning" => { "efforts" => %w[low medium], "default_enabled" => true },
        },
      }
      write_fragment(
        root,
        providers: { "deepseek" => { "base_url" => "https://api.deepseek.com", "api_format" => "deepseek_responses", "concurrency_limit" => 8 } },
        models: { "deepseek/text" => entry },
        selectors: { "interactive_chat" => [{ "model" => "deepseek/text" }] }
      )

      selector = compile(root).selectors.fetch("interactive_chat")
      assert_equal ["deepseek/text"], selector.pluck("model")

      _value, refusal = Nexus::EffectiveReasoning.derive(
        entry.fetch("capabilities").fetch("reasoning"), nil
      )
      assert_nil refusal, "the compiler and the resolver run the same derivation"
    end
  end
end
