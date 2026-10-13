require "test_helper"

# Internal::Keys and Internal::Envelope are the gem's single homes for hash
# key-shape conversion and adapter-envelope consumption. Their semantics are
# pinned here once so the (many) call sites can stay assertion-free.
class TestInternalModules < Minitest::Test
  # --- Internal::Keys ---

  def test_shallow_symbolize_converts_top_level_keys_only
    input = { "a" => 1, :b => { "nested" => 2 } }

    result = SimpleInference::Internal::Keys.shallow_symbolize(input)

    assert_equal({ a: 1, b: { "nested" => 2 } }, result)
    assert_same input[:b], result[:b], "nested payload values pass through by reference"
  end

  def test_shallow_symbolize_reads_nil_as_empty_bag_and_refuses_a_scalar
    assert_equal({}, SimpleInference::Internal::Keys.shallow_symbolize(nil))
    assert_raises(NoMethodError) { SimpleInference::Internal::Keys.shallow_symbolize("not a hash") }
  end

  def test_shallow_stringify_converts_top_level_keys_only
    result = SimpleInference::Internal::Keys.shallow_stringify({ a: 1, "b" => { c: 2 } })

    assert_equal({ "a" => 1, "b" => { c: 2 } }, result)
  end

  def test_deep_stringify_copies_and_stringifies_through_hashes_and_arrays
    original_content = [{ text: "hi", meta: { k: 1 } }, "plain"]
    input = { type: "message", content: original_content }

    result = SimpleInference::Internal::Keys.deep_stringify(input)

    assert_equal(
      { "type" => "message", "content" => [{ "text" => "hi", "meta" => { "k" => 1 } }, "plain"] },
      result
    )
    copied_content = result.fetch("content")
    refute_same original_content, copied_content, "deep copy, not an aliased array"
    assert_equal({}, SimpleInference::Internal::Keys.deep_stringify(nil))
  end

  # --- Internal::Envelope ---

  def test_envelope_status_is_strict
    assert_equal 200, SimpleInference::Internal::Envelope.from_h({ status: 200, headers: {}, body: "" }).status
    assert_equal 200, SimpleInference::Internal::Envelope.from_h({ status: "200", headers: {}, body: "" }).status
    assert_raises(KeyError) { SimpleInference::Internal::Envelope.from_h({ headers: {}, body: "" }) }
    assert_raises(TypeError) { SimpleInference::Internal::Envelope.from_h({ status: nil, headers: {}, body: "" }) }
  end

  def test_envelope_headers_downcases_names
    envelope = SimpleInference::Internal::Envelope.from_h({ status: 200, headers: { "Content-Type" => "a", "X-ID" => "b" }, body: "" })

    assert_equal({ "content-type" => "a", "x-id" => "b" }, envelope.headers)
    assert_equal({}, SimpleInference::Internal::Envelope.from_h({ status: 200, headers: nil, body: "" }).headers)
  end

  def test_envelope_sse_sniff_requires_success_and_event_stream_content_type
    sse = ->(status, headers) { SimpleInference::Internal::Envelope.new(status:, headers:, body: nil).sse? }

    assert sse.call(200, { "Content-Type" => "text/event-stream" })
    refute sse.call(400, { "content-type" => "text/event-stream" })
    refute sse.call(200, { "content-type" => "application/json" })
    refute sse.call(200, {})
  end

  # A malformed adapter response now fails loudly AT THE SEAM instead of
  # surfacing later as a mysterious status-0 HTTPError.
  def test_protocol_raises_on_malformed_adapter_envelope
    adapter =
      Class.new(SimpleInference::HTTPAdapter) do
        def call(_request)
          { headers: {}, body: "{}" } # no :status
        end
      end.new
    protocol = SimpleInference::Protocols::OpenAIEmbeddings.new(base_url: "http://example.com", api_key: "k", adapter: adapter)

    assert_raises(KeyError) { protocol.create(model: "m", input: ["x"]) }
  end
end
