require "test_helper"
require "support/ops_harness"

class HostRunTranscriptRecoveryTest < Minitest::Test
  include RhoTest::OpsHarness

  class Api < NexusDoubles::FakeAgentApi
    attr_accessor :on_variants
    attr_reader :variant_reads

    def initialize(**)
      super
      @variant_reads = 0
    end

    def call(path, **options)
      response = super
      if path.end_with?("/variants")
        @variant_reads += 1
        callback, @on_variants = @on_variants, nil
        callback&.call
      end
      response
    end
  end

  class Socket
    def initialize = @messages = []
    def push(event) = @messages << { "event" => event }

    def each
      until @closed
        message = @messages.shift
        message ? yield(message) : Fiber.yield
      end
    end

    def unsubscribe = @closed = true
  end

  class Realtime
    attr_reader :sockets

    def initialize = @sockets = {}
    def connect_for_feed = nil
    def rebind = true
    def close = @sockets.each_value(&:unsubscribe)

    def subscribe(channel:, params:, timeout:)
      @sockets[params.fetch(:items, "events")] = Socket.new
    end
  end

  def setup
    super
    @events = [status_event(1, "running")]
    @variant = variant("v-1", "completed", "the complete answer", active: true)
    @deck = { "turn" => { "public_id" => "t-1", "inherited" => false }, "variants" => [@variant] }
    @api = Api.new(conversation_events: -> { @events }, variants: @deck)
    context = CybrosAgent::Client.new(base_url: "https://nexus.example",
      credential: NexusDoubles::MEMBER_TOKEN, transport: @api)
      .workspace("ws-1").conversations.conversation("c-1")
    @realtime = Realtime.new
    @fibers = []
    @sleeps = []
    @frames = []
    @run = Rho::HostRun.new(host: Rho::Host::Conversation.new(public_id: "c-1"),
      context: context, realtime: @realtime,
      sleeper: ->(seconds) { @sleeps << seconds; Fiber.yield })
    @run.listen { |frame| @frames << [frame.type, frame.payload] }
    @run.start(->(&block) { @fibers << Fiber.new(&block) })
    tick
    transcript("text_delta", "text" => "the complete ")
  end

  def teardown
    @run.stop
    tick
    super
  end

  def test_caught_up_events_still_recover_the_missing_final_transcript_frame
    terminal
    assert @run.turn_settled?
    refute @run.transcript_settled?
    assert_equal 2, @run.event_position.sequence

    @fibers.last.resume

    assert_equal "the complete answer", @run.snapshot.text
    assert @run.transcript_settled?
    assert_equal ["text_delta", { "text" => "answer" }], @frames.last
    assert_equal 2, @run.event_position.sequence, "text recovery owns no durable event cursor"
    assert_equal 1, @api.variant_reads
    assert_empty @api.turn_windows, "the known turn needs no history scan"
    assert_equal Rho::HostRun::IDLE_POLL_SECONDS, @sleeps.last
    @fibers.last.resume
    assert_equal 1, @api.variant_reads, "a recovered body needs no repeated read"
  end

  def test_a_late_delta_cannot_append_to_the_http_recovered_answer
    terminal
    @fibers.last.resume
    settled_frames = @frames.dup
    transcript("text_delta", "text" => "answer")
    @fibers.last.resume

    assert @run.transcript_settled?
    assert_equal 1, @api.variant_reads
    assert_equal ["the complete answer", settled_frames], [@run.snapshot.text, @frames],
      "late deltas must change neither the sealed snapshot nor its listeners"
  end

  def test_a_late_reset_cannot_clear_the_http_recovered_answer
    terminal
    @fibers.last.resume
    settled_frames = @frames.dup
    transcript("stream_reset", "reason" => "retry")
    @fibers.last.resume

    assert @run.transcript_settled?
    assert_equal 1, @api.variant_reads
    assert_equal ["the complete answer", settled_frames], [@run.snapshot.text, @frames],
      "late resets must change neither the sealed snapshot nor its listeners"
  end

  def test_late_frames_cannot_interrupt_the_replacement_notification
    @variant["content"] = "replacement answer"
    terminal
    interrupted = false
    @run.listen do |frame|
      next unless frame.type == "stream_reset" && !interrupted

      interrupted = true
      replacement_frames = @frames.dup
      refute @run.transcript_settled?, "the replacement body has not been delivered yet"
      transcript("text_delta", "text" => "stale")
      transcript("stream_reset", "reason" => "retry")
      settled_transcript

      assert_equal "replacement answer", @run.snapshot.text
      assert_equal replacement_frames, @frames
      refute @run.transcript_settled?, "a duplicate settle cannot close the reader before the body"
    end
    @fibers.last.resume

    assert interrupted
    assert @run.transcript_settled?
    assert_equal "replacement answer", @run.snapshot.text
    assert_equal [["stream_reset", { "reason" => "replaced" }],
      ["text_delta", { "text" => "replacement answer" }]], @frames.last(2)
  end

  def test_canceled_regeneration_recovers_the_retained_active_answer
    @variant.merge!("status" => "canceled", "active" => false, "content" => nil)
    @deck.fetch("variants") << variant("v-old", "completed", "retained answer", active: true)
    terminal("canceled")
    @fibers.last.resume

    assert_equal "retained answer", @run.snapshot.text
    assert @run.transcript_settled?
    assert_equal ["stream_reset", "text_delta"], @frames.last(2).map(&:first)
  end

  def test_hiding_and_restoring_during_replacement_invalidates_the_earlier_settle
    @variant["content"] = "replacement answer"
    terminal
    interrupted = false
    @run.listen do |frame|
      next unless frame.type == "stream_reset" && !interrupted

      interrupted = true
      %w[hidden visible].each_with_index do |visibility, index|
        event = status_event(index + 3, "completed")
        event["type"] = "visibility"
        event["payload"] = { "turn_public_id" => "t-1", "visibility" => visibility, "inherited" => false }
        deliver(event)
      end
    end
    @fibers.last.resume

    assert interrupted
    assert @run.transcript_settled?
    assert_equal "replacement answer", @run.snapshot.text
    assert_equal 1, @frames.count { |type, payload| type == "text_delta" && payload["text"] == "replacement answer" }
  end

  def test_the_follow_route_delivers_the_recovered_remainder_before_closing
    terminal
    daemon = one_shot_ready(boot)
    daemon.lineage.install_run(daemon.lineage.credentials, @run)
    capturing_spawns(daemon) do |spawned|
      request = query_request("/loops/follow?public_id=c-1", token: bearer(daemon))
      response = route(daemon, "GET", "/loops/follow").call(request)
      initial = drain(response.body)
      assert_includes initial, %("text":"the complete ")
      refute_includes initial, "event: closed"

      @fibers.last.resume
      final = drain(response.body)
      remainder = final.index(%(event: text_delta\ndata: {"text":"answer"}))
      closed = final.index(%(event: closed\ndata: {"reason":"turn_settled"}))
      refute_nil remainder
      refute_nil closed
      assert_operator remainder, :<, closed
      spawned.each(&:call)
    end
  end

  def test_a_received_settle_needs_no_extra_http_read
    settled_transcript
    terminal
    @fibers.last.resume

    assert @run.transcript_settled?
    assert_equal "the complete answer", @run.snapshot.text
    assert_equal 0, @api.variant_reads
  end

  def test_a_live_settle_during_the_body_read_is_not_delivered_twice
    terminal
    @api.on_variants = -> { Fiber.yield }
    @fibers.last.resume
    settled_transcript
    settled_frames = @frames.dup
    @fibers.last.resume

    assert_equal settled_frames, @frames
    assert @run.transcript_settled?
    assert_equal "the complete answer", @run.snapshot.text
  end

  def test_transient_body_read_retries_on_the_existing_active_cadence
    terminal
    @api.on_variants = -> { raise CybrosAgent::Api::ServerError.new("temporarily unavailable") }
    @fibers.last.resume

    refute @run.transcript_settled?
    assert_equal Rho::HostRun::POLL_SECONDS, @sleeps.last
    @fibers.last.resume
    assert @run.transcript_settled?
    assert_equal "the complete answer", @run.snapshot.text
    assert_equal 2, @api.variant_reads
  end

  def test_a_body_read_cannot_replace_a_new_turn_that_started_during_http
    terminal
    @api.on_variants = -> { Fiber.yield }
    @fibers.last.resume
    deliver(status_event(3, "running", turn: "t-2", variant: "v-2", loop_id: "al-2"))
    @fibers.last.resume

    assert_equal "t-2", @run.snapshot.turn
    refute @run.turn_settled?
    refute @run.transcript_settled?
    assert_empty @run.snapshot.text
    assert_equal 1, @api.variant_reads
  end

  def test_a_new_active_selection_is_not_sealed_under_the_previous_candidates_identity
    @variant["active"] = false
    @deck.fetch("variants") << variant("v-new", "completed", "another answer", active: true)
    terminal
    @fibers.last.resume

    refute @run.transcript_settled?
    assert_equal "the complete ", @run.snapshot.text
  end

  def test_stopping_during_the_body_read_discards_the_response
    terminal
    @api.on_variants = -> { Fiber.yield }
    @fibers.last.resume
    @run.stop
    @fibers.last.resume

    refute @run.transcript_settled?
    assert_equal "the complete ", @run.snapshot.text
  end

  def test_a_running_source_candidate_is_not_sealed_with_its_previous_answer
    @variant.merge!("status" => "running", "active" => false)
    @deck.fetch("variants") << variant("v-old", "completed", "old answer", active: true)
    terminal
    @fibers.last.resume

    refute @run.transcript_settled?
    assert_equal "the complete ", @run.snapshot.text
    assert_equal Rho::HostRun::POLL_SECONDS, @sleeps.last
  end

  def test_a_replacement_reset_cannot_seal_a_new_candidate_started_by_its_listener
    @variant["content"] = "replacement answer"
    terminal
    @run.listen do |frame|
      if frame.type == "stream_reset"
        regenerating = status_event(3, "running", variant: "v-2", loop_id: "al-2")
        regenerating["type"] = "turn_variant"
        regenerating.fetch("payload")["regenerating"] = true
        deliver(regenerating)
      end
    end
    @fibers.last.resume

    refute @run.transcript_settled?
    assert_equal "al-2", @run.snapshot.loop
    assert_empty @run.snapshot.text
    refute @frames.any? { |type, payload| type == "text_delta" && payload["text"] == "replacement answer" }
  end

  private

    def tick = @fibers.each { |fiber| fiber.resume if fiber.alive? }

    def drain(body)
      frames = +""
      while body.ready?
        chunk = body.read
        break if chunk.nil?

        frames << chunk
      end
      frames
    end

    def variant(public_id, status, content, active:)
      { "public_id" => public_id, "source" => "model", "status" => status,
        "content" => content, "content_preview" => content, "active" => active }
    end

    def terminal(status = "completed") = deliver(status_event(2, status))

    def deliver(event)
      @events << event
      @realtime.sockets.fetch("events").push(event)
      @fibers.first.resume
    end

    def transcript(type, payload)
      @realtime.sockets.fetch("transcript").push(payload.merge("type" => type,
        "turn_public_id" => "t-1", "variant_public_id" => "v-1", "agent_loop_public_id" => "al-1"))
      @fibers[1].resume
    end

    def settled_transcript
      transcript("turn", "turn" => {
        "public_id" => "t-1", "position" => 1, "kind" => "direct_reply", "role" => "assistant",
        "status" => "completed", "visibility" => "visible", "inherited" => false,
        "answering_user_public_id" => "0199-user", "created_at" => "2026-09-22T00:00:00Z",
        "active_variant" => @variant,
      })
    end

    def status_event(sequence, status, turn: "t-1", variant: "v-1", loop_id: "al-1")
      { "public_id" => "e#{sequence}", "sequence" => sequence, "cursor" => "c#{sequence}",
        "type" => "turn_status", "resource" => { "type" => "conversation", "public_id" => "c-1" },
        "occurred_at" => "2026-09-22T00:00:00Z", "payload" => {
          "turn_public_id" => turn, "variant_public_id" => variant, "agent_loop_public_id" => loop_id,
          "status" => status, "loop_status" => status,
        } }
    end
end
