require "test_helper"
require "tempfile"
require "tmpdir"

# C2-4 WP-B: the local profile/token-count estimate. Exact lanes use their
# declared tokenizer; other lanes return a conservative advisory value.
class ModelRequests::TokenCountTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:cybros)
    DevModelLane.ensure_enabled!(@account)
  end

  def profile(model_ref) = DevModelLane.profile_for(model_ref)

  # A lane with no counter declared at all, for the bound's own tests.
  def bare_profile
    SimpleInference::ExecutionProfile.new(
      profile_id: "test.bare.v1", provider_id: "dev",
      adapter_profile: "openai_responses", protocol_route: "responses_http_sse",
      workload: "text_generation", model_pin: "mock-text", credential_lane: "none",
      total_execution_deadline_seconds: 600,
      primary_execution_pair: SimpleInference::ExecutionProfile::MODEL_RUNNER_ASYNC_HTTP_PAIR,
      allowed_execution_pairs: [SimpleInference::ExecutionProfile::MODEL_RUNNER_ASYNC_HTTP_PAIR]
    )
  end

  test "an openai-family lane counts exactly through its declared encoding" do
    result = ModelRequests::TokenCount.count(
      profile: profile("openai_api/gpt-6.1-sol"),
      segments: ["The quick brown fox jumps over the lazy dog."]
    )

    assert_predicate result, :counted?
    assert_predicate result, :exact?
    assert_equal Tiktoken.get_encoding("o200k_base").encode_ordinary(
      "The quick brown fox jumps over the lazy dog."
    ).length + envelope(1), result.tokens
  end

  # The dangerous direction, pinned: a caller who pastes control markup is
  # charged what the escape costs, not what an honoring encoder would report.
  test "special-token markup is counted as the literal text it becomes" do
    markup = "<|endoftext|>" * 20
    result = ModelRequests::TokenCount.count(
      profile: profile("openai_api/gpt-6.1-sol"), segments: [markup]
    )

    honored = Tiktoken.get_encoding("o200k_base").encode_with_special_tokens(markup).length
    assert_operator result.tokens, :>, honored,
      "counting must not honor caller-supplied special tokens"
    # 121 tokens of markup plus the chat template's own framing, which the
    # provider adds and this side never sees.
    assert_equal 121 + envelope(1), result.tokens
  end

  # Anthropic and Gemini: a tokenizer we CAN run, times the lane's declared safety factor. It
  # remains a measured confidence, not a Provider-authoritative bound.
  test "an anchored lane scales a real tokenization by its declared factor" do
    anthropic = profile("anthropic/claude-opus-5-5")
    assert_equal "anchored", anthropic.token_counter.kind
    assert_equal "2.5", anthropic.token_counter.safety_factor

    text = "The quick brown fox jumps over the lazy dog. " * 20
    result = ModelRequests::TokenCount.count(profile: anthropic, segments: [text])
    anchor = Tiktoken.get_encoding("o200k_base").encode_ordinary(text).length

    refute_predicate result, :exact?, "a confidence must not be reported as exact"
    # The envelope is added AFTER the factor: the factor was measured against
    # tokenizer output, not against framing, so multiplying the framing by it
    # would inflate for no measured reason.
    assert_equal (anchor * BigDecimal("2.5")).ceil + envelope(1), result.tokens
    # Tighter than the byte bound it replaces, which is the whole point.
    assert_operator result.tokens, :<, text.bytesize
  end

  # The chat template's framing is charged on every EXACT arm too. Only the
  # byte bound had it, so an exact tokenizer counted lower than the truth —
  # against this module's own first rule.
  test "the chat envelope is charged on the exact arms and only where it applies" do
    text = "hello"
    exact = ModelRequests::TokenCount.count(
      profile: profile("openai_api/gpt-6.1-sol"), segments: [text]
    )
    raw = Tiktoken.get_encoding("o200k_base").encode_ordinary(text).length

    assert_predicate exact, :exact?
    assert_equal raw + envelope(1), exact.tokens

    # An embeddings endpoint sends what it is given, so charging chat framing
    # against its window would invent a bound the provider does not apply.
    embedding = ModelRequests::TokenCount.count(
      profile: profile("openai_api/text-embedding-3-large"), segments: [text]
    )
    assert_equal raw, embedding.tokens
  end

  def envelope(segments)
    ModelRequests::TokenCount::ENVELOPE_TOKENS_FIXED +
      (ModelRequests::TokenCount::ENVELOPE_TOKENS_PER_SEGMENT * segments)
  end

  test "a lane with no declared counter uses the provable byte bound" do
    bare = bare_profile
    assert_nil bare.token_counter

    segments = ["hello world"]
    result = ModelRequests::TokenCount.count(profile: bare, segments: segments)

    refute_predicate result, :exact?
    assert_equal 11 + ModelRequests::TokenCount::ENVELOPE_TOKENS_FIXED +
      ModelRequests::TokenCount::ENVELOPE_TOKENS_PER_SEGMENT, result.tokens
  end

  test "the byte estimate adds chat framing only to chat-shaped workloads" do
    text = "hello"
    chat = ModelRequests::TokenCount.count(profile: bare_profile, segments: [text])
    embedding = DevModelLane.profile_with(
      bare_profile,
      profile_id: "test.bare-embedding.v1",
      adapter_profile: "openai_embeddings",
      protocol_route: "embeddings_http",
      workload: "embedding",
      output_modalities: ["embedding"]
    )

    plain = ModelRequests::TokenCount.count(profile: embedding, segments: [text])

    assert_equal text.bytesize + envelope(1), chat.tokens
    assert_equal text.bytesize, plain.tokens
  end

  # Compare against actual tokenization: across content types whose real bytes-per-token spans 1.0
  # to 5.0, the bound is never below what a real tokenizer reports.
  test "the byte bound never counts lower than a real tokenizer" do
    bare = bare_profile
    encoding = Tiktoken.get_encoding("o200k_base")
    samples = {
      "english" => "The quick brown fox jumps over the lazy dog. " * 20,
      "chinese" => "模型平面的结算围栏与不可变收据。" * 20,
      # The band that breaks every chars/N heuristic in the references.
      "digits" => (1..300).map { |n| (n % 10).to_s }.join(" "),
      "base64" => SecureRandom.base64(600),
      "hex" => SecureRandom.hex(400),
    }

    samples.each do |name, text|
      bound = ModelRequests::TokenCount.count(profile: bare, segments: [text]).tokens
      actual = encoding.encode_ordinary(text).length

      assert_operator bound, :>=, actual,
        "#{name}: the bound (#{bound}) must never be under a real count (#{actual})"
    end
  end

  test "a declared counter that cannot be loaded refuses rather than degrading" do
    unloadable = SimpleInference::ExecutionProfile.new(
      profile_id: "test.unloadable.v1", provider_id: "dev",
      adapter_profile: "openai_responses", protocol_route: "responses_http_sse",
      workload: "text_generation", model_pin: "mock-text", credential_lane: "none",
      total_execution_deadline_seconds: 600,
      primary_execution_pair: SimpleInference::ExecutionProfile::MODEL_RUNNER_ASYNC_HTTP_PAIR,
      allowed_execution_pairs: [SimpleInference::ExecutionProfile::MODEL_RUNNER_ASYNC_HTTP_PAIR],
      token_counter: { kind: "huggingface", tokenizer_id: "nobody/nothing" }
    )

    result = ModelRequests::TokenCount.count(profile: unloadable, segments: ["hi"])

    refute_predicate result, :counted?
    assert_equal ModelRequests::TokenCount::UNAVAILABLE, result.refusal
  end

  test "HF counts only supplied text without the tokenizer's added boundary tokens" do
    tokenizer = Tokenizers::Tokenizer.new(Tokenizers::Models::WordLevel.new(
      vocab: { "[UNK]" => 0, "hello" => 1, "[BOS]" => 2, "[EOS]" => 3 }, unk_token: "[UNK]"
    ))
    tokenizer.post_processor = Tokenizers::Processors::TemplateProcessing.new(
      single: "[BOS] $A [EOS]", special_tokens: [["[BOS]", 2], ["[EOS]", 3]]
    )
    assert_equal [2, 1, 3], tokenizer.encode("hello").ids

    with_local_tokenizer(tokenizer.to_s) do |candidate|
      counted = ModelRequests::TokenCount.count(profile: candidate, segments: ["hello", "hello"])

      assert_predicate counted, :exact?
      assert_equal 2 + envelope(2), counted.tokens
    end
  end

  test "an invalid local tokenizer reports unavailability without another counter" do
    with_local_tokenizer("invalid tokenizer JSON") do |candidate|
      counted = ModelRequests::TokenCount.count(profile: candidate, segments: ["hello"])

      refute_predicate counted, :counted?
      assert_equal ModelRequests::TokenCount::UNAVAILABLE, counted.refusal
    end
  end

  test "the shipped open weight models select their installed vocabulary for estimates and history budgets" do
    bindings = {
      "deepseek/deepseek-flash" => "deepseek-ai/DeepSeek-V4.1-Flash",
      "deepseek/deepseek-v4-pro" => "deepseek-ai/DeepSeek-V4-Pro-0813",
      "openrouter/deepseek/deepseek-v4.1-flash" => "deepseek-ai/DeepSeek-V4.1-Flash",
      "openrouter/deepseek/deepseek-v4-pro-0813" => "deepseek-ai/DeepSeek-V4-Pro-0813",
      "openrouter/z-ai/glm-5.2:exacto" => "zai-org/GLM-5.2",
      "openrouter/z-ai/glm-5.3" => "zai-org/GLM-5.2",
      "openrouter/z-ai/glm-5.3-flash" => "zai-org/GLM-5.2",
      "openrouter/tencent/hy3:exacto" => "tencent/Hy3",
      "openrouter/qwen/qwen3.8-flash" => "Qwen/Qwen3.8-Flash-Next",
    }
    bindings.each do |model_ref, tokenizer_id|
      selected = profile(model_ref)
      assert_equal "huggingface", selected.token_counter.kind
      assert_equal tokenizer_id, selected.token_counter.tokenizer_id
      counted = ModelRequests::TokenCount.count(profile: selected, segments: ["Hello world", "你好，世界"])

      # These fixed strings encode to two and three tokens in each pinned
      # vocabulary. The shared chat allowance is separate from that text count.
      assert_predicate counted, :exact?, model_ref
      assert_equal 5 + envelope(2), counted.tokens, model_ref
      assert_equal 3 + envelope(1), Conversations::ContextAssembly::FillCost.call("你好，世界", selected), model_ref
    end
  end

  test "the local Qwen examples count with their installed vocabularies" do
    Dir.mktmpdir do |dir|
      %w[models providers].each do |name|
        sample = Rails.root.join("config.d/#{name}.yml.sample").read
        body = sample.split(/^schema_version:.*\n/, 2).fetch(1)
        File.write(File.join(dir, "#{name}.yml"),
          "schema_version: #{ModelCatalog::FileBase::SCHEMA_VERSION}\n" +
            body.lines.map { |line| line.sub(/\A# ?/, "") }.join)
      end
      catalog = ModelCatalog::FileBase.compile(root: Rails.root.join("config/model_catalog"),
        override_dir: dir, env: "development")
      %w[local/qwen3.8-flash-next local/qwen3.8-27b local/qwen3.6-35b-a3b local/qwen3.5-9b].each do |ref|
        selected = ModelCatalog::ProfileBuilder.call(model_ref: ref,
          provider: catalog.providers.fetch("local"), model: catalog.models.fetch(ref))
        counted = ModelRequests::TokenCount.count(profile: selected, segments: ["Hello world"])

        assert_predicate counted, :counted?, ref
        assert_predicate counted, :exact?, ref
        assert_equal 2 + envelope(1), counted.tokens, ref
        assert_equal 3 + envelope(1), Conversations::ContextAssembly::FillCost.call("你好，世界", selected), ref
      end
    end
  end

  # The registry declares data; nothing is inferred from a model name. The
  # binding's own model table diverges from upstream on at least one row, so
  # a name-derived encoding would be a guess wearing an audited fact's name.
  test "every declared counter is loadable and every dev lane declares one" do
    DevModelLane.each_catalog_profile do |candidate|
      counter = candidate.token_counter
      next if counter.nil?

      result = ModelRequests::TokenCount.count(profile: candidate, segments: ["probe"])
      assert_predicate result, :counted?, "#{candidate.profile_id} declares an unloadable counter"
      # Only an anchored lane is inexact; the exact kinds must say so.
      assert_equal !counter.anchored?, result.exact?, candidate.profile_id
    end
  end

  private

    def with_local_tokenizer(contents)
      Tempfile.create(["counter", ".json"]) do |file|
        file.write(contents)
        file.flush
        candidate = bare_profile.with(token_counter: { kind: "huggingface", tokenizer_id: SecureRandom.uuid })
        ModelRequests::TokenCount.stub(:tokenizer_path, file.path) { yield candidate }
      end
    end
end
