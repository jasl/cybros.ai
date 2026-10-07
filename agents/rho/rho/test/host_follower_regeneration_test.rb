require "test_helper"

class HostFollowerRegenerationTest < Minitest::Test
  class Transcript
    def initialize
      @items = []
    end

    def append(item) = @items << item

    def each
      until @closed
        item = @items.shift
        item ? yield(item) : Fiber.yield
      end
    end

    def unsubscribe = @closed = true
  end

  class Context
    attr_reader :stream

    def initialize
      @items = []
      @stream = Transcript.new
    end

    def append(type, payload)
      sequence = @items.length + 1
      @items << CybrosAgent::Api::ConversationEvent.new(sequence: sequence, cursor: sequence.to_s,
        public_id: "event-#{sequence}", type: type, payload: payload,
        resource_type: "conversation", resource_public_id: "conversation", occurred_at: "2026-09-20T00:00:00Z")
    end

    def feed(realtime: nil, items: nil, **options)
      CybrosAgent::KernelFeed.new(replay: ->(cursor) {
        CybrosAgent::Api::ConversationEventPage.new(items: @items.drop(cursor.to_i),
          next_after: nil, watermark: @items.length)
      }, **options)
    end

    def transcript(realtime:) = -> { @stream }
    # This fixture polls durable events while driving transcript delivery separately.
    def realtime_opener(_realtime, items: nil) = nil
    def children = CybrosAgent::Api::Page.new(items: [], next_after: nil)
  end

  def setup
    @context = Context.new
    @run = Rho::HostFollower.new(host: Rho::Host::Conversation.new(public_id: "conversation"),
      context: @context, realtime: Object.new, sleeper: ->(_seconds) { Fiber.yield })
    @events = Fiber.new { @run.follow }
    @transcript = Fiber.new { @run.follow_transcript }
  end

  def teardown
    @run.stop
    [@events, @transcript].each { |fiber| fiber.resume if fiber.alive? }
  end

  def test_regeneration_starts_a_fresh_task_and_text_projection_on_the_same_turn
    finish_original
    regenerate

    assert_equal "new-run", @run.snapshot.run_public_id
    assert_equal ["r1"], @run.snapshot.tasks.map(&:task_key)
    assert_empty @run.snapshot.text
    assert_nil @run.snapshot.reasoning
    assert_equal %w[old-run new-run], @run.snapshot.run_public_ids

    delta("new answer", run_id: "new-run")
    assert_equal "new answer", @run.snapshot.text
  end

  def test_regeneration_waits_for_its_own_sealed_body_before_closing_the_reader
    finish_original
    assert @run.transcript_settled?
    regenerate
    refute @run.transcript_settled?

    status("completed", run_id: "new-run")
    assert @run.turn_settled?
    refute @run.transcript_settled?, "the prior candidate's body cannot finish this candidate's stream"

    sealed("new answer", run_id: "new-run", variant: "new-variant")
    assert @run.transcript_settled?
    assert_equal "new answer", @run.snapshot.text
  end

  def test_a_retry_reopens_the_same_runs_transcript_without_losing_its_tasks
    status("running", run_id: "old-run")
    @context.append("task_status", { "task_key" => "r1", "kind" => "model_task", "lifetime" => "conversation", "wake" => "auto", "status" => "failed" })
    @events.resume
    delta("partial answer", run_id: "old-run")
    status("failed", run_id: "old-run", run_status: "needs_attention")
    sealed(nil, run_id: "old-run", variant: "old-variant", status: "failed")
    assert @run.transcript_settled?
    refute @run.turn_settled?

    status("running", run_id: "old-run")
    refute @run.transcript_settled?
    assert_equal ["r1"], @run.snapshot.tasks.map(&:task_key)
    status("completed", run_id: "old-run")
    refute @run.transcript_settled?
    sealed("retry answer", run_id: "old-run", variant: "old-variant")
    assert @run.transcript_settled?
    assert_equal "retry answer", @run.snapshot.text
  end

  def test_an_old_seal_cannot_finish_regeneration_before_the_new_run_is_born
    finish_original(deliver_seal: false)
    begin_regeneration
    @transcript.resume

    assert_nil @run.snapshot.run_public_id
    assert_empty @run.snapshot.text
    refute @run.transcript_settled?

    status("running", run_id: "new-run", variant: "new-variant")
    delta("new answer", run_id: "new-run")
    status("completed", run_id: "new-run")
    refute @run.transcript_settled?
    sealed("new answer", run_id: "new-run", variant: "new-variant")
    assert @run.transcript_settled?
    assert_equal "new answer", @run.snapshot.text
  end

  def test_an_old_seal_cannot_finish_regeneration_after_the_new_run_is_born
    finish_original(deliver_seal: false)
    regenerate
    @transcript.resume

    assert_empty @run.snapshot.text
    refute @run.transcript_settled?
    status("completed", run_id: "new-run")
    assert @run.turn_settled?
    refute @run.transcript_settled?
  end

  def test_loopless_regeneration_rejects_the_old_variants_delayed_seal
    status("running", run_id: nil, variant: "old-variant")
    delta("old answer", run_id: nil, variant: "old-variant")
    status("completed", run_id: nil)
    sealed("old answer", run_id: nil, variant: "old-variant", deliver: false)

    begin_regeneration
    status("running", run_id: nil, variant: "new-variant")
    @transcript.resume
    assert_nil @run.snapshot.run_public_id
    assert_empty @run.snapshot.text
    refute @run.transcript_settled?

    sealed("new answer", run_id: nil, variant: "new-variant")
    assert @run.transcript_settled?
    assert_equal "new answer", @run.snapshot.text
    status("completed", run_id: nil, variant: "new-variant")
    assert @run.turn_settled?
  end

  def test_a_new_seal_can_render_the_previous_candidate_before_the_terminal_event
    finish_original
    regenerate
    delta("canceled candidate", run_id: "new-run")

    sealed("old answer", run_id: "old-run", variant: "old-variant",
      source_run: "new-run", source_variant: "new-variant")

    assert_equal "running", @run.snapshot.status
    assert_equal "new-run", @run.snapshot.run_public_id
    assert_equal "old answer", @run.snapshot.text
    assert @run.transcript_settled?
    refute @run.turn_settled?
    status("completed", run_id: "new-run", run_status: "canceled", variant: "new-variant")
    assert @run.turn_settled?
    assert @run.transcript_settled?
  end

  private

    def finish_original(deliver_seal: true)
      status("running", run_id: "old-run", variant: "old-variant")
      @context.append("task_status", { "task_key" => "r1", "kind" => "model_task", "lifetime" => "conversation", "wake" => "auto", "status" => "completed" })
      @context.append("task_status", { "task_key" => "r1t1", "kind" => "tool_task", "lifetime" => "conversation", "wake" => "auto", "status" => "completed" })
      @events.resume
      delta("old answer", run_id: "old-run")
      delta("old reasoning", run_id: "old-run", type: "reasoning_delta")
      status("completed", run_id: "old-run")
      sealed("old answer", run_id: "old-run", variant: "old-variant", deliver: deliver_seal)
    end

    def begin_regeneration
      @context.append("turn_variant", { "turn_public_id" => "turn", "variant_public_id" => "new-variant", "regenerating" => true })
      @events.resume
    end

    def regenerate
      # Regenerate narrates the reopen, then the backing run's buffered birth.
      @context.append("turn_variant", { "turn_public_id" => "turn", "variant_public_id" => "new-variant", "regenerating" => true })
      @context.append("turn_status", { "turn_public_id" => "turn", "variant_public_id" => "new-variant", "status" => "running" })
      @context.append("task_status", { "task_key" => "r1", "kind" => "model_task", "lifetime" => "conversation", "wake" => "auto", "status" => "waiting" })
      @context.append("turn_status", { "turn_public_id" => "turn", "run_public_id" => "new-run", "run_status" => "running" })
      @context.append("task_status", { "task_key" => "r1", "kind" => "model_task", "lifetime" => "conversation", "wake" => "auto", "status" => "dispatched" })
      @events.resume
    end

    def status(word, run_id:, run_status: word, variant: nil)
      @context.append("turn_status", { "turn_public_id" => "turn", "run_public_id" => run_id,
        "variant_public_id" => variant, "status" => word, "run_status" => run_status })
      @events.resume
    end

    def delta(text, run_id:, type: "text_delta", variant: nil)
      @context.stream.append(CybrosAgent::Api::TranscriptItem.new(type: type, turn_public_id: "turn",
        run_public_id: run_id, task_key: run_id && "r1", variant_public_id: variant, turn: nil, payload: { "text" => text }))
      @transcript.resume
    end

    def sealed(content, run_id:, variant:, status: "completed", source_run: run_id, source_variant: variant, deliver: true)
      candidate = CybrosAgent::Api::ConversationVariant.new(public_id: variant, source: run_id ? "run" : "inference", status: status,
        model: nil, content_preview: content, content: content, active: true, run_public_id: run_id)
      turn = CybrosAgent::Api::ConversationTurn.new(public_id: "turn", position: 1, kind: "direct_reply", role: "assistant",
        status: status, visibility: "visible", inherited: false, sender_conversation_public_id: nil,
        active_variant: candidate, created_at: nil, answering_user_public_id: "answerer")
      @context.stream.append(CybrosAgent::Api::TranscriptItem.new(type: "turn", turn_public_id: "turn", turn: turn,
        run_public_id: source_run, task_key: nil, variant_public_id: source_variant, payload: {}))
      @transcript.resume if deliver
    end
end
