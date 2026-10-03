require "json"
require "test_helper"

# Gemini embeddings v1 is the singular embedContent route (one text per
# call). Every negative/malformed response below is a deterministic
# construction, not a wire capture.
class TestGeminiEmbeddingsProtocol < Minitest::Test
  class CapturingAdapter < SimpleInference::HTTPAdapter
    attr_reader :last_request

    def initialize(body: nil)
      super()
      @body = body || JSON.generate({ "embedding" => { "values" => [0.1, 0.2, 0.3] } })
    end

    def call(request)
      @last_request = request
      { status: 200, headers: { "content-type" => "application/json" }, body: @body }
    end
  end

  class ExplodingAdapter < SimpleInference::HTTPAdapter
    def call(_request)
      raise "no request may be emitted on a pre-IO rejection"
    end
  end

  # The input byte cap is a construction fact fed from the registry row's
  # local_safety_limits (ApiFormat.protocol_for); these tests feed the
  # same declared value the shipped row carries.
  def build_protocol(adapter: CapturingAdapter.new)
    SimpleInference::Protocols::GeminiEmbeddings.new(
      base_url: "https://generativelanguage.googleapis.com", api_key: "secret", adapter: adapter,
      input_byte_cap: 2_048,
    )
  end

  # --- the singular embedContent endpoint ---

  def test_create_posts_the_singular_embed_content_route
    adapter = CapturingAdapter.new
    protocol = build_protocol(adapter: adapter)

    result = protocol.create(model: "gemini-embedding-001", input: "embed this")

    assert_equal(
      "https://generativelanguage.googleapis.com/v1beta/models/gemini-embedding-001:embedContent",
      adapter.last_request.fetch(:url),
    )
    body = JSON.parse(adapter.last_request.fetch(:body))
    assert_equal "embed this", body.dig("content", "parts", 0, "text")
    refute body.key?("requests"), "the batch envelope must not appear on the wire"
    refute body.key?("model"), "model rides the path on the singular route"
    assert_equal [0.1, 0.2, 0.3], result.embeddings.fetch(0).fetch("embedding")
    assert_equal 0, result.embeddings.fetch(0).fetch("index")
  end

  def test_array_input_is_rejected_pre_io
    protocol = build_protocol(adapter: ExplodingAdapter.new)

    error =
      assert_raises(SimpleInference::ValidationError) do
        protocol.create(model: "gemini-embedding-001", input: %w[a b])
      end

    assert_includes error.message, "one input text"
  end

  def test_non_string_and_empty_inputs_are_rejected_pre_io
    protocol = build_protocol(adapter: ExplodingAdapter.new)

    assert_raises(SimpleInference::ValidationError) do
      protocol.create(model: "gemini-embedding-001", input: 42)
    end
    assert_raises(SimpleInference::ValidationError) do
      protocol.create(model: "gemini-embedding-001", input: "   ")
    end
  end

  def test_model_is_required
    assert_raises(SimpleInference::ValidationError) do
      build_protocol(adapter: ExplodingAdapter.new).create(model: "  ", input: "x")
    end
  end

  # --- MRL dimensions contract: 128..3072, loud outside ---

  def test_output_dimensionality_maps_onto_the_wire
    adapter = CapturingAdapter.new(body: JSON.generate({ "embedding" => { "values" => [0.1] * 128 } }))
    protocol = build_protocol(adapter: adapter)

    protocol.create(model: "gemini-embedding-001", input: "x", output_dimensionality: 128)

    body = JSON.parse(adapter.last_request.fetch(:body))
    assert_equal 128, body.fetch("outputDimensionality")
  end

  def test_dimensions_alias_maps_onto_output_dimensionality
    adapter = CapturingAdapter.new(body: JSON.generate({ "embedding" => { "values" => [0.2] * 256 } }))
    protocol = build_protocol(adapter: adapter)

    protocol.create(model: "gemini-embedding-001", input: "x", dimensions: 256)

    body = JSON.parse(adapter.last_request.fetch(:body))
    assert_equal 256, body.fetch("outputDimensionality")
  end

  def test_conflicting_dimension_spellings_are_rejected
    protocol = build_protocol(adapter: ExplodingAdapter.new)

    error =
      assert_raises(SimpleInference::ValidationError) do
        protocol.create(model: "gemini-embedding-001", input: "x", dimensions: 256, output_dimensionality: 512)
      end

    assert_includes error.message, "dimensions"
  end

  def test_output_dimensionality_outside_128_to_3072_is_rejected_pre_io
    protocol = build_protocol(adapter: ExplodingAdapter.new)

    [127, 3073, 0, -5].each do |dim|
      error =
        assert_raises(SimpleInference::ValidationError, "#{dim} must be rejected") do
          protocol.create(model: "gemini-embedding-001", input: "x", output_dimensionality: dim)
        end

      assert_includes error.message, "128"
      assert_includes error.message, "3072"
    end
  end

  def test_output_dimensionality_must_be_an_integer
    protocol = build_protocol(adapter: ExplodingAdapter.new)

    assert_raises(SimpleInference::ValidationError) do
      protocol.create(model: "gemini-embedding-001", input: "x", output_dimensionality: 256.5)
    end
    assert_raises(SimpleInference::ValidationError) do
      protocol.create(model: "gemini-embedding-001", input: "x", output_dimensionality: "256")
    end
  end

  def test_boundary_dimensionalities_pass
    [128, 3072].each do |dim|
      adapter = CapturingAdapter.new(body: JSON.generate({ "embedding" => { "values" => [0.1] * dim } }))
      protocol = build_protocol(adapter: adapter)

      result = protocol.create(model: "gemini-embedding-001", input: "x", output_dimensionality: dim)

      assert_equal dim, result.embeddings.fetch(0).fetch("embedding").length
      refute result.embeddings.fetch(0).key?("dimension")
    end
  end

  def test_result_embeddings_do_not_duplicate_the_vector_length
    result = build_protocol.create(model: "gemini-embedding-001", input: "x")

    entry = result.embeddings.fetch(0)
    assert_equal 3, entry.fetch("embedding").length
    refute entry.key?("dimension")
    assert_predicate result.embeddings, :frozen?
  end

  # --- requested-vs-effective dimension verification ---

  def test_effective_dimension_mismatch_is_a_typed_error
    # Deterministic construction: a 2xx body whose values.length differs from
    # the requested outputDimensionality (never observed on the wire; the
    # 2026-08-09 probe returned exactly the requested 768).
    adapter = CapturingAdapter.new(body: JSON.generate({ "embedding" => { "values" => [0.1, 0.2] } }))
    protocol = build_protocol(adapter: adapter)

    error =
      assert_raises(SimpleInference::DecodeError) do
        protocol.create(model: "gemini-embedding-001", input: "x", output_dimensionality: 128)
      end

    assert_includes error.message, "128"
    assert_includes error.message, "2"
  end

  # --- truthful usage: the wire reports none, so none is reported ---

  def test_usage_is_truthfully_absent_even_when_stray_metadata_appears
    adapter = CapturingAdapter.new(
      body: JSON.generate(
        {
          "embedding" => { "values" => [0.1] },
          "usageMetadata" => { "promptTokenCount" => 3 },
        },
      ),
    )
    protocol = build_protocol(adapter: adapter)

    result = protocol.create(model: "gemini-embedding-001", input: "x")

    assert_nil result.usage, "embedContent declares no usage; a fabricated mapping would be silent drift"
  end

  # --- malformed 2xx response (deterministic construction) ---

  def test_missing_embedding_values_is_a_loud_decode_error
    adapter = CapturingAdapter.new(body: JSON.generate({ "embedding" => {} }))

    assert_raises(SimpleInference::DecodeError) do
      build_protocol(adapter: adapter).create(model: "gemini-embedding-001", input: "x")
    end
  end

  # --- declared-vocabulary + extra_body contract ---

  def test_unknown_symbol_options_raise_and_point_at_extra_body
    error =
      assert_raises(SimpleInference::ValidationError) do
        build_protocol(adapter: ExplodingAdapter.new).create(model: "m", input: "x", dimensionz: 256)
      end

    assert_includes error.message, "dimensionz"
    assert_includes error.message, "extra_body"
  end

  def test_task_type_and_title_left_the_declared_vocabulary
    # v1 pins the probe-evidenced body shape {content, outputDimensionality?};
    # unevidenced native fields ride extra_body visibly or not at all.
    keys = SimpleInference::Protocols::GeminiEmbeddings.request_option_keys

    refute_includes keys, :task_type
    refute_includes keys, :title
    assert_includes keys, :dimensions
    assert_includes keys, :output_dimensionality
    assert keys.frozen?
  end

  def test_extra_body_merges_verbatim_and_collisions_raise
    adapter = CapturingAdapter.new
    protocol = build_protocol(adapter: adapter)

    protocol.create(model: "gemini-embedding-001", input: "x", extra_body: { "taskType" => "RETRIEVAL_QUERY" })
    body = JSON.parse(adapter.last_request.fetch(:body))
    assert_equal "RETRIEVAL_QUERY", body.fetch("taskType")

    error =
      assert_raises(SimpleInference::ValidationError) do
        protocol.create(model: "gemini-embedding-001", input: "x", extra_body: { "content" => {} })
      end
    assert_includes error.message, "content"
  end
end
