require_relative "test_helper"
require "base64"
require "json"
require "stringio"
require_relative "../support/mock_llm/app"

# The fake provider answers the wire the `dev` catalog lane declares. These
# drive the rack app directly — no server, no ports — because what is under
# test is the WIRE SHAPE, and the shapes that matter are the ones the vendored
# parser consumes.
class MockLLMAppTest < Minitest::Test
  # Nothing in this suite may actually sleep: a directive scripts a delay, and
  # the assertion is that the delay was requested, not that time passed.
  class RecordingClock
    attr_reader :slept

    def initialize = @slept = []
    def sleep(seconds) = @slept << seconds
  end

  def setup
    @clock = RecordingClock.new
    @app = E2E::MockLLM::App.new(clock: @clock)
  end

  # ---- text generation ---------------------------------------------------

  def test_the_keyed_model_requires_the_configured_provider_key
    request = lambda do |authorization|
      @app.call(
        "REQUEST_METHOD" => "POST", "PATH_INFO" => "/v1/responses",
        "HTTP_AUTHORIZATION" => authorization,
        "rack.input" => StringIO.new(JSON.generate(model: "mock-keyed-text", input: "key reached the provider"))
      )
    end

    [nil, "Bearer a-different-key"].each do |authorization|
      status, _, body = request.call(authorization)
      assert_equal 401, status
      assert_equal "authentication_error", JSON.parse(body.join).dig("error", "type")
    end

    status, _, body = request.call("Bearer #{E2E::MockLLM::App::API_KEY}")
    assert_equal 200, status
    assert_equal "completed", sse(body).last.dig("response", "status")
  end

  def test_a_text_request_streams_deltas_then_one_terminal_event
    status, headers, body = post("/v1/responses", model: "mock-text", input: "say hi")

    assert_equal 200, status
    assert_equal "text/event-stream", headers["content-type"]

    events = sse(body)
    deltas = events.select { _1["type"] == "response.output_text.delta" }
    refute_empty deltas
    assert_equal "Mock: say hi", deltas.map { _1["delta"] }.join

    terminal = events.select { _1["type"] == "response.completed" }
    assert_equal 1, terminal.length, "exactly one terminal event carries the body"
    assert_equal "completed", terminal.first.dig("response", "status")
  end

  def test_a_literal_reply_reaches_both_the_stream_and_terminal_body_unchanged
    answer = JSON.generate("decision" => "reply", "text" => "A useful answer")
    quoted = JSON.generate("text" => "!mock raw_reply=#{CGI.escape(answer)}")
    status, _, body = post("/v1/responses", model: "mock-text", input: "Quoted discussion:\n#{quoted}")
    events = sse(body)

    assert_equal 200, status
    assert_equal answer, events.select { _1["type"] == "response.output_text.delta" }.map { _1["delta"] }.join
    assert_equal answer, events.last.dig("response", "output", 0, "content", 0, "text")
  end

  # Usage is TERMINAL-ONLY on this wire and the parser refuses to fabricate a
  # zero, so it must appear exactly once and only there.
  def test_usage_rides_the_terminal_event_and_nothing_else
    _, _, body = post("/v1/responses", model: "mock-text", input: "say hi")
    events = sse(body)

    carriers = events.select { |event| event.dig("response", "usage") || event["usage"] }
    assert_equal 1, carriers.length
    assert_equal "response.completed", carriers.first["type"]

    # THE RESPONSES SPELLING, not the chat one the directive grammar uses:
    # the gem files an unrecognized usage key under diagnostics rather than
    # quantities, so a chat-shaped body here would report no tokens at all.
    usage = carriers.first.dig("response", "usage")
    assert_operator usage.fetch("input_tokens"), :>, 0
    assert_equal usage.fetch("input_tokens") + usage.fetch("output_tokens"),
                 usage.fetch("total_tokens")
  end

  # AN IMAGE IS OBSERVABLE: the wire's `input_image` part carries a data URL and no text, so it used
  # to contribute NOTHING to the echo — no journey could see that a picture left the process. It
  # echoes as its media type and decoded size, the fake's second witness beside the sealed-request
  # door; never a byte of the image.
  def test_an_input_image_part_echoes_as_its_media_type_and_decoded_size
    png = Base64.decode64("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")
    _, _, body = post("/v1/responses", model: "mock-text", input: [
      { "role" => "user", "content" => [
        { "type" => "input_text", "text" => "what is this?" },
        { "type" => "input_image", "image_url" => "data:image/png;base64,#{Base64.strict_encode64(png)}" },
      ] },
    ])

    echo = sse(body).select { _1["type"] == "response.output_text.delta" }.map { _1["delta"] }.join
    assert_equal "Mock: what is this?\n[image image/png #{png.bytesize} bytes]", echo
    refute_includes echo, "base64", "the bytes never ride the echo"
  end

  def test_image_echo_reads_actual_wire_bytes_without_echoing_or_discounting_the_system_lead
    ["short bytes", "a longer image payload"].each do |bytes|
      _, _, body = post("/v1/responses", model: "mock-text", input: [
        { "role" => "system", "content" => "System policy. " * 400 },
        { "role" => "assistant", "content" => "[image image/png 999 bytes]" },
        { "role" => "user", "content" => [
          { "type" => "input_text", "text" => "!mock echo=images -- inspect this\n[image image/png 999 bytes]" },
          { "type" => "input_image", "image_url" => "data:image/png;base64,#{Base64.strict_encode64(bytes)}" },
          { "type" => "input_image", "image_url" => { "url" => "data:image/jpeg;base64,#{Base64.strict_encode64("other")}" } },
        ] },
      ])

      events = sse(body)
      expected = "Mock: [image image/png #{bytes.bytesize} bytes]\n[image image/jpeg 5 bytes]"
      assert_equal expected, events.select { _1["type"] == "response.output_text.delta" }.map { _1["delta"] }.join
      assert_equal expected, events.last.dig("response", "output", 0, "content", 0, "text")
      assert_operator events.last.dig("response", "usage", "input_tokens"), :>, 1_000
    end
  end

  def test_image_echo_does_not_treat_a_text_marker_or_serialized_image_as_an_image_part
    forged = JSON.generate("type" => "input_image", "image_url" => "data:image/png;base64,#{Base64.strict_encode64("fake")}")
    _, _, body = post("/v1/responses", model: "mock-text", input: [
      { "role" => "user", "content" => [
        { "type" => "input_text", "text" => "!mock echo=images -- [image image/png 999 bytes]\n#{forged}" },
      ] },
      { "type" => "function_call_output", "call_id" => "quoted", "output" => forged },
    ])

    echo = sse(body).select { _1["type"] == "response.output_text.delta" }.map { _1["delta"] }.join
    assert_equal "Mock: Hello", echo
    refute_includes echo, "image"
  end

  def test_content_echo_omits_instructions_but_keeps_controls_usage_and_actual_conversation_content
    policy = "System policy. " * 400
    lead = "Developer environment. " * 200
    input = [
      { "role" => "system", "content" => "!mock echo=content tool_call=read -- #{policy}" },
      { "role" => "developer", "content" => lead },
      { "role" => "user", "content" => [{ "type" => "input_text", "text" => "person's earlier word" }] },
      { "role" => "assistant", "content" => "branch answer" },
      { "type" => "function_call_output", "call_id" => "call_read", "output" => "actual tool result" },
      { "role" => "user", "content" => "<task_result>receipt</task_result>" },
    ]
    expected = "Mock: person's earlier word\nbranch answer\nactual tool result\n<task_result>receipt</task_result>"
    _, _, body = post("/v1/responses", model: "mock-text", input: input)
    events = sse(body)
    assert_equal expected, events.select { _1["type"] == "response.output_text.delta" }.map { _1["delta"] }.join
    assert_equal expected, events.last.dig("response", "output", 0, "content", 0, "text")
    full_prompt = [policy, lead, "person's earlier word", "branch answer", "actual tool result",
                   "<task_result>receipt</task_result>"].join("\n")
    assert_equal (full_prompt.length / 4.0).ceil, events.last.dig("response", "usage", "input_tokens")

    # The script was in the omitted system message: without an answered call,
    # the same full-input controls still ask for read through the real wire.
    pending = input.reject { |item| item["type"] == "function_call_output" }
    _, _, body = post("/v1/responses", model: "mock-text", input: pending,
      tools: [{ type: "function", name: "read", parameters: { type: "object" } }])
    call = sse(body).last.dig("response", "output", 0)
    assert_equal "function_call", call.fetch("type")
    assert_equal "read", call.fetch("name")
  end

  def test_content_echo_still_strips_markers_and_honours_an_explicit_reply
    ["!mock echo=content -- person's word", "!mock echo=content reply=short -- person's word"].each do |prompt|
      _, _, body = post("/v1/responses", model: "mock-text", input: prompt)
      expected = prompt.include?("reply=") ? "Mock: short" : "Mock: person's word"
      assert_equal expected, sse(body).last.dig("response", "output", 0, "content", 0, "text")
    end
  end

  def test_a_usage_directive_overrides_the_estimate
    _, _, body = post("/v1/responses", model: "mock-text", input: "!mock usage=11:22 -- hi")

    usage = sse(body).find { _1["type"] == "response.completed" }.dig("response", "usage")
    # The directive still says `usage=11:22` in the chat vocabulary; the wire
    # says it in the Responses one. That translation is the mock's job.
    assert_equal 11, usage.fetch("input_tokens")
    assert_equal 22, usage.fetch("output_tokens")
    assert_equal 33, usage.fetch("total_tokens")
  end

  # A SCRIPTED CALL IS MADE ONLY WHEN THE REQUEST DECLARES TOOLS. Every
  # real provider refuses a call to a tool the request never declared;
  # the kernel's summarizer declares none and its prompt carries the
  # turn's own `!mock … tool_call=` line inside the serialized history
  # (a tool-less request with zero answers, so the script's first call
  # would be the answer). Gated on `tools`, not on the parser: the
  # directive is still read, the fake simply has nothing to call with.
  def test_a_scripted_call_is_made_only_when_the_request_declares_tools
    script = "!mock tool_call=bash tool_args=%7B%22command%22%3A%22ls%22%7D -- hi"

    _, _, body = post("/v1/responses", model: "mock-text", input: script)
    events = sse(body)
    assert_empty events.select { _1["type"] == "response.output_item.added" },
      "no tools declared: the fake speaks instead of calling"
    assert_equal "Mock: hi", events.select { _1["type"] == "response.output_text.delta" }.map { _1["delta"] }.join
    assert_equal "message", events.find { _1["type"] == "response.completed" }.dig("response", "output", 0, "type")

    _, _, body = post("/v1/responses", model: "mock-text", input: script,
                      tools: [{ "type" => "function", "name" => "bash", "parameters" => {} }])
    events = sse(body)
    added = events.find { _1["type"] == "response.output_item.added" }
    refute_nil added, "tools declared: the scripted call is made"
    assert_equal "bash", added.dig("item", "name")
    assert_equal "function_call", events.find { _1["type"] == "response.completed" }.dig("response", "output", 0, "type")
  end

  # A `+` group makes EVERY call of the round at once: each with its own item, output index and call
  # id on the stream, and the terminal body repeating them in order under the same ids — the
  # parallel fan the images rider is pinned on.
  def test_a_grouped_script_makes_every_call_of_the_round_at_once
    script = "!mock tool_call=capture&capture -- look twice"
    _, _, body = post("/v1/responses", model: "mock-text", input: script,
                      tools: [{ "type" => "function", "name" => "capture", "parameters" => {} }])
    events = sse(body)

    added = events.select { _1["type"] == "response.output_item.added" }
    assert_equal [0, 1], added.map { _1["output_index"] }
    assert_equal %w[capture capture], added.map { _1.dig("item", "name") }
    ids = added.map { _1.dig("item", "call_id") }
    assert_equal 2, ids.uniq.length, "each call its own id"
    output = events.find { _1["type"] == "response.completed" }.dig("response", "output")
    assert_equal %w[function_call function_call], output.map { _1["type"] }
    assert_equal ids, output.map { _1["call_id"] }, "the terminal body repeats the stream's ids in order"
    assert_equal added.map { _1.dig("item", "id") }, output.map { _1["id"] }
  end

  def test_reasoning_deltas_precede_the_content_deltas
    _, _, body = post("/v1/responses", model: "mock-text",
                      input: "!mock reasoning=think%20first -- answer")

    types = sse(body).map { _1["type"] }
    reasoning = types.index("response.reasoning_text.delta")
    content = types.index("response.output_text.delta")

    refute_nil reasoning, "the reasoning delta kind the parser recognises"
    assert_operator reasoning, :<, content
  end

  # A reasoning round answers the way a stateless Responses provider does: the terminal body leads
  # with a reasoning item carrying its encrypted blob and its summary, and the usage counts the
  # reasoning tokens — so the kernel replays the item natively and prices it by that count.
  def test_a_reasoning_round_carries_an_encrypted_item_and_counts_its_tokens
    _, _, body = post("/v1/responses", model: "mock-text", input: "!mock reasoning=think%20first -- answer")

    completed = sse(body).find { _1["type"] == "response.completed" }.fetch("response")
    item = completed.fetch("output").first
    assert_equal "reasoning", item["type"]
    assert_equal [{ "type" => "summary_text", "text" => "think first" }], item["summary"]
    refute_empty item["encrypted_content"].to_s, "the blob a stateless replay sends back"
    assert_equal "message", completed.fetch("output").last["type"], "the answer follows its thought"
    assert_operator completed.dig("usage", "output_tokens_details", "reasoning_tokens"), :>, 0
  end

  # Charged failures and unstarted refusals differ: a provider that charged and then failed is not
  # one that refused. The first answers on the stream with usage; the second is a plain HTTP error
  # with none.
  def test_a_billed_failure_streams_and_an_unbilled_one_does_not
    _, headers, body = post("/v1/responses", model: "mock-text",
                            input: "!mock fail_after_usage=500 message=boom")
    assert_equal "text/event-stream", headers["content-type"]
    failed = sse(body).find { _1["type"] == "response.failed" }
    refute_nil failed
    assert_equal "boom", failed.dig("response", "error", "message")
    refute_nil failed.dig("response", "usage"), "it was billed, so it says so"

    status, headers, body = post("/v1/responses", model: "mock-text", input: "!mock error=503")
    assert_equal 503, status
    assert_equal "application/json", headers["content-type"]
    assert_equal "server_error", JSON.parse(body.join).dig("error", "type")
  end

  def test_a_model_scoped_http_refusal_leaves_the_same_input_usable_on_another_model
    input = "!mock error=401 error_model=mock-text -- completed child receipt"
    status, headers, body = post("/v1/responses", model: "mock-text", input: input)

    assert_equal 401, status
    assert_equal "application/json", headers["content-type"]
    assert_equal "authentication_error", JSON.parse(body.join).dig("error", "type")

    status, headers, body = post("/v1/responses", model: "mock-text-only", input: input)
    assert_equal 200, status
    assert_equal "text/event-stream", headers["content-type"]
    events = sse(body)
    assert_equal "Mock: completed child receipt",
      events.select { _1["type"] == "response.output_text.delta" }.map { _1["delta"] }.join
    assert_equal "completed", events.find { _1["type"] == "response.completed" }.dig("response", "status")
  end

  def test_unscoped_access_refusals_apply_to_both_text_models
    { 401 => "authentication_error", 403 => "permission_error", 404 => "invalid_request_error" }.each do |code, type|
      %w[mock-text mock-text-only].each do |model|
        status, headers, body = post("/v1/responses", model: model, input: "!mock error=#{code}")
        assert_equal code, status
        assert_equal "application/json", headers["content-type"]
        assert_equal type, JSON.parse(body.join).dig("error", "type")
      end
    end
  end

  # `retry_after=N` is the header on the wire, on the plain HTTP arm of
  # every endpoint: the streaming lane and a unary one both carry it.
  def test_a_scripted_retry_after_rides_the_error_as_the_header
    status, headers, body = post("/v1/responses", model: "mock-text", input: "!mock error=429 retry_after=10")

    assert_equal 429, status
    assert_equal "10", headers["retry-after"]
    assert_equal "rate_limit_error", JSON.parse(body.join).dig("error", "type")

    status, headers, = post("/v1/embeddings", model: "mock-embedding", input: "!mock error=503 retry_after=7")
    assert_equal 503, status
    assert_equal "7", headers["retry-after"]

    _, headers, = post("/v1/responses", model: "mock-text", input: "!mock error=503")
    assert_nil headers["retry-after"], "no script, no header"
  end

  def test_a_scripted_delay_is_requested_rather_than_slept_through
    post("/v1/responses", model: "mock-text", input: "!mock slow=0.05 -- hi")

    assert_includes @clock.slept, 0.05
  end

  def test_a_mistyped_directive_is_a_four_hundred_not_a_happy_path
    status, _, body = post("/v1/responses", model: "mock-text", input: "!mock erorr=503")

    assert_equal 400, status
    assert_equal "invalid_request_error", JSON.parse(body.join).dig("error", "type")
  end

  # ---- the unary endpoints ------------------------------------------------

  def test_embeddings_answer_one_vector_per_input
    status, _, body = post("/v1/embeddings", model: "mock-embedding",
                           input: %w[alpha beta], dimensions: 4)
    payload = JSON.parse(body.join)

    assert_equal 200, status
    assert_equal 2, payload.fetch("data").length
    assert_equal [0, 1], payload.fetch("data").map { _1.fetch("index") }
    assert payload.fetch("data").all? { _1.fetch("embedding").length == 4 }
    refute_nil payload["usage"]
  end

  def test_images_answer_decodable_bytes_rather_than_a_placeholder
    status, _, body = post("/v1/images/generations", model: "mock-image", prompt: "a cat", n: 2)
    payload = JSON.parse(body.join)

    assert_equal 200, status
    assert_equal 2, payload.fetch("data").length
    bytes = payload.dig("data", 0, "b64_json").unpack1("m0")
    assert_equal "\x89PNG".b, bytes.byteslice(0, 4), "a real PNG signature"
  end

  def test_speech_answers_audio_bytes
    status, headers, body = post("/v1/audio/speech", model: "mock-speech", input: "read this")

    assert_equal 200, status
    assert_equal "audio/wav", headers["content-type"]
    assert_equal "RIFF".b, body.join.byteslice(0, 4)
  end

  def test_transcription_reads_its_multipart_parts
    status, _, body = post_multipart("/v1/audio/transcriptions",
                                     model: "mock-transcription", prompt: "a hint",
                                     file: "RIFF....WAVE")
    payload = JSON.parse(body.join)

    assert_equal 200, status
    assert_includes payload.fetch("text"), "12 bytes"
    refute_nil payload["usage"]
  end

  def test_the_model_list_names_every_shipped_dev_model
    status, _, body = get("/v1/models")
    ids = JSON.parse(body.join).fetch("data").map { _1.fetch("id") }

    assert_equal 200, status
    assert_equal E2E::MockLLM::App::MODELS.keys.sort, ids.sort
  end

  # ---- refusals -----------------------------------------------------------

  def test_a_model_on_the_wrong_endpoint_is_refused
    status, _, body = post("/v1/responses", model: "mock-embedding", input: "hi")

    assert_equal 404, status
    assert_equal "model_not_found", JSON.parse(body.join).dig("error", "code")
  end

  def test_an_unknown_endpoint_is_refused
    status, = get("/v1/chat/completions")

    assert_equal 404, status,
      "the chat wire is deliberately absent: every dev text profile rides openai_responses"
  end

  def test_a_body_that_is_not_json_is_refused
    status, _, body = @app.call(
      "REQUEST_METHOD" => "POST", "PATH_INFO" => "/v1/responses",
      "rack.input" => StringIO.new("{oops")
    )

    assert_equal 400, status
    assert_equal "invalid_request_error", JSON.parse(body.join).dig("error", "type")
  end

  private

    def get(path)
      @app.call("REQUEST_METHOD" => "GET", "PATH_INFO" => path, "rack.input" => StringIO.new(""))
    end

    def post(path, **payload)
      @app.call(
        "REQUEST_METHOD" => "POST", "PATH_INFO" => path,
        "CONTENT_TYPE" => "application/json",
        "rack.input" => StringIO.new(JSON.generate(payload))
      )
    end

    def post_multipart(path, **parts)
      boundary = "----MockBoundary"
      body = parts.map do |name, value|
        "--#{boundary}\r\nContent-Disposition: form-data; name=\"#{name}\"\r\n\r\n#{value}\r\n"
      end.join + "--#{boundary}--\r\n"

      @app.call(
        "REQUEST_METHOD" => "POST", "PATH_INFO" => path,
        "CONTENT_TYPE" => "multipart/form-data; boundary=#{boundary}",
        "rack.input" => StringIO.new(body)
      )
    end

    def sse(body)
      body.to_a.join.split("\n\n").filter_map do |frame|
        data = frame.sub(/\Adata: /, "").strip
        next if data.empty? || data == "[DONE]"

        JSON.parse(data)
      end
    end
end
