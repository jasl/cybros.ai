require "test_helper"
require "securerandom"
require "support/actor_provisioning"

# FOLLOWING A RUN WITHOUT SUBSCRIBING, against a deployed system.
#
# The socket is an accelerator and the durable window is the authority — a
# claim that only means something if a consumer using the authority alone gets
# everything, in order, once. `CybrosAgent::KernelFeed` is that consumer, and
# with no `subscribe:` it needs no websocket at all: this lane runs the whole
# pump over ordinary HTTP against a turn being executed in another process.
#
# What it proves that the SDK's own tests cannot: that the head the pump
# freezes is a real one, that draining terminates against a stream that is
# still producing, and that the events a follower assembles are the answer the
# caller reads back.
class InferenceRequestFeedTest < Minitest::Test
  TURN_TIMEOUT = 60
  PROMPT = "!mock usage=4:6 -- say hi".freeze
  ANSWER = "Mock: say hi".freeze

  def setup
    @base_url = E2E.base_url
    @actor = E2E::ActorProvisioning.world(@base_url).shared_human
    @client = CybrosAgent::Client.new(base_url: @base_url, credential: @actor.member_token)
    E2E.enable_dev_lane!
    # The runner alone, so the deltas below are attributable to it — and so
    # the terminal item genuinely arrives later, from the other host, which is
    # what makes the "keep draining" half of this lane real.
    E2E.hosts.pin(:runner)
    @workspace = @client.workspaces.create(
      name: "InferenceRequest feed #{SecureRandom.hex(4)}", idempotency_key: SecureRandom.uuid
    )
    @lane = @client.workspace(@workspace.public_id).inference_requests
  end

  def teardown
    E2E.hosts.start
  end

  def test_a_rest_only_follower_assembles_the_whole_turn_in_order
    created = @lane.create(
      workload: "text_generation", model: "dev/mock-text", input: PROMPT,
      idempotency_key: SecureRandom.uuid
    )
    public_id = created.public_id

    seen = []
    feed = @lane.feed(public_id)

    # DRAIN UNTIL THE TURN CLOSES. Each `each` is one full barrier pass that
    # returns when it reaches the head it froze; the loop is the caller's
    # own pacing, which is exactly the shape the docs recommend for a
    # follower that does not subscribe.
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + TURN_TIMEOUT
    until seen.any? { _1.type == "result" }
      feed.each { |event| seen << event }
      # The terminal item is a queue job's to write, so it cannot arrive
      # while only the reactor runs. Starting the other host is what closes
      # the stream — and the feed picks it up on its next pass without being
      # told anything.
      #
      # NOT BEFORE THE RUNNER HAS THE TURN, though. Starting jobs on the
      # first pass raced the pinned host for the invocation: whoever
      # admitted first executed it, and the queue host carries no stream
      # sink, so the delta assertion below failed with an empty list on
      # the runs where it won. A delta IS the proof the runner claimed it,
      # so it is the honest gate — and with jobs still down, the runner is
      # the only host that can produce one.
      E2E.hosts.start(:jobs) if seen.any? { _1.type == "text_delta" }
      flunk("the stream never closed; saw #{seen.map(&:type).inspect}") if
        Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep 1
    end

    # IN ORDER, ONCE. The pump's whole job.
    sequences = seen.map(&:sequence)
    assert_equal sequences.sort, sequences, "a follower must see the stream in order"
    assert_equal sequences.uniq, sequences, "and must not be handed the same item twice"
    assert_equal (1..seen.length).to_a, sequences,
      "and must miss nothing — the sequence is contiguous, so a gap would show here"

    deltas = seen.select { _1.type == "text_delta" }
    refute_empty deltas
    assert_equal ANSWER, deltas.map { _1.payload.fetch("text") }.join,
      "what a follower assembles is the answer the caller reads back"
    assert_equal "result", seen.last.type
    assert_equal seen.last.sequence, feed.position.sequence,
      "the position is where the stream ended, which is what a caller would persist"
  end
end
