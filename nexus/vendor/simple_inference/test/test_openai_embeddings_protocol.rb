require "json"
require "test_helper"

# The declared-vocabulary + extra_body contract, pinned on the smallest
# protocol first (the template every transplanted protocol follows):
# - request methods accept ONLY their declared symbol options,
# - provider-specific wire fields ride the extra_body escape hatch
#   (string-keyed, merged verbatim, collisions rejected),
# - the wire body is built string-keyed with every wire key written once.
class TestOpenAIEmbeddingsProtocol < Minitest::Test
  class CapturingAdapter < SimpleInference::HTTPAdapter
    attr_reader :last_request

    def call(request)
      @last_request = request
      body = JSON.generate(
        {
          "data" => [{ "index" => 0, "embedding" => [0.1, 0.2] }],
          "usage" => { "prompt_tokens" => 1, "total_tokens" => 1 },
        }
      )
      { status: 200, headers: { "content-type" => "application/json" }, body: body }
    end
  end

  def build_protocol(adapter: CapturingAdapter.new, input_byte_cap: nil)
    SimpleInference::Protocols::OpenAIEmbeddings.new(
      base_url: "http://example.com", api_key: "k", adapter: adapter, input_byte_cap: input_byte_cap
    )
  end

  def test_declared_options_reach_the_wire_as_string_keys
    adapter = CapturingAdapter.new
    protocol = build_protocol(adapter: adapter)

    # dimensions matches the canned 2-value embedding: requested-vs-effective
    # verification passes silently on the honest path.
    result = protocol.create(model: "text-embedding-3-small", input: %w[a b], dimensions: 2, user: "u1")

    assert_instance_of SimpleInference::Embeddings::Result, result
    body = JSON.parse(adapter.last_request.fetch(:body))
    assert_equal "text-embedding-3-small", body.fetch("model")
    assert_equal %w[a b], body.fetch("input")
    assert_equal 2, body.fetch("dimensions")
    assert_equal "u1", body.fetch("user")
  end

  def test_unknown_symbol_options_raise_and_point_at_extra_body
    error =
      assert_raises(SimpleInference::ValidationError) do
        build_protocol.create(model: "m", input: "x", dimensionz: 42)
      end

    assert_includes error.message, "dimensionz"
    assert_includes error.message, "extra_body"
  end

  def test_extra_body_merges_string_keyed_fields_verbatim
    adapter = CapturingAdapter.new
    protocol = build_protocol(adapter: adapter)

    protocol.create(model: "m", input: "x", extra_body: { "input_type" => "query", "truncate" => "END" })

    body = JSON.parse(adapter.last_request.fetch(:body))
    assert_equal "query", body.fetch("input_type")
    assert_equal "END", body.fetch("truncate")
  end

  def test_extra_body_rejects_symbol_keys
    error =
      assert_raises(SimpleInference::ValidationError) do
        build_protocol.create(model: "m", input: "x", extra_body: { input_type: "query" })
      end

    assert_includes error.message, "string keys"
  end

  def test_extra_body_collisions_with_built_wire_fields_raise
    error =
      assert_raises(SimpleInference::ValidationError) do
        build_protocol.create(model: "m", input: "x", dimensions: 2, extra_body: { "dimensions" => 4 })
      end

    assert_includes error.message, "dimensions"
  end

  def test_request_option_keys_are_introspectable
    keys = SimpleInference::Protocols::OpenAIEmbeddings.request_option_keys

    assert_includes keys, :dimensions
    refute_includes keys, :input_byte_cap
    assert keys.frozen?
  end

  # --- the pre-IO input-byte measurement seam. The profile owns the cap and
  # feeds it into protocol construction; callers cannot change it per request.
  # All cap/cap+1 inputs are deterministic constructions. ---

  class ExplodingAdapter < SimpleInference::HTTPAdapter
    def call(_request)
      raise "no request may be emitted on a pre-IO rejection"
    end
  end

  def test_measured_input_bytes_sums_ordered_inputs
    protocol = build_protocol

    assert_equal 3, protocol.measured_input_bytes("abc")
    assert_equal 5, protocol.measured_input_bytes(%w[ab cde])
    assert_equal 6, protocol.measured_input_bytes(["世", "界"]), "UTF-8 bytes, not scalars"
  end

  def test_measured_input_bytes_rejects_non_string_entries
    assert_raises(SimpleInference::ValidationError) do
      build_protocol.measured_input_bytes([1, 2, 3])
    end
  end

  def test_input_byte_cap_at_cap_passes_and_never_reaches_the_wire
    adapter = CapturingAdapter.new
    protocol = build_protocol(adapter: adapter, input_byte_cap: 16)

    protocol.create(model: "m", input: "a" * 16)

    body = JSON.parse(adapter.last_request.fetch(:body))
    refute body.key?("input_byte_cap"), "the cap is a local bound, not a wire field"
  end

  def test_input_byte_cap_plus_one_is_rejected_pre_io
    error =
      assert_raises(SimpleInference::BoundExceededError) do
        build_protocol(adapter: ExplodingAdapter.new, input_byte_cap: 16).create(model: "m", input: "a" * 17)
      end

    assert_includes error.message, "embeddings_input_bytes"
    assert_includes error.message, "17"
  end

  def test_input_byte_cap_measures_the_sum_over_ordered_inputs
    assert_raises(SimpleInference::BoundExceededError) do
      build_protocol(adapter: ExplodingAdapter.new, input_byte_cap: 8).create(model: "m", input: %w[abcd efgh x])
    end
  end

  def test_input_byte_cap_rejects_invalid_profile_values_at_construction
    [0, -1, 1.5, "16"].each do |cap|
      assert_raises(SimpleInference::ConfigurationError, "cap=#{cap.inspect} must be rejected") do
        build_protocol(adapter: ExplodingAdapter.new, input_byte_cap: cap)
      end
    end
  end

  def test_profile_local_safety_limit_is_fed_into_protocol_construction
    protocol = SimpleInference::ApiFormat.protocol_for(
      profile: profile_for("openai_embeddings", local_safety_limits: { "input_bytes" => 16 }),
      config: SimpleInference::Config.new(
        base_url: "http://example.com", api_key: "k", adapter: ExplodingAdapter.new
      )
    )

    assert_raises(SimpleInference::BoundExceededError) do
      protocol.create(model: "m", input: "a" * 17)
    end
  end

  # --- dimensions bound to evidence: pass-through, loud on nonsense ---

  def test_dimensions_rejects_non_positive_and_non_integer_values
    [0, -3, 2.5, "256"].each do |dimensions|
      error =
        assert_raises(SimpleInference::ValidationError, "dimensions=#{dimensions.inspect} must be rejected") do
          build_protocol(adapter: ExplodingAdapter.new).create(model: "m", input: "x", dimensions: dimensions)
        end

      assert_includes error.message, "dimensions"
    end
  end

  # --- requested dimensions are checked against the returned vector ---

  def test_result_embeddings_keep_the_provider_shape
    result = build_protocol.create(model: "m", input: "x")

    entry = result.embeddings.fetch(0)
    assert_equal [0.1, 0.2], entry.fetch("embedding")
    refute entry.key?("dimension")
    assert_predicate result.embeddings, :frozen?
  end

  def test_requested_vs_effective_dimension_mismatch_is_a_typed_error
    # The canned body always returns 2 values; requesting 4 dimensions must
    # fail loudly — a silent mismatch would corrupt downstream vector math.
    error =
      assert_raises(SimpleInference::DecodeError) do
        build_protocol.create(model: "m", input: "x", dimensions: 4)
      end

    assert_includes error.message, "4"
    assert_includes error.message, "2"
    assert_includes error.message, "requested-vs-effective"
  end

  # --- truthful usage parsing: canonical prompt_tokens -> input_tokens
  # mapping with the raw Chat-style fields preserved ---

  def test_usage_maps_prompt_tokens_to_canonical_input_tokens_keeping_raw
    result = build_protocol.create(model: "m", input: "x")

    assert_equal 1, result.usage.fetch("input_tokens")
    assert_equal 1, result.usage.fetch("prompt_tokens"), "the raw Chat-style field survives"
    assert_equal 1, result.usage.fetch("total_tokens")
  end

  def test_absent_usage_stays_absent
    adapter = Class.new(SimpleInference::HTTPAdapter) do
      def call(_request)
        body = JSON.generate({ "data" => [{ "index" => 0, "embedding" => [0.1] }] })
        { status: 200, headers: { "content-type" => "application/json" }, body: body }
      end
    end.new

    result = build_protocol(adapter: adapter).create(model: "m", input: "x")

    assert_nil result.usage, "a usage object absent on the wire stays absent — never fabricated"
  end
end
