require "test_helper"
require "securerandom"
require "support/actor_provisioning"
require "support/nexus_operator"

# ONE SINGLE-TURN LLM CALL, THROUGH A DEPLOYED SYSTEM.
#
# Everything below this lane was already connected and green: an in-process
# integration test drives the whole chain — create, admission, claim, request
# build, dispatch, apply, usage, terminal event — with only the HTTP adapter
# faked. What no test could reach was the system as it actually runs. Nothing
# had ever put a turn through a booted Puma, a Solid Queue supervisor, a
# `bin/model_runner` reactor, a real TCP socket, and a provider process that
# is not in this address space. The fake provider had no launcher and no
# catalog entry pointing at it; the harness started no executor at all.
#
# So this lane proves the things only a deployed run can:
#   - the catalog OVERRIDE SEAM: the dev provider's address comes from a
#     fragment the harness writes, the same seam an operator uses
#   - a REAL HTTP transport carrying a real request to a real listener
#   - an EXECUTOR that is not the test: work created by one process is
#     admitted and executed by others
#   - the answer, the usage, and the durable replay stream a caller reads back
#
# It deliberately does NOT assert which host executed the turn. `Wake` wakes
# both the runner and the queue immediately and neither is given a
# tiebreaker, so the streaming narration only the runner produces is not
# guaranteed for any one run. Pinning a host is the next lane, and it is
# worth having precisely because this one cannot do it.
class InferenceRequestTurnTest < Minitest::Test
  TURN_TIMEOUT = 60
  # 120 requests a minute per identity (AgentAPI::V1::BaseController::
  # RATE_LIMIT), and a journey that polls faster than that gets 429s of its own
  # making. A second between reads is both under the ceiling and about what a
  # real polling consumer would do.
  POLL = 1.0
  MOCK_TURN = { workload: "text_generation", model: "dev/mock-text" }.freeze

  def setup
    @base_url = E2E.base_url
    world = E2E::ActorProvisioning.world(@base_url)
    @actor = world.shared_human
    @client = CybrosAgent::Client.new(base_url: @base_url, credential: @actor.member_token)
    E2E.enable_dev_lane!
    E2E.hosts.start
    @workspace = @client.workspaces.create(
      name: "InferenceRequest turn #{SecureRandom.hex(4)}", idempotency_key: SecureRandom.uuid
    )
    @lane = @client.workspace(@workspace.public_id).inference_requests
  end

  def test_a_created_inference_request_is_executed_by_the_deployment_and_read_back
    # `usage=7:5` pins what the provider will report, so the usage assertion
    # below is a fact about the path rather than about the fake's estimator.
    # A CONFIGURATION RIDES ALONG deliberately. Every generation parameter the
    # catalog declares used to 500 on this surface — Strong Parameters handed
    # the action a `Parameters` the envelope's digest could not encode — and no
    # in-process test could see it, because they all called the domain with a
    # Ruby Hash. Sending one here is what makes the deployed surface prove it.
    input = "!mock usage=7:5 -- say hi"
    estimate = @lane.estimate_input(**MOCK_TURN, input: input,
                                    configuration: { "temperature" => 0.25,
                                                     "max_output_tokens" => 64 })
    assert_operator estimate.input_tokens, :>, 0
    assert_predicate estimate, :tokenizer_exact?
    assert_equal 8192, estimate.catalog_input_token_limit
    assert_nil estimate.advisory_input_token_limit
    assert_equal "dev", estimate.model.provider_id

    created = @lane.create(**MOCK_TURN, input: input,
                           configuration: { "temperature" => 0.25, "max_output_tokens" => 64 },
                           idempotency_key: SecureRandom.uuid)

    refute_predicate created, :replayed?, "a fresh key is new work, not a receipt"
    assert_equal "queued", created.status
    public_id = created.public_id
    assert_equal "dev", created.model.provider_id

    # NOTHING IN THIS PROCESS EXECUTES IT. Reaching a terminal state at all is
    # the assertion: it means the enqueued admission was drained and a host
    # claimed the work, in other processes, against a provider on a socket.
    final = await_terminal(public_id)

    assert_equal "completed", final.result.status,
      "the deployed system did not carry the turn to completion"
    assert_equal "Mock: say hi", final.output_text,
      "the answer must be the one the fake provider composed, over the wire"

    assert_equal 7, final.result.usage.input_tokens
    assert_equal 5, final.result.usage.output_tokens

    # The durable replay window is what a caller reads to follow a turn, and
    # it ends in the terminal item whatever host produced it. POLLED, not read
    # once: the invocation reaching a terminal STATUS and the terminal EVENT
    # being appended are two different moments, and a caller following the
    # stream sees exactly this gap.
    items = await_terminal_event(public_id)
    assert_equal "result", items.last.type,
      "the replay window ends on the terminal item"

    # A time to first token means the answer STREAMED — the provider's SSE
    # frames were parsed as they arrived rather than a body being read whole.
    assert_operator final.result.timing.time_to_first_token_ms, :>=, 0
  end

  # A non-retryable provider refusal has to arrive as a typed terminal rather than wait for
  # the deadline sweep. Transport retries are separate from this terminal-result contract.
  def test_a_provider_failure_reaches_the_caller_as_a_terminal_state
    created = @lane.create(**MOCK_TURN, input: "!mock error=400 -- say hi",
                           idempotency_key: SecureRandom.uuid)

    final = await_terminal(created.public_id)

    refute_equal "completed", final.status,
      "a provider that refused must not read as a completed turn"
    refute_nil final.result.error, "a refused turn names why on the result envelope"
  end

  private

    # A 429 IS A BUG IN THIS HARNESS, not weather to be waited out. These lanes
    # poll one resource at 1Hz against a 120/minute per-resource budget, so
    # they cannot legitimately trip it — and swallowing the refusal to re-ask a
    # second later is precisely the client behaviour we would flag in someone
    # else's code. Failing here names the real problem instead of hiding it
    # behind a timeout somewhere further on.
    def throttled!(throttle)
      flunk("the journey tripped the API's own rate limit (Retry-After #{throttle.retry_after}s) — " \
            "a lane that polls faster than a consumer should is testing the wrong thing")
    end

    def await_terminal_event(public_id)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + TURN_TIMEOUT
      last = nil
      loop do
        last = begin
          @lane.events(public_id).items
        rescue CybrosAgent::Api::RateLimited => throttle
          throttled!(throttle)
        end
        return last if last.any? && last.last.type == "result"

        if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
          flunk("the replay window never ended on a terminal item; " \
                "saw #{last.map(&:type).inspect}")
        end
        sleep POLL
      end
    end

    def await_terminal(public_id)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + TURN_TIMEOUT
      last = nil
      loop do
        last = @lane.fetch(public_id)
        # TERMINALITY IS THE RESULT ENVELOPE, which is what the server
        # guarantees — never a status string this harness froze.
        return last if last.finished?

        if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
          flunk("the turn never reached a terminal state; last read: #{last.inspect}")
        end
        sleep POLL
      end
    end
end
