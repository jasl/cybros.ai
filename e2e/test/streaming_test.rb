require "test_helper"
require "cgi/escape"
require "securerandom"
require "async"
require "support/actor_provisioning"
require "support/realtime_lane"

# THE DELTAS, CROSS-PROCESS, FOR FREE.
#
# `conversation_turn_test` proves the settled turn crosses the process
# boundary and deliberately throws every delta away. This lane reads them,
# and it reads them ON EACH HOST IN TURN: `Wake` wakes both execution hosts
# and the start CAS gives neither a tiebreaker, so a journey that let them
# race would be asserting on whichever won. Pinning is how the harness
# already states a composition, and here it is what makes each host's
# narration its own fact rather than a coin toss.
#
# A conversation input cannot be seeded that way — `Inputs::DrainJob`
# applies it and only a queue worker runs jobs — so the seed turn is taken
# with the deployment shape and the assertion rides a REGENERATION, whose
# invocation is created inside the request and so needs no job to exist.
# With the queue host stopped the model runner is the only host that can
# claim it, and the deltas are therefore a fact rather than a flip.
#
# The mock streams SSE with a scriptable per-chunk delay, so "the model is
# still writing" is a state this can actually be in. The provider proof is
# `live_streaming_test` on both weak models; this is the CI proof that the
# kernel's half of the stream still works, and that the SDK accumulator
# joins it back into exactly what was sealed.
class StreamingTest < Minitest::Test
  include E2E::RealtimeLane

  MODEL = "dev/mock-text".freeze
  TURN_TIMEOUT = 60
  POLL = 0.25
  # Nothing terminalizes while the converger is stopped, so the end of the
  # deltas is a silence rather than an item.
  STREAM_IDLE = 5

  def setup
    @base_url = E2E.base_url
    @actor = E2E::ActorProvisioning.world(@base_url).shared_human
    @client = CybrosAgent::Client.new(base_url: @base_url, credential: @actor.member_token)
    E2E.enable_dev_lane!
    E2E.hosts.start
    @workspace = @client.workspaces.create(
      name: "Streaming #{SecureRandom.hex(4)}", idempotency_key: SecureRandom.uuid
    )
    @conversations = @client.workspace(@workspace.public_id).conversations
  end

  # THE DEPLOYMENT SHAPE IS THE JOURNEY'S, and this one narrows it: what
  # follows must inherit both hosts however this lane ended.
  def teardown
    E2E.hosts.start
  end

  def test_the_deltas_arrive_while_the_reply_is_written_and_join_into_the_sealed_body
    chat, turn = settled_seed("!mock stream_chunk_delay=0.02 reply=#{CGI.escape(long_reply)} -- narrate me")

    E2E.hosts.pin(:runner)
    regenerated = nil
    seen = drain_regeneration(chat) do
      regenerated = @conversations.conversation(chat).turns.regenerate(turn, model: MODEL)
    end

    deltas = seen.select { |item| item.fetch("type") == "text_delta" }
    refute_empty deltas, "the reply ran without a single delta reaching a subscriber"
    # NOTHING SETTLED WHILE THEY ARRIVED: the converger is a job and no
    # queue host is running, so every one of these is on screen strictly
    # before the turn seals — which is the property, stated as a fact
    # about the feed rather than as an index comparison against a race.
    assert_empty seen.select { |item| item.fetch("type") == "turn" },
      "a turn settled while the only host that can settle it was stopped"

    # ONE ROUTING KEY for every item on this feed, deltas included: a
    # follower routes by one field whatever the type, and a regeneration's
    # deltas name the NEW sample rather than the one still rendering.
    deltas.each do |delta|
      assert_equal turn, delta.fetch("turn_public_id")
      assert_equal regenerated.variant.public_id, delta.fetch("variant_public_id")
      assert_nil delta["agent_loop_public_id"], "a direct reply carries no loop keys"
    end

    body = settled_variant(chat, turn, regenerated.variant.public_id)

    # THE FIVE LAWS, ASKED THROUGH THE SHIPPED IMPLEMENTATION: joined in
    # arrival order the deltas ARE the sealed body, so the settle has no
    # remainder left to print and replaced nothing.
    accumulator = CybrosAgent::Api::TranscriptAccumulator.new
    deltas.each { |delta| accumulator.accumulate(delta.fetch("text")) }

    assert_equal "", accumulator.replace_on_settle(body),
      "the deltas and the sealed body disagree; #{accumulator.length} bytes streamed, #{body.bytesize} sealed"
    refute_predicate accumulator, :replaced?
    assert_equal body, accumulator.text
  end

  # THE SAME DELTAS, FROM THE OTHER HOST. `sink_for` was the runner's own private method and
  # `RunJob` executed SINK-LESS, so whether a person saw the model write depended on which host won
  # a race nobody chose — and pinned to the queue worker, this lane printed nothing at all while the
  # reply sealed 757 bytes. Both hosts build the same sink now, and this is the twin that says so.
  #
  # The converger is a job, so here it runs: what this asserts is the
  # deltas and their agreement with the sealed body, never the silence its
  # runner-side twin depends on.
  def test_the_queue_host_narrates_the_deltas_the_runner_host_does
    chat, turn = settled_seed("!mock stream_chunk_delay=0.02 reply=#{CGI.escape(long_reply)} -- narrate me")

    E2E.hosts.pin(:jobs)
    regenerated = nil
    seen = drain_regeneration(chat) do
      regenerated = @conversations.conversation(chat).turns.regenerate(turn, model: MODEL)
    end

    deltas = seen.select { |item| item.fetch("type") == "text_delta" }
    refute_empty deltas, "the queue host ran the whole reply and narrated none of it"
    deltas.each do |delta|
      assert_equal turn, delta.fetch("turn_public_id")
      assert_equal regenerated.variant.public_id, delta.fetch("variant_public_id")
      assert_nil delta["agent_loop_public_id"], "a direct reply carries no loop keys"
    end

    body = settled_variant(chat, turn, regenerated.variant.public_id)
    accumulator = CybrosAgent::Api::TranscriptAccumulator.new
    deltas.each { |delta| accumulator.accumulate(delta.fetch("text")) }

    assert_equal "", accumulator.replace_on_settle(body),
      "the deltas and the sealed body disagree; #{accumulator.length} bytes streamed, #{body.bytesize} sealed"
    refute_predicate accumulator, :replaced?
  end

  # The reasoning channel is the only one the mock can be made to produce
  # on demand — a weak model through OpenRouter may emit none — so this is
  # where `reasoning_delta` is pinned at all.
  def test_a_reasoning_delta_rides_the_same_stream_and_never_shares_an_item_with_text
    chat, turn = settled_seed(
      "!mock stream_chunk_delay=0.02 reasoning=#{CGI.escape("weighing it up carefully")} -- narrate me"
    )

    E2E.hosts.pin(:runner)
    seen = drain_regeneration(chat) do
      @conversations.conversation(chat).turns.regenerate(turn, model: MODEL)
    end

    reasoning = seen.select { |item| item.fetch("type") == "reasoning_delta" }
    refute_empty reasoning, "the reasoning half of the stream never arrived"
    assert_equal ["reasoning_text"], reasoning.map { |item| item.fetch("kind") }.uniq
    assert_equal "weighing it up carefully", reasoning.map { |item| item.fetch("text") }.join

    # The coalescer flushes on a KEY SWITCH, so no item ever carries both
    # channels and a follower never has to split one.
    text = seen.select { |item| item.fetch("type") == "text_delta" }
    refute_empty text, "the text half of the stream never arrived"
    text.each { |item| refute item.key?("kind"), "one item carried both channels: #{item.inspect}" }
    assert_equal "Mock: narrate me", text.map { |item| item.fetch("text") }.join
  end

  private

    # The seed, taken with the deployment shape because only a queue worker
    # applies an input. Answers the conversation and the turn a
    # regeneration can be asked for: tail, terminal, and not loop-backed.
    def settled_seed(prompt)
      chat = @conversations.conversation(
        @conversations.create(idempotency_key: SecureRandom.uuid).public_id
      )
      chat.inputs.create(
        kind: "direct_reply", model: MODEL, text: prompt, idempotency_key: SecureRandom.uuid
      )
      turn = await("a reply that settles") do
        last = chat.turns.list.items.last
        last if last&.kind == "direct_reply" && last.status == "completed"
      end
      [chat.public_id, turn.public_id]
    end

    # Subscribed BEFORE the sample is asked for; drained until the stream
    # goes quiet, which is the only end it has while nothing can settle it.
    def drain_regeneration(conversation_public_id)
      seen = nil
      with_reactor do
        subscription = subscribe_to_transcript(conversation_public_id)
        yield if block_given?
        seen = drain_until_quiet(subscription, idle: STREAM_IDLE)
      end
      seen
    end

    # The queue host comes back to converge it, and the sealed body is read
    # through the door rather than off the feed — an independent witness of
    # what the deltas were supposed to add up to.
    def settled_variant(conversation_public_id, turn_public_id, variant_public_id)
      E2E.hosts.start(:jobs)
      chat = @conversations.conversation(conversation_public_id)
      variant = await("the regenerated sample to settle") do
        chat.turns.variants(turn_public_id).items
          .find { |item| item.public_id == variant_public_id && item.status == "completed" }
      end
      variant.content
    end

    # Long enough that the coalescer emits more than one item at a 20 ms
    # chunk delay, so "joined in arrival order" is an assertion about a
    # sequence rather than about one flush.
    def long_reply
      (1..40).map { |index| "sentence #{index} of the answer." }.join(" ")
    end

    def await(what)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + TURN_TIMEOUT
      loop do
        result = yield
        return result if result
        flunk("the deployment never reached #{what}") if
          Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

        sleep POLL
      end
    end
end
