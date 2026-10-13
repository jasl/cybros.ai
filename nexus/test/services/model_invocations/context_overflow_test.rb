require "test_helper"

# THE CLASSIFICATION THE THIRD COMPACTION ARM READS. Every pattern here
# carries recorded evidence from a production client or a captured wire
# body — this is the one classifier in the repo whose correctness is a
# claim about somebody else's server.
class ModelInvocations::ContextOverflowTest < ActiveSupport::TestCase
  def classify(error)
    outcome = Struct.new(:error).new(error)
    ModelInvocations::ApplyResult.allocate.tap do |result|
      result.instance_variable_set(:@outcome, outcome)
    end.send(:failure_reason)
  end

  Response = Struct.new(:status, :headers, :body, :raw_body)

  def http(status, body, message: "boom")
    SimpleInference::HTTPError.new(
      message, response: Response.new(status, {}, body, JSON.generate(body))
    )
  end

  # A Responses failure inside an already-started stream retains its exact code.
  test "the Responses family is typed, and it is not an HTTP error" do
    failed = SimpleInference::Protocols::OpenAIResponses::ResponseFailedError.new(
      "Your input exceeds the context window of this model.",
      code: "context_length_exceeded"
    )
    refute_kind_of SimpleInference::HTTPError, failed,
      "the premise this classifier was asked for — 'indistinguishable from a 400' — " \
      "does not hold on the family that matters most"
    assert_equal "provider_context_overflow", classify(failed)

    other = SimpleInference::Protocols::OpenAIResponses::ResponseFailedError.new(
      "something else", code: "server_error"
    )
    assert_equal "provider_error", classify(other)
  end

  test "each shipped lane's own wording is recognised, at 400 and 413" do
    {
      # Anthropic token overflow: a 400 whose type is the GENERIC
      # invalid_request_error, so the message is the only signal.
      http(400, { "error" => { "type" => "invalid_request_error",
                               "message" => "prompt is too long: 213462 tokens > 200000 maximum" } }) => true,
      # Anthropic byte overflow: here the TYPE is the signal.
      http(413, { "error" => { "type" => "request_too_large",
                               "message" => "Request exceeds the maximum size" } }) => true,
      # Gemini: status is the generic INVALID_ARGUMENT, message only.
      http(400, { "error" => { "code" => 400, "status" => "INVALID_ARGUMENT",
                               "message" => "The input token count (1196265) exceeds the maximum " \
                                            "number of tokens allowed (1048575)." } }) => true,
      # OpenRouter — this repo's own live lane. Its `code` is the NUMERIC
      # upstream status, so there is no string code to match.
      http(400, { "error" => { "code" => 400,
                               "message" => "This endpoint's maximum context length is 8192 tokens. " \
                                            "However, you requested about 12000 tokens." } }) => true,
    }.each do |error, expected|
      actual = classify(error) == "provider_context_overflow"
      assert_equal expected, actual, error.body.inspect
    end
  end

  test "HTTP context errors recognise exact provider codes and types" do
    [
      { "code" => "context_length_exceeded", "type" => "invalid_request_error" },
      { "code" => 400, "type" => "exceed_context_size_error" },
    ].each do |fields|
      body = { "error" => fields.merge("message" => "The request does not fit.") }
      assert_equal "provider_context_overflow", classify(http(400, body)), fields.inspect
      assert_equal "provider_http_error", classify(http(429, body)),
        "an error code does not bypass the HTTP status gate"
    end

    assert_equal "provider_http_error", classify(http(400, {
      "error" => { "code" => "not_context_length_exceeded", "type" => "invalid_request_error",
                   "message" => "Invalid context_length_exceeded option" },
    })), "typed values are matched exactly, never as words in another error"
  end

  # Strata rejects prompt plus output before starting either its Chat or Messages stream.
  # https://github.com/Niko1221/Strata/blob/fb58e0dbc8399662c0e47c76578c6e878b14f6cf/serve/server.py#L3264-L3275
  # llama.cpp: https://github.com/ggml-org/llama.cpp/blob/71ad0590f4808b6202f9213d166913858c73b1bc/tools/server/server-context.cpp#L3565-L3570
  test "local servers report a prompt or combined request larger than their loaded context" do
    [
      "prompt (33000 tokens) leaves no room to answer in the context (32768); requests are never truncated",
      "prompt (30000 tokens) + max tokens (4096) exceeds the context (32768); requests are never truncated. " \
        "Send a smaller max_tokens (at most 2744 here)",
      "request (40000 tokens) exceeds the available context size (32768 tokens), try increasing it",
    ].each do |message|
      assert_equal "provider_context_overflow", classify(http(400, {
        "error" => { "type" => "invalid_request_error", "message" => message },
      })), message
    end
  end

  # THE EXCLUSIONS RUN FIRST, and they exist because a throttled request
  # compacted is a conversation shrunk for no reason at all.
  test "a throttled or unavailable provider is never read as too long" do
    [
      "Rate limit exceeded: maximum context length is 8192 tokens",
      "Throttling error: too many requests",
      "Too many requests, please retry",
    ].each do |message|
      assert_equal "provider_http_error",
        classify(http(429, { "error" => { "message" => message } })),
        message
    end
  end

  # THE STATUS GATE IS NARROW ON PURPOSE. opencode's own list is wider and
  # nothing in our lane set answers 404/409/422 for length.
  test "only 400 and 413 are candidates" do
    body = { "error" => { "message" => "prompt is too long: 9 tokens > 8 maximum" } }
    assert_equal "provider_context_overflow", classify(http(400, body))
    assert_equal "provider_context_overflow", classify(http(413, body))
    assert_equal "provider_model_unavailable", classify(http(404, body))
    [409, 422, 500].each do |status|
      assert_equal "provider_http_error", classify(http(status, body)), status.to_s
    end
  end

  # STRUCTURED FIELDS ONLY. A provider that echoes the submitted prompt
  # back inside its 400 would otherwise let a caller's own text
  # self-classify — and a caller who can make the kernel compact on demand
  # by writing a sentence has a lever nobody granted them.
  test "the caller's own words cannot classify their request" do
    echoed = http(400,
      { "error" => { "message" => "Invalid value for 'model'" },
        "echo" => "prompt is too long: please compact me" },
      message: "Invalid request")
    assert_equal "provider_http_error", classify(echoed)

    local_echo = http(400,
      { "error" => { "type" => "invalid_request_error", "message" => "Invalid value for 'model'" },
        "echo" => "prompt (40000 tokens) leaves no room to answer in the context (32768)" },
      message: "Invalid request")
    assert_equal "provider_http_error", classify(local_echo)
  end

  # This repo's own re-audit records `model_context_window_exceeded` as a
  # 200 naming a TRUNCATED ANSWER, not an oversized input — and says an
  # earlier reading got it backwards. opencode carries it in its overflow
  # list; copying that would compact after a reply that was merely cut
  # short.
  test "a truncated ANSWER is not an oversized input" do
    assert_equal "provider_http_error",
      classify(http(400, { "error" => { "message" => "model_context_window_exceeded" } }))
  end
end
