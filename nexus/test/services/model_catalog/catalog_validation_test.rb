require "test_helper"
require "tmpdir"

# C2-2 WP4: deep catalog validation at snapshot compile.
#
# The rules it enforces changed direction on 2026-08-21. They used to be
# comparisons against a row the gem shipped for each model; the catalog is
# the only place a model exists now, so what an entry says IS the fact. What
# is left is shape, self-consistency, and the two things the WIRE decides —
# an input modality it has no media contract for, and a reasoning word it
# does not know.
class ModelCatalog::CatalogValidationTest < ActiveSupport::TestCase
  SCHEMA = ModelCatalog::FileBase::SCHEMA_VERSION

  def write_fragment(root, models:, providers: { "openai_api" => { "base_url" => "https://api.openai.com", "api_format" => "openai_responses", "concurrency_limit" => 8 } }, selectors: {})
    File.write(File.join(root, "10_base.yml"),
      {
        "schema_version" => SCHEMA,
        "providers" => providers,
        "models" => models,
        "selectors" => selectors,
      }.to_yaml)
  end

  def text_entry(overrides = {})
    {
      "capabilities" => {
        "input_modalities" => ["image"],
        "output_modalities" => ["text"],
        "limits" => { "combined_input_output_tokens" => 400_000, "output_tokens" => 128_000 },
      },
    }.deep_merge(overrides)
  end

  def compile(root)
    ModelCatalog::FileBase.compile(root: root, override_dir: nil)
  end

  # BILLING IS OPT-IN. A model nobody priced runs and is recorded unmetered rather than being
  # refused at admission: rates move faster than releases, and a deployment that wants cost computed
  # says so. Absent and explicitly-empty are the same declaration.
  test "a model nobody priced is unmetered, not unrunnable" do
    Dir.mktmpdir do |root|
      write_fragment(root, models: { "openai_api/text" => text_entry })

      entry = compile(root).models.fetch("openai_api/text")
      projection = ModelCatalog::EffectivePricing.project(entry: entry, account_unit: "USD")
      assert_predicate projection, :unmetered?
      assert_not projection.cost_unknown?
    end
  end

  test "a model entry composes with the wire its provider speaks" do
    Dir.mktmpdir do |root|
      write_fragment(root, models: { "openai_api/text" => text_entry })

      candidate = compile(root)
      assert_includes candidate.models.keys, "openai_api/text"
    end
  end

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

  test "a selector candidate must freeze an effort when its model has no catalog default" do
    Dir.mktmpdir do |root|
      entry = text_entry(
        "capabilities" => { "reasoning" => { "efforts" => %w[low medium] } }
      )
      write_fragment(
        root,
        models: { "openai_api/text" => entry },
        selectors: { "interactive_chat" => [{ "model" => "openai_api/text" }] }
      )

      error = assert_raises(ModelCatalog::CompileError) { compile(root) }
      assert_includes error.message, "requires reasoning_effort"
    end
  end

  # A MODEL MAY OVERRIDE ITS PROVIDER'S WIRE — that is how one provider
  # serves images and embeddings alongside its text lanes — but only with a
  # wire this gem adapted.
  test "a model naming an unadapted wire rejects the snapshot" do
    Dir.mktmpdir do |root|
      write_fragment(root, models: {
        "openai_api/text" => text_entry("api_format" => "telepathy"),
      })

      error = assert_raises(ModelCatalog::CompileError) { compile(root) }
      assert_includes error.message, "telepathy"
    end
  end

  # The two checks that used to live here — "the entry's provider disagrees
  # with the row" and "the entry's model pin disagrees with the row" — were
  # comparisons against a shipped table. A model under `anthropic/` composes
  # with anthropic's wire and pins its own name, so there is no second
  # statement left to disagree with.

  test "catalog input modalities beyond the audited profile reject; a subset is legal" do
    Dir.mktmpdir do |root|
      write_fragment(root, models: {
        "openai_api/text" => text_entry(
          "capabilities" => { "input_modalities" => ["image", "audio"] }
        ),
      })
      error = assert_raises(ModelCatalog::CompileError) { compile(root) }
      assert_includes error.message, "audio"
      assert_includes error.message, "no media contract on this wire"
    end

    Dir.mktmpdir do |root|
      write_fragment(root, models: {
        "openai_api/text" => text_entry("capabilities" => { "input_modalities" => [] }),
      })
      assert compile(root)
    end
  end

  # Output modalities and service tiers used to be checked against a
  # shipped row and refused for WIDENING it. They are the model's own facts
  # — one host offers a priority tier and another does not, on the same
  # wire — so what is checked now is that they are well-shaped and that
  # they reach the composed profile. The feature booleans are the wire's
  # (their own pins live in ProfileBuilderTest); only their shape is
  # checked here.
  test "output modalities and tiers are the model's own to state; a feature bit is boolean" do
    Dir.mktmpdir do |root|
      write_fragment(root, models: {
        "openai_api/text" => text_entry("capabilities" => { "service_tiers" => %w[priority] }),
      })
      candidate = compile(root)
      profile = ModelCatalog::ProfileBuilder.call(
        model_ref: "openai_api/text",
        provider: candidate.providers.fetch("openai_api"),
        model: candidate.models.fetch("openai_api/text")
      )
      assert_equal %w[priority], profile.service_tiers
    end

    Dir.mktmpdir do |root|
      write_fragment(root, models: {
        "openai_api/text" => text_entry("capabilities" => { "prompt_caching" => "yes" }),
      })
      error = assert_raises(ModelCatalog::CompileError) { compile(root) }
      assert_includes error.message, "must be boolean"
    end
  end

  # STRUCTURED OUTPUT IS THE WIRE'S DEFAULT (owner 2026-09-16): no
  # capability key claims it — `structured_output` is refused as the
  # unknown key it now is — and a row opts out of the wire's synthesized
  # descriptor with `output_format: false` under `generation_parameters`,
  # the one control whose absence a row may state (every other control is
  # a mapping or nothing).
  test "output_format: false opts out of the wire's structured output, and structured_output is no key" do
    Dir.mktmpdir do |root|
      write_fragment(root, models: {
        "openai_api/text" => text_entry("capabilities" => {
          "generation_parameters" => { "output_format" => false },
        }),
      })
      candidate = compile(root)
      profile = ModelCatalog::ProfileBuilder.call(
        model_ref: "openai_api/text",
        provider: candidate.providers.fetch("openai_api"),
        model: candidate.models.fetch("openai_api/text")
      )
      refute profile.generation_parameters.key?("output_format")
    end

    Dir.mktmpdir do |root|
      write_fragment(root, models: {
        "openai_api/text" => text_entry("capabilities" => {
          "generation_parameters" => { "temperature" => false },
        }),
      })
      error = assert_raises(ModelCatalog::CompileError) { compile(root) }
      assert_includes error.message, "generation parameter temperature must be a mapping"
    end

    Dir.mktmpdir do |root|
      write_fragment(root, models: {
        "openai_api/text" => text_entry("capabilities" => { "structured_output" => true }),
      })
      error = assert_raises(ModelCatalog::CompileError) { compile(root) }
      assert_includes error.message, "unknown capability keys structured_output"
    end
  end

  # ONE SHAPE FOR ONE KEY (owner 2026-09-16: parallel tool calls verified
  # by a direct test on eight cells; no row states a parallel fact).
  # `tool_calls` is a boolean like the three feature booleans: silent is
  # the wire's default, `false` the one opt-out, `true` allowed and saying
  # nothing more. The retired mapping `{parallel: false}` is refused at
  # compile as the unknown shape it now is, never read as a fact.
  test "tool_calls is boolean, and the retired parallel mapping is refused at compile" do
    Dir.mktmpdir do |root|
      write_fragment(root, models: {
        "openai_api/text" => text_entry("capabilities" => { "tool_calls" => true }),
        "openai_api/text-without-tools" => text_entry("capabilities" => { "tool_calls" => false }),
      })
      candidate = compile(root)
      profile = ->(ref) do
        ModelCatalog::ProfileBuilder.call(
          model_ref: ref, provider: candidate.providers.fetch("openai_api"), model: candidate.models.fetch(ref)
        )
      end

      assert profile.call("openai_api/text").capability_enabled?("tool_calls")
      refute profile.call("openai_api/text-without-tools").capability_enabled?("tool_calls"), "false is the opt-out"
    end

    [{ "parallel" => false }, { "parallel" => true }, {}, "yes"].each do |declared|
      Dir.mktmpdir do |root|
        write_fragment(root, models: {
          "openai_api/text" => text_entry("capabilities" => { "tool_calls" => declared }),
        })
        error = assert_raises(ModelCatalog::CompileError, declared.inspect) { compile(root) }
        assert_includes error.message, "capability tool_calls must be boolean", declared.inspect
      end
    end
  end

  # VOICES AND RANGES VARY BY MODEL on one wire, so a declaration here
  # REPLACES the format's table rather than being checked against it. What
  # is still checked is that the descriptor means something: a default
  # outside its own values is a typo in every deployment that copies it.
  test "generation parameter descriptors must agree with themselves" do
    cases = [
      [{ "voice" => generation_parameter("string", "echo", %w[alloy shimmer]) },
       "is not among its allowed values"],
      [{ "voice" => generation_parameter("string", "alloy", []) },
       "non-empty unique list"],
      [{ "speed" => { "kind" => "number", "default" => 4.0, "minimum" => 0.25,
                      "maximum" => 2.0, "allowed_values" => nil } },
       "outside"],
      [{ "speed" => { "kind" => "number", "default" => nil, "minimum" => 2.0,
                      "maximum" => 0.25, "allowed_values" => nil } },
       "minimum exceeds its maximum"],
    ]

    cases.each do |parameters, message|
      Dir.mktmpdir do |root|
        write_fragment(root, models: {
          "openai_api/speech" => {
            "api_format" => "openai_audio_speech",
            "capabilities" => {
              "input_modalities" => [],
              "output_modalities" => ["audio"],
              "limits" => { "input_bytes" => 2_000, "input_characters" => 4_096 },
              "generation_parameters" => parameters,
            },
          },
        })
        error = assert_raises(ModelCatalog::CompileError) { compile(root) }
        assert_includes error.message, message
      end
    end
  end

  # AVAILABLE, WITH NOTHING SENT UNLESS ASKED — the declaration an enumerated
  # control could not make. A default rides EVERY turn, so demanding one from
  # anything carrying `allowed_values` meant a control had to be either forced
  # on every caller or not offered at all. Two real lanes lost a real control
  # to that: transcription's `language`, where the endpoint detects one when
  # none is sent, and Anthropic's `output_format`, whose protocol accepts a
  # single value nobody wants on a plain turn. The range branch had always
  # read a nil default this way.
  test "an enumerated control may offer itself without imposing a default" do
    Dir.mktmpdir do |root|
      write_fragment(root, models: {
        "openai_api/speech" => {
          "api_format" => "openai_audio_speech",
          "capabilities" => {
            "input_modalities" => [],
            "output_modalities" => ["audio"],
            "limits" => { "input_bytes" => 2_000, "input_characters" => 4_096 },
            "generation_parameters" => {
              "voice" => generation_parameter("string", nil, %w[alloy shimmer]),
            },
          },
        },
      })

      voice = compile(root).models.fetch("openai_api/speech")
        .fetch("capabilities").fetch("generation_parameters").fetch("voice")
      assert_equal %w[alloy shimmer], voice.fetch("allowed_values")
      assert_nil voice.fetch("default")
    end
  end

  # And the guard is exactly that narrow: a default that IS present still has
  # to be one of the values, which is the typo this check exists to catch.
  test "a present default is still held to the allowed values" do
    Dir.mktmpdir do |root|
      write_fragment(root, models: {
        "openai_api/speech" => {
          "api_format" => "openai_audio_speech",
          "capabilities" => {
            "input_modalities" => [],
            "output_modalities" => ["audio"],
            "limits" => { "input_bytes" => 2_000, "input_characters" => 4_096 },
            "generation_parameters" => {
              "voice" => generation_parameter("string", "echo", %w[alloy shimmer]),
            },
          },
        },
      })

      error = assert_raises(ModelCatalog::CompileError) { compile(root) }
      assert_includes error.message, "is not among its allowed values"
    end
  end

  # The same rule from the other side: an embeddings wire carries no media
  # at all, so a model on it may declare no input modality.
  test "a modality bit without a media contract on its wire cannot authorize media" do
    Dir.mktmpdir do |root|
      write_fragment(root,
        providers: { "gemini" => { "base_url" => "https://generativelanguage.googleapis.com",
                                   "api_format" => "gemini_embeddings", "concurrency_limit" => 8 } },
        models: { "gemini/embedding" => {
          "capabilities" => closed_capabilities(
            output_modalities: ["embedding"], limits: { "input_tokens" => 2_048 }
          ).merge("input_modalities" => ["image"]),
        } })

      error = assert_raises(ModelCatalog::CompileError) { compile(root) }
      assert_includes error.message, "no media contract on this wire"
    end
  end

  # A DEADLINE IS SETTABLE FROM OUTSIDE, which it was not before: it used to
  # come only from a shipped row, so a deployment that knew its own provider
  # was slower had nowhere to say so. The workload default still applies to
  # every model that stays silent.
  test "a model may state its own deadline, and inherits its workload's otherwise" do
    Dir.mktmpdir do |root|
      write_fragment(root, models: {
        "openai_api/text" => text_entry("deadline_seconds" => 300),
        "openai_api/text-default-deadline" => text_entry,
      })

      candidate = compile(root)
      built = ->(ref) {
        ModelCatalog::ProfileBuilder.call(
          model_ref: ref, provider: candidate.providers.fetch("openai_api"),
          model: candidate.models.fetch(ref)
        )
      }
      assert_equal 300, built.("openai_api/text").total_execution_deadline_seconds
      assert_equal SimpleInference::ApiFormat::WORKLOAD_DEADLINE_SECONDS.fetch("text_generation"),
        built.("openai_api/text-default-deadline").total_execution_deadline_seconds
    end
  end

  test "unknown entry keys and unknown capability keys reject" do
    Dir.mktmpdir do |root|
      write_fragment(root, models: { "openai_api/text" => text_entry("surprise" => 1) })
      error = assert_raises(ModelCatalog::CompileError) { compile(root) }
      assert_includes error.message, "surprise"
    end

    Dir.mktmpdir do |root|
      write_fragment(root, models: {
        "openai_api/text" => text_entry("capabilities" => { "tools" => true }),
      })
      error = assert_raises(ModelCatalog::CompileError) { compile(root) }
      assert_includes error.message, "tools"
    end
  end

  test "limits carry only the closed key set with their reviewed value shapes" do
    Dir.mktmpdir do |root|
      write_fragment(root, models: {
        "openai_api/text" => text_entry(
          "capabilities" => { "limits" => { "output_bytes" => 5 } }
        ),
      })
      error = assert_raises(ModelCatalog::CompileError) { compile(root) }
      assert_includes error.message, "output_bytes"
    end

    Dir.mktmpdir do |root|
      write_fragment(root, models: {
        "openai_api/text" => text_entry(
          "capabilities" => { "limits" => { "input_tokens" => -1 } }
        ),
      })
      error = assert_raises(ModelCatalog::CompileError) { compile(root) }
      assert_includes error.message, "input_tokens"
    end
  end

  test "required capability mappings cannot be null" do
    ["input_modalities", "limits"].each do |key|
      Dir.mktmpdir do |root|
        entry = text_entry
        entry.fetch("capabilities")[key] = nil
        write_fragment(root, models: { "openai_api/text" => entry })

        error = assert_raises(ModelCatalog::CompileError) { compile(root) }
        assert_includes error.message, key
      end
    end
  end

  test "embedding dimensions must be a unique set of positive integers" do
    [[4_096, 4_096], [0], ["768"], []].each do |dimensions|
      Dir.mktmpdir do |root|
        write_fragment(root,
          providers: { "gemini" => { "base_url" => "https://generativelanguage.googleapis.com",
                                     "api_format" => "gemini_embeddings", "concurrency_limit" => 8 } },
          models: { "gemini/embedding" => {
            "capabilities" => closed_capabilities(
              output_modalities: ["embedding"],
              limits: { "input_tokens" => 2_048, "embedding_dimensions" => dimensions }
            ),
          } })
        error = assert_raises(ModelCatalog::CompileError) { compile(root) }
        assert_includes error.message, "unique positive integers"
      end
    end
  end

  # The shared-window contract, re-cut 2026-08-21: a window that input and
  # output both draw from admits companions that bound a TERM inside the sum
  # (the output ceiling) and this side's soft advisory threshold — but never a
  # second answer to the same question, and never a dropped bound.
  test "a shared window admits its companions and still refuses a rival input window" do
    Dir.mktmpdir do |root|
      write_fragment(root, models: { "openai_api/text" => text_entry(
        "capabilities" => { "limits" => {
          "combined_input_output_tokens" => 400_000, "output_tokens" => 128_000,
          "effective_input_tokens" => 100_000,
        } }
      ) })
      assert compile(root), "the soft threshold is this side's alone and needs no profile key"
    end

    Dir.mktmpdir do |root|
      rival = text_entry
      rival.dig("capabilities", "limits")["input_tokens"] = 400_000
      write_fragment(root, models: { "openai_api/text" => rival })
      error = assert_raises(ModelCatalog::CompileError) { compile(root) }
      assert_includes error.message, "cannot mix independent limits"
    end

    Dir.mktmpdir do |root|
      write_fragment(root, models: { "openai_api/text" => text_entry(
        "capabilities" => { "limits" => {
          "combined_input_output_tokens" => 400_000, "output_tokens" => 128_000,
          "effective_input_tokens" => 500_000,
        } }
      ) })
      error = assert_raises(ModelCatalog::CompileError) { compile(root) }
      assert_includes error.message, "exceeds the hard window",
        "a SOFT threshold above the hard one is not soft, it is nonsense"
    end
  end

  # THE CATALOG IS THE CEILING NOW. This used to check two things against a
  # shipped row — that the entry restated every bound the row declared, and
  # that no bound exceeded it. There is no second number to exceed; a model
  # that states no window gets the conservative default instead.
  test "a text model that states no window gets the conservative one" do
    Dir.mktmpdir do |root|
      write_fragment(root, models: { "openai_api/text" => {} })

      candidate = compile(root)
      profile = ModelCatalog::ProfileBuilder.call(
        model_ref: "openai_api/text",
        provider: candidate.providers.fetch("openai_api"),
        model: candidate.models.fetch("openai_api/text")
      )
      assert_equal SimpleInference::ApiFormat::DEFAULT_INPUT_TOKENS,
        profile.local_safety_limits.input_tokens
    end
  end

  test "openrouter carries its combined prepared-input and requested-output bound in production" do
    entry = {
      "capabilities" => closed_capabilities(
        output_modalities: ["text"],
        limits: { "combined_input_output_tokens" => 200_000 }
      ),
    }

    Dir.mktmpdir do |root|
      write_fragment(root,
        providers: { "openrouter" => { "base_url" => "https://openrouter.ai/api", "api_format" => "openrouter_chat", "concurrency_limit" => 8 } },
        models: { "openrouter/vendor/text" => entry })
      assert compile(root)
    end
  end

  # Two tests stood here: "a profile with no numeric authority cannot invent
  # a catalog limit" and "a catalog limit may not exceed the profile's
  # platform cap". Both compared the entry to a shipped row. A deployment
  # states its own bounds now — that is the whole point — and what remains is
  # that they are positive integers and agree with each other.

  test "reasoning blocks are content-validated against closed vocabularies" do
    Dir.mktmpdir do |root|
      write_fragment(root, models: {
        "openai_api/text" => text_entry(
          "capabilities" => { "reasoning" => { "efforts" => ["low", "galaxy"] } }
        ),
      })
      error = assert_raises(ModelCatalog::CompileError) { compile(root) }
      assert_includes error.message, "galaxy"
    end

    Dir.mktmpdir do |root|
      write_fragment(root, models: {
        "openai_api/text" => text_entry(
          "capabilities" => { "reasoning" => { "efforts" => ["low"], "default_effort" => "high" } }
        ),
      })
      error = assert_raises(ModelCatalog::CompileError) { compile(root) }
      assert_includes error.message, "default_effort"
    end

    Dir.mktmpdir do |root|
      write_fragment(root, models: {
        "openai_api/text" => text_entry(
          "capabilities" => { "reasoning" => { "efforts" => ["ultra"] } }
        ),
      })
      error = assert_raises(ModelCatalog::CompileError) { compile(root) }
      assert_includes error.message, "its wire does not know"
    end

    Dir.mktmpdir do |root|
      write_fragment(root, models: {
        "openai_api/text" => text_entry(
          "capabilities" => { "reasoning" => { "budget" => "reasoning_max_tokens" } }
        ),
      })
      error = assert_raises(ModelCatalog::CompileError) { compile(root) }
      assert_includes error.message, "reasoning budget"
    end
  end

  test "codex never adapted ultra and the catalog cannot author it" do
    efforts = SimpleInference::ApiFormat.defaults("codex_responses")[:reasoning_options]
      .fetch("efforts")
    refute_includes efforts, "ultra"

    Dir.mktmpdir do |root|
      write_fragment(root,
        providers: { "codex_subscription" => { "base_url" => "https://chatgpt.com/backend-api/codex", "api_format" => "codex_responses", "concurrency_limit" => 8 } },
        models: {
          "codex_subscription/text" => {
            "capabilities" => closed_capabilities(
              output_modalities: ["text"],
              limits: { "combined_input_output_tokens" => 1_050_000, "effective_input_tokens" => 272_000,
                       "output_tokens" => 128_000 }
            ).merge(
              "reasoning" => { "efforts" => ["ultra"] },
            ),
          },
        })
      error = assert_raises(ModelCatalog::CompileError) { compile(root) }
      assert_includes error.message, "ultra"
    end
  end

  # THE POINT OF THE ROUND, stated as a test: a model entry may be empty.
  # It inherits its provider's wire and every default that wire decides, and
  # an operator adding a model writes one line.
  test "a model entry may say nothing at all and still compile" do
    Dir.mktmpdir do |root|
      write_fragment(root, models: { "openai_api/text" => {} })

      candidate = compile(root)
      assert_equal({}, candidate.models.fetch("openai_api/text"))
    end
  end


  private

    def generation_parameter(kind, default, allowed_values)
      {
        "kind" => kind,
        "default" => default,
        "minimum" => nil,
        "maximum" => nil,
        "allowed_values" => allowed_values,
      }
    end

    def closed_capabilities(output_modalities:, limits: {})
      {
        "input_modalities" => [],
        "output_modalities" => output_modalities,
        "limits" => limits,
      }
    end
  # The compile-time selector rule IS the accept-time derivation: a lane whose reasoning is declared
  # on-by-default needs no pinned effort, and the two sides cannot drift into disagreeing rules
  # again. DeepSeek is the shipped lane whose registry profile declares default_enabled.
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

  # The replay capability's vocabulary is closed on TWO axes: the format
  # list, and the wire each native format is speakable on — a mismatch
  # would silently emit blocks a foreign protocol forwards to a certain
  # provider refusal.
  test "reasoning_replay validates its closed vocabulary and its wire" do
    Dir.mktmpdir do |root|
      entry = text_entry(
        "capabilities" => { "reasoning_replay" => { "format" => "responses_reasoning" } }
      )
      write_fragment(root, models: { "openai_api/text" => entry })
      assert_includes compile(root).models.keys, "openai_api/text"
    end

    Dir.mktmpdir do |root|
      entry = text_entry(
        "capabilities" => { "reasoning_replay" => { "format" => "anthropic_thinking" } }
      )
      write_fragment(root, models: { "openai_api/text" => entry })
      error = assert_raises(ModelCatalog::CompileError) { compile(root) }
      assert_includes error.message, "not something the openai_responses wire speaks"
    end

    Dir.mktmpdir do |root|
      entry = text_entry(
        "capabilities" => { "reasoning_replay" => { "format" => "responses_reasonning" } }
      )
      write_fragment(root, models: { "openai_api/text" => entry })
      error = assert_raises(ModelCatalog::CompileError) { compile(root) }
      assert_includes error.message, "format must be one of"
    end

    # The format is the row's one replay fact: the mode is the kernel's
    # (`all` on every row), so the retired mode flags are unknown keys.
    [{ "budget" => 1 }, { "keeps_prior_turns" => true }, { "last_turn_only" => true }].each do |extra|
      Dir.mktmpdir do |root|
        entry = text_entry(
          "capabilities" => { "reasoning_replay" => { "format" => "responses_reasoning" }.merge(extra) }
        )
        write_fragment(root, models: { "openai_api/text" => entry })
        error = assert_raises(ModelCatalog::CompileError) { compile(root) }
        assert_includes error.message, "unknown reasoning_replay keys #{extra.keys.sole}"
      end
    end

    # The vendor's refusal of a tool round sent back without its reasoning
    # is a yes or a no: a word there is a typo, never a lane's rule.
    Dir.mktmpdir do |root|
      entry = text_entry("capabilities" => { "reasoning_replay" => {
        "format" => "responses_reasoning", "required_for_tool_rounds" => "yes",
      } })
      write_fragment(root, models: { "openai_api/text" => entry })
      error = assert_raises(ModelCatalog::CompileError) { compile(root) }
      assert_includes error.message, "reasoning_replay required_for_tool_rounds must be boolean"
    end
  end

  # The two field-shaped formats are each one wire family's: the chat
  # assistant message's reasoning field on the broker's chat wire, the
  # plain-text reasoning item on DeepSeek's Responses route.
  test "the chat and plain-text reasoning formats are speakable on their own wires only" do
    broker = { "openrouter" => { "base_url" => "https://openrouter.ai/api/v1", "api_format" => "openrouter_chat", "concurrency_limit" => 8 } }
    deepseek = { "deepseek" => { "base_url" => "https://api.deepseek.com", "api_format" => "deepseek_responses", "concurrency_limit" => 8 } }
    [
      [broker, "openrouter/x/m", "chat_reasoning"],
      [deepseek, "deepseek/m", "responses_reasoning_text"],
    ].each do |providers, ref, format|
      Dir.mktmpdir do |root|
        entry = text_entry("capabilities" => { "input_modalities" => [], "reasoning_replay" => { "format" => format } })
        write_fragment(root, providers: providers, models: { ref => entry })
        assert_includes compile(root).models.keys, ref, "#{format} is the #{ref} wire's"
      end

      Dir.mktmpdir do |root|
        entry = text_entry("capabilities" => { "reasoning_replay" => { "format" => format } })
        write_fragment(root, models: { "openai_api/text" => entry })
        error = assert_raises(ModelCatalog::CompileError) { compile(root) }
        assert_includes error.message, "#{format} is not something the openai_responses wire speaks"
      end
    end
  end

  test "a Responses row's reasoning context is a member of the wire's vocabulary" do
    Dir.mktmpdir do |root|
      entry = text_entry(
        "capabilities" => { "reasoning" => { "efforts" => %w[medium], "contexts" => %w[all_turns], "default_context" => "all_turns" } }
      )
      write_fragment(root, models: { "openai_api/text" => entry })
      assert_equal "all_turns", compile(root).models.fetch("openai_api/text").dig("capabilities", "reasoning", "default_context")
    end

    Dir.mktmpdir do |root|
      entry = text_entry(
        "capabilities" => { "reasoning" => { "efforts" => %w[medium], "contexts" => %w[every_turn] } }
      )
      write_fragment(root, models: { "openai_api/text" => entry })
      assert_raises(ModelCatalog::CompileError) { compile(root) }
    end
  end
end
