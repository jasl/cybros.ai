require "test_helper"

# The send: what the client reported, recorded once, and nothing else.
#
# Every test here drives a FAKE adapter rather than a network, because the
# subject is the mapping from what a client does to what the row says — and
# that mapping is the whole of this service's judgment.
class ModelInvocations::DispatchTest < ActiveSupport::TestCase
  # Stands in for the gem's adapters at their own seam. Returning versus
  # raising is exactly the distinction under test, so the fake does only that.
  class FakeAdapter < SimpleInference::HTTPAdapter
    def initialize(behaviour) = @behaviour = behaviour

    def call(_request)
      raise @behaviour if @behaviour.is_a?(Exception)

      @behaviour
    end
  end

  setup do
    @account = accounts(:cybros)
    DevModelLane.ensure_enabled!(@account)
    @profile = DevModelLane.profile_for("dev/mock-text")
    @attempt = started_attempt
  end

  test "a client that returns is recorded with its assembled result" do
    result = dispatch(envelope(200, success_body, { "x-request-id" => "req_abc" }))

    assert_predicate result, :sent?
    assert_predicate result, :succeeded?
    assert_nil result.error
    assert_equal "assembled by the gem", result.result.output_text,
      "the send returns the assembled final result, not the raw provider response"
    assert_equal "req_abc", result.request_id
  end

  test "dispatch executes the already compiled request without rebuilding its protocol" do
    compiled = request
    validator = SimpleInference::Planning::RequestValidator
    validator.stub(:validate_responses_request, ->(**) { flunk "request was validated twice" }) do
      result = dispatch(envelope(200, success_body), request: compiled)

      assert_predicate result, :succeeded?
    end
  end

  # The header is wire-controlled and the column is varchar(128): unbounded,
  # a hostile value raised ValueTooLong AFTER the response was observed,
  # stranding a delivered answer with no receipt (settlement review).
  test "an oversize request id is truncated, never a strand" do
    result = dispatch(envelope(200, success_body, { "x-request-id" => "r" * 200 }))

    assert_predicate result, :succeeded?
    assert_equal "r" * 128, result.request_id
  end

  test "a header with invalid bytes is scrubbed, never a crashed write" do
    result = dispatch(envelope(200, success_body, { "x-request-id" => "\xFF\xFEreq_ok".b }))

    assert_predicate result, :succeeded?
    assert_equal "req_ok", result.request_id,
      "dropped bytes are not evidence; the honest tail survives"
  end

  test "a NUL byte in the header is deleted, never a crashed write" do
    result = dispatch(envelope(200, success_body, { "x-request-id" => "req_\u0000ok" }))

    assert_predicate result, :succeeded?
    assert_equal "req_ok", result.request_id,
      "NUL is valid UTF-8 that PostgreSQL text still refuses"
  end

  # The status is the provider's answer, not the client's report. On the
  # high-level path a provider refusal arrives as the gem's typed HTTPError —
  # the provider ANSWERED, and the error rides the result for terminal apply
  # to classify, with the request id read from the response it carries.
  test "a provider error is recorded with its response's request id" do
    result = dispatch(envelope(
      500, { "error" => { "message" => "upstream" } }, { "x-request-id" => "req_refusal" }
    ))

    assert_predicate result, :sent?
    assert_not_predicate result, :succeeded?
    assert_kind_of SimpleInference::HTTPError, result.error
    assert_equal 500, result.error.status
    assert_equal "req_refusal", result.request_id
  end

  # Whatever the client raises is the record — its own class, nothing
  # derived from it; there is no response, so there is no request id.
  test "a raised client error is recorded as the error with no request_id" do
    [
      SimpleInference::TimeoutError.new("read timed out"),
      SimpleInference::ConnectionError.new("connection reset"),
      SimpleInference::ConnectionNotEstablishedError.new("connect timed out"),
    ].each do |raised|
      result = dispatch(raised)

      assert_predicate result, :sent?, raised.class.name
      assert_not_predicate result, :succeeded?, raised.class.name
      assert_same raised, result.error
      assert_nil result.request_id, raised.class.name
    end
  end

  test "the adapter follows the claimed host in the send context" do
    assert_kind_of SimpleInference::HTTPAdapters::HTTPX, adapter_for("solid_queue")
    assert_kind_of SimpleInference::HTTPAdapters::AsyncHTTP, adapter_for("model_runner")
    assert_raises(ArgumentError) { adapter_for("lambda") }
  end

  # ONE INSTANCE PER HOST, for the process. The async adapter holds its client
  # pool in ordinary instance variables, so a fresh instance per send rebuilt
  # it every time: fresh TCP, fresh TLS, no h2 multiplexing. Concurrently, too
  # — the memo is what two threads share, and a hash created outside the mutex
  # would orphan one of them along with the pool it had already built.
  test "each host's adapter is one instance, shared across sends and threads" do
    assert_same adapter_for("solid_queue"), adapter_for("solid_queue")
    assert_same adapter_for("model_runner"), adapter_for("model_runner")
    refute_same adapter_for("solid_queue"), adapter_for("model_runner")

    seen = 8.times.map { Thread.new { adapter_for("model_runner") } }.map(&:value)
    assert_equal 1, seen.uniq(&:object_id).length
  end

  # THE CARVE-OUT, and it is load-bearing rather than tidy. Every shipped text
  # lane derives 120s from min(120, deadline/2); a unary image generation has a
  # 600s deadline and a transcription 900s, so an idle bound applied to them
  # would abort healthy work at two minutes and record the client's timeout —
  # an attempt burned, a receipt owed.
  test "a unary send carries the total deadline and no idle bound" do
    client = ModelInvocations::Dispatch
      .new(attempt: @attempt, context: context, request: request)
      .send(:client)

    assert_equal @profile.total_execution_deadline_seconds, client.config.timeout
    assert_nil client.config.read_timeout
  end

  test "a streaming send carries the lane's declared idle bound" do
    client = ModelInvocations::Dispatch
      .new(attempt: @attempt, context: context, request: request(stream: true))
      .send(:client)

    assert_equal @profile.total_execution_deadline_seconds, client.config.timeout
    assert_equal @profile.stream_idle_timeout_seconds, client.config.read_timeout
    assert_operator client.config.read_timeout, :<, client.config.timeout
  end

  # The measurements only a live send can take. They go to settlement, never
  # onto the Attempt — nothing later re-derives them from wall-clock columns
  # written at different moments for different reasons.
  test "timing is measured monotonically and stored on no row" do
    result = dispatch(envelope(200, { "id" => "resp_1" }))

    assert_operator result.timing.duration_ms, :>=, 0
    assert_nil result.timing.time_to_first_token_ms, "a unary send has no first token"
    assert_not_includes ModelInvocationAttempt.column_names, "duration_ms"
    assert_not_includes ModelInvocationAttempt.column_names, "time_to_first_token_ms"
  end


  # A credentialless lane hands over nothing at all rather than an empty
  # string, so no Authorization header can be built from a blank secret.
  test "a credentialless lane sends no credential material" do
    client = ModelInvocations::Dispatch
      .new(attempt: @attempt, context: context, request: request)
      .send(:client)

    assert_nil client.config.api_key
    assert_not client.config.headers.key?("Authorization")
  end

  private

    # A lambda, not the adapter itself: Minitest CALLS a stub value that
    # responds to `call`, and an HTTP adapter is exactly that — so passing one
    # directly makes the stub invoke it and hand back its return value. The
    # raising cases then "passed" for the wrong reason, from a rescue two
    # layers away from the one under test.
    def dispatch(behaviour, request: request())
      fake = FakeAdapter.new(behaviour)
      ModelInvocations::ExecutionAdapter.stub(:for, ->(*) { fake }) do
        ModelInvocations::Dispatch.call(
          attempt: @attempt, context: context, request: request
        )
      end
    end

    def adapter_for(host) = ModelInvocations::ExecutionAdapter.for(host)

    def context
      ModelInvocations::ProviderStart::SendContext.new(
        credential: nil, base_url: "http://127.0.0.1:3000/mock_llm",
        profile: @profile, host: "solid_queue"
      )
    end

    # The adapter contract is an envelope hash, not a Response — the protocol
    # is what turns one into the other, and keeping the fake at the real seam
    # is what makes these tests about the mapping rather than about a double.
    def envelope(status, body, headers = {})
      { status: status, headers: { "content-type" => "application/json" }.merge(headers),
        body: JSON.generate(body) }
    end

    def request(stream: false)
      compile_client = SimpleInference::Client.new(
        execution_profile: @profile,
        base_url: "http://127.0.0.1:3000/mock_llm",
        adapter: FakeAdapter.new(nil)
      )
      compile_client.responses.compile_from_validated(
        model: "mock-text", stream: stream,
        input: [{ "role" => "user", "content" => [{ "type" => "input_text", "text" => "hi" }] }]
      )
    end

    # What the openai_responses wire calls a completed unary body — the
    # assembler reads output out of it, which is what the success test pins.
    def success_body
      {
        "id" => "resp_1", "status" => "completed",
        "output" => [{
          "type" => "message", "role" => "assistant",
          "content" => [{ "type" => "output_text", "text" => "assembled by the gem" }],
        }],
        "usage" => { "input_tokens" => 1, "output_tokens" => 4 },
      }
    end

    def started_attempt
      selection = DevModelLane.selection(workload: "text_generation", account: @account)
      one_shot = OneShot.create!(
        account: @account, workspace: workspaces(:shared), creating_user: users(:member),
        workload: selection.workload
      )
      invocation = DevModelLane.create_invocation!(one_shot: one_shot, selection: selection)
      attempt = ModelInvocationAttempt.create!(
        account: @account, model_invocation: invocation, ordinal: 1,
        admission_shape: "admitted_free", deadline_at: 10.minutes.from_now
      )
      attempt.update!(
        provider_started_at: Time.current, status: "running", settlement_state: "pending"
      )
      attempt
    end
end
