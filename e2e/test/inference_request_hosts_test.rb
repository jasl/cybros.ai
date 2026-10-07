require "test_helper"
require "securerandom"
require "support/actor_provisioning"

# WHICH HOST RAN THE TURN, AND WHAT THAT COSTS THE CALLER.
#
# `Wake` wakes both execution hosts for a text lane and gives neither a tiebreaker — the comment in
# it is explicit that primacy is "the runner listening faster, never the queue host waiting". So
# with both running, the host that executes a turn is a race, and on THIS plane the two hosts do not
# give a caller the same thing: a InferenceRequest's narration is durable items under the inference_request lock, and
# the one sink chooser gives that kind to the reactor host alone. A conversation's streaming
# narration is the other case entirely — both hosts build that sink, which `streaming_test` pins on
# each of them.
#
# The plain turn lane therefore cannot assert narration, and this one exists
# to say what that lane cannot. Each case runs ONE host, which is possible
# because each is self-sufficient — the runner drains admission itself
# (`ModelRunner::Host#admission_loop`) exactly as the queue worker does.
#
# What this proves that nothing else does: that the reactor claims work off a
# LISTEN/NOTIFY in another process and streams a provider's SSE frames into
# durable items a caller can read back — and that the queue host, taking the
# same work, honestly produces no narration rather than pretending to.
class InferenceRequestHostsTest < Minitest::Test
  TURN_TIMEOUT = 60
  # 120 requests a minute per identity (AgentAPI::V1::BaseController::
  # RATE_LIMIT), and a journey that polls faster than that gets 429s of its own
  # making. A second between reads is both under the ceiling and about what a
  # real polling consumer would do.
  POLL = 1.0
  PROMPT = "!mock usage=3:9 -- say hi".freeze
  ANSWER = "Mock: say hi".freeze

  def setup
    @base_url = E2E.base_url
    @actor = E2E::ActorProvisioning.world(@base_url).shared_human
    @client = CybrosAgent::Client.new(base_url: @base_url, credential: @actor.member_token)
    E2E.enable_dev_lane!
    @workspace = @client.workspaces.create(
      name: "InferenceRequest hosts #{SecureRandom.hex(4)}", idempotency_key: SecureRandom.uuid
    )
    @lane = @client.workspace(@workspace.public_id).inference_requests
  end

  def teardown
    # The next lane states its own composition, but leaving one host stopped
    # would make whichever runs next depend on the order tests happened to run.
    E2E.hosts.start
  end

  # THE PRIMARY HOST for every text lane, and until this round nothing had ever
  # started one: `ModelRunner::Host#run`, its LISTEN loop, its claim loop and
  # its signal traps had zero callers anywhere in the tree.
  #
  # THE TWO HOSTS ARE STARTED IN SEQUENCE, and the sequence is the assertion.
  # The runner alone executes the turn, so the narration below can only have
  # come from it — with both up, `Wake` gives neither a tiebreaker and the
  # evidence would be a coin toss. Then the queue host is started, because the
  # caller-visible TERMINAL EVENT is not the runner's to write: `ExecuteAttempt`
  # enqueues `InferenceRequests::ConvergeTerminalEventsJob` and only a queue worker
  # drains it. A deployment that ran the reactor alone would stream deltas and
  # then go quiet — worth knowing, and this is where it is written down.
  def test_the_model_runner_claims_the_work_and_narrates_it
    E2E.hosts.pin(:runner)

    public_id = create_turn.public_id

    final = await_terminal(public_id)
    assert_equal "completed", final.status
    assert_equal ANSWER, final.output_text

    # The invocation is terminal and the caller can read the answer — but the
    # terminal EVENT is still owed to a job nobody is draining yet.
    assert_empty terminal_events(public_id),
      "the terminal event is a queued job's to write, not the reactor's"

    E2E.hosts.start(:jobs)
    items = await_terminal_event(public_id)
    deltas = items.select { _1.type == "text_delta" }
    refute_empty deltas,
      "the runner is the host that narrates; a turn it executed must leave deltas"

    # The narration is the ANSWER, arriving in pieces — not a separate thing
    # that happens to look like it. Reassembling is the only check that says so.
    assert_equal ANSWER, deltas.map { _1.payload.fetch("text") }.join,
      "the deltas must reassemble to exactly the answer the caller reads"

    # Every delta precedes the terminal item, which is what makes the stream
    # followable: a caller that stops at `result` has already seen it all.
    assert_equal "result", items.last.type
  end

  # THE FALLBACK HOST, and the point is that it is honestly worse. A caller on this host gets the
  # same answer and the same usage with no narration at all: the InferenceRequest's narration is DURABLE —
  # appended items under the inference_request lock — and the one sink chooser gives that kind to the reactor
  # host alone (both hosts build the hosted plane's streaming sink). Asserting the ABSENCE is what
  # keeps this a known property rather than an intermittent disappointment.
  def test_the_queue_host_completes_the_same_turn_without_narrating_it
    E2E.hosts.pin(:jobs)

    public_id = create_turn.public_id

    final = await_terminal(public_id)
    assert_equal "completed", final.status,
      "the fallback host must carry a turn to completion on its own"
    assert_equal ANSWER, final.output_text

    assert_equal 3, final.result.usage.input_tokens
    assert_equal 9, final.result.usage.output_tokens

    items = await_terminal_event(public_id)
    assert_empty items.select { _1.type == "text_delta" },
      "the queue host builds no durable sink, so a InferenceRequest it executed narrates nothing"
    assert_equal "result", items.last.type
  end

  private

    def create_turn
      created = @lane.create(
        workload: "text_generation", model: "dev/mock-text", input: PROMPT,
        idempotency_key: SecureRandom.uuid
      )
      refute_predicate created, :replayed?, "a fresh key is new work, not a receipt"
      refute_predicate created, :finished?, "creation is asynchronous by contract"
      created
    end

    def await_terminal(public_id)
      poll_until("the turn never reached a terminal state") do
        # TERMINALITY IS THE RESULT ENVELOPE, which is what the server
        # guarantees — never a status string this harness froze.
        result = @lane.fetch(public_id)
        result.finished? ? result : nil
      end
    end

    def terminal_events(public_id)
      replay(public_id).select { _1.type == "result" }
    end

    def await_terminal_event(public_id)
      poll_until("the replay window never ended on a terminal item") do
        items = replay(public_id)
        items.any? && items.last.type == "result" ? items : nil
      end
    end

    def replay(public_id)
      @lane.events(public_id).items
    rescue CybrosAgent::Api::RateLimited => throttle
      throttled!(throttle)
    end

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

    def poll_until(complaint)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + TURN_TIMEOUT
      loop do
        found = yield
        return found if found

        flunk(complaint) if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        sleep POLL
      end
    end
end
