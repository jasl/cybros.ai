require "test_helper"
require "securerandom"
require "support/actor_provisioning"
require "async"
require "support/realtime_lane"

# THE REALTIME LEG: LLM API → Nexus → a subscriber on a WebSocket.
#
# Everything else about a turn is proven through REST, which is the authority
# by design: the durable replay window is the truth and the socket is an
# accelerator that may miss, duplicate, or reorder. That framing only holds up
# if the accelerator actually accelerates, and nothing had ever checked. The
# broadcast is written by whichever process EXECUTED the turn — here the model
# runner, a different process from the Puma the subscriber is attached to — so
# this lane is the only place a cross-process bus is exercised at all.
#
# It found a real defect on the first run: `config/cable.yml` left development
# on Rails' `async` adapter, which is an IN-PROCESS pubsub. Every broadcast the
# runner made went nowhere, silently, in every non-production deployment.
#
# WHAT THIS PROVES THAT NOTHING ELSE DOES:
#   - a real WebSocket handshake authenticated by the ordinary member
#     credential, and a subscription the server CONFIRMS
#   - deltas crossing a process boundary as they are produced, not after
#   - the socket item and the REST replay item being the same object, which is
#     what makes "resume from your last cursor" a real recovery path
class InferenceRequestStreamTest < Minitest::Test
  include E2E::RealtimeLane

  PROMPT = "!mock usage=4:6 -- say hi".freeze
  ANSWER = "Mock: say hi".freeze
  TURN_TIMEOUT = 60
  POLL = 1.0

  def setup
    @base_url = E2E.base_url
    @actor = E2E::ActorProvisioning.world(@base_url).shared_human
    @client = CybrosAgent::Client.new(base_url: @base_url, credential: @actor.member_token)
    E2E.enable_dev_lane!
    # The RUNNER, alone. It is the host that narrates, and pinning it is what
    # makes the deltas below attributable rather than a coin toss.
    E2E.hosts.pin(:runner)
    @workspace = @client.workspaces.create(
      name: "InferenceRequest stream #{SecureRandom.hex(4)}", idempotency_key: SecureRandom.uuid
    ).workspace
    @lane = @client.workspace(@workspace.public_id).inference_requests
  end

  def teardown
    E2E.hosts.start
  end

  def test_a_subscriber_watches_the_answer_arrive_from_another_process
    created = @lane.create(
      workload: "text_generation", model: "dev/mock-text", input: PROMPT,
      idempotency_key: SecureRandom.uuid
    )
    public_id = created.public_id

    # SUBSCRIBE AFTER CREATING, ON PURPOSE. That is the honest order for a
    # consumer — the resource has to exist to be addressed — and it is the
    # order that makes the REST window load-bearing: whatever was emitted
    # before the confirmation is only recoverable through the replay endpoint.
    # THE SHIPPED CLIENT, driven the way a consumer must drive it: it is
    # fiber-native, so the socket work runs inside a reactor. That is not a
    # harness detail — it is the usage shape, and a journey that faked it
    # would prove nothing about the thing that ships.
    narrated = []
    closing = []
    # THE CLIENT MUST BE CLOSED, and not only for tidiness: its frame pump is
    # an ordinary child task, so a reactor block that does not close it waits
    # on a pump that runs until the socket does — which is a hang, not a leak.
    # Closing is what ends the pump and lets the reactor unwind.
    with_reactor do
      subscription = subscribe_to(public_id)

      # PHASE ONE: the runner narrates, then simply stops. It has no closing
      # item to send, because the terminal event is a queued job's to write —
      # so the honest end of this phase is the stream GOING QUIET, and a
      # subscriber that waited for `result` here would wait forever. That
      # constraint is invisible over REST and visible on the socket.
      narrated = drain_until_quiet(subscription, idle: 3)
      refute_empty narrated,
        "the runner executed in another process and the subscriber heard nothing — " \
        "the cable bus does not cross processes in this environment"

      deltas = narrated.select { _1.fetch("type") == "text_delta" }
      refute_empty deltas, "a narrated turn must put its deltas on the socket, not only in the table"
      assert_equal ANSWER, deltas.map { _1.dig("payload", "text") }.join,
        "the streamed deltas must reassemble to exactly the answer"
      assert_empty narrated.select { _1.fetch("type") == "result" },
        "the reactor does not close the stream; a queue host does"

      # PHASE TWO: the queue host arrives and the SAME subscription sees the
      # turn close. One socket, two producing processes.
      E2E.hosts.start(:jobs)
      closing = drain_until(subscription, "result", timeout: TURN_TIMEOUT)
      assert_equal "result", closing.last&.fetch("type"),
        "the terminal item must reach the subscriber too, not only the replay window"
    end
    streamed = narrated + closing

    # ONE PROJECTION, TWO TRANSPORTS. This is the claim the whole recovery
    # story rests on: a client that reconnects and replays from its last
    # cursor must get objects it can apply the same way. Comparing the durable
    # items to the streamed ones by cursor is what makes that testable.
    replayed = await_replay(public_id)
    streamed_by_sequence = streamed.to_h { [_1.fetch("sequence"), _1] }
    replayed.each do |item|
      streamed_item = streamed_by_sequence[item.sequence]
      next if streamed_item.nil?

      assert_equal item.type, streamed_item.fetch("type")
      assert_equal item.public_id, streamed_item.fetch("public_id")
      assert_equal item.cursor, streamed_item.fetch("cursor")
      assert_equal item.payload, streamed_item.fetch("payload"),
        "the socket and the replay window must carry the same item, not two renderings of it"
    end

    # Every sequence the socket delivered is present in the durable window —
    # the socket never invents an item the authority does not have. Merging by
    # SEQUENCE rather than by cursor is the point: it is the value a follower
    # can compare, and comparing is how it notices a gap.
    assert_empty streamed_by_sequence.keys - replayed.map(&:sequence),
      "the stream announced an item the replay window cannot serve"
    assert_equal replayed.map(&:sequence).sort, replayed.map(&:sequence),
      "the durable window is ascending, which is what makes the merge one pass"
  end

  # THE SOCKET REJECTS, AND SAYS SO. Without this, an authenticated connection
  # could be subscribing to nothing and every assertion above would still pass
  # on a channel that streamed to anyone who asked.
  #
  # Which TIERS reject is settled in the channel's own unit test, over every
  # containment rule at once. What only a real socket can show is that the
  # refusal arrives as a protocol `reject_subscription` a client can act on —
  # rather than a silent connection that never delivers anything.
  def test_an_unknown_resource_is_refused_on_the_protocol
    with_reactor do
      error = assert_raises(CybrosAgent::Realtime::SubscriptionRejectedError) do
        subscribe_to(SecureRandom.uuid)
      end
      assert_includes error.identifier, "InferenceRequestEventsChannel",
        "a refusal has to say WHICH subscription, because one connection carries many"
    end
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

    def await_replay(public_id)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + TURN_TIMEOUT
      loop do
        items = begin
          @lane.events(public_id).items
        rescue CybrosAgent::Api::RateLimited => throttle
          throttled!(throttle)
        end
        return items if items.any? && items.last.type == "result"

        flunk("the durable window never ended on a terminal item") if
          Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        sleep POLL
      end
    end
end
