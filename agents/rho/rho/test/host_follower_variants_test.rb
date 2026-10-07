require_relative "support/host_follower_harness"

class HostFollowerVariantsTest < Minitest::Test
  include RhoTest::HostFollowerHarness

  class Context < RhoTest::HostFollowerHarness::Context
    attr_accessor :deck, :read_error, :socket

    def initialize
      super([])
      @events = []
    end

    def append(event) = @events << event
    def turns = self
    def transcript(realtime:) = -> { @socket }

    def variants(_turn)
      if @read_error
        error, @read_error = @read_error, nil
        raise error
      end
      @deck
    end

    def feed(realtime: nil, items: nil, **options)
      CybrosAgent::KernelFeed.new(replay: ->(cursor) {
        RhoTest::HostFollowerHarness::Page.new(items: @events.drop(cursor.to_s.delete_prefix("c").to_i),
          next_after: nil, watermark: @events.length)
      }, **options)
    end
  end

  def setup
    @context = Context.new
    @run_reads = []
    @turn_moves = []
    @run = Rho::HostFollower.new(host: CONVERSATION, context: @context, realtime: Realtime.new,
      sleeper: ->(_) { Fiber.yield }, on_turn: ->(run) { @turn_moves << run.snapshot.run_public_id },
      run_context: ->(id) {
        @run_reads << id
        CybrosAgent::Api::RunContext.new(workspace_public_id: "workspace", run_public_id: id,
          dispatch: ->(_) { { "run" => @run_document } })
      })
    @events = Fiber.new { @run.follow }
    append("turn_status", turn_public_id: "t-1", variant_public_id: "v-old", run_public_id: "old-run",
      status: "failed", run_status: "needs_attention", failure_reason_key: "halt_failure")
    append("task_status", task_key: "r1", kind: "model_task", status: "failed")
    append("attention_required", reason: "halt_failure", blocked_task_keys: ["r1"])
    @events.resume
  end

  def teardown
    @run.stop
    @events.resume if @events.alive?
  end

  def test_manual_edit_clears_the_old_execution_and_recovers_the_sealed_body_without_a_stream
    select("v-edit", content: "manual answer")
    @events.resume

    snapshot = @run.snapshot
    assert_nil snapshot.run_public_id
    assert_nil snapshot.run_status
    assert_nil snapshot.attention
    assert_empty snapshot.tasks
    assert_equal "manual answer", snapshot.text
    assert_equal "completed", snapshot.status
    assert snapshot.complete
    assert_nil snapshot.failure_reason_key
    assert_equal ["old-run", nil], @turn_moves
    assert_empty @run_reads

    append("task_status", turn_public_id: "t-1", variant_public_id: "v-old", run_public_id: "old-run",
      task_key: "r1", kind: "model_task", status: "completed")
    @events.resume
    assert_empty @run.snapshot.tasks
  end

  def test_activation_restores_the_selected_runs_current_tasks_and_attention
    @run_document = {
      "public_id" => "selected-run", "status" => "running",
      "tasks" => [
        { "key" => "r1", "kind" => "model_task", "lifetime" => "conversation", "wake" => "auto", "status" => "completed" },
        { "key" => "question", "kind" => "await_task", "lifetime" => "conversation", "wake" => "auto", "status" => "awaiting_input", "after" => ["r1"] },
      ],
      "attention" => { "reason" => "awaiting_human", "blocked_task_keys" => ["question"] },
    }
    select("v-selected", content: "earlier answer", run_id: "selected-run")
    @events.resume

    snapshot = @run.snapshot
    assert_equal "selected-run", snapshot.run_public_id
    assert_equal "running", snapshot.run_status
    assert_equal "completed", snapshot.status
    assert_equal "earlier answer", snapshot.text
    assert_equal %w[r1 question], snapshot.tasks.map(&:task_key)
    assert_equal ["r1"], snapshot.tasks.last.after
    assert_equal "awaiting_input", snapshot.tasks.last.status
    assert_equal ["question"], snapshot.attention.blocked_task_keys
    assert_equal ["selected-run"], @run_reads
    assert_equal %w[old-run selected-run], snapshot.run_public_ids
    assert_equal %w[old-run selected-run], @turn_moves
  end

  def test_a_transient_selection_read_keeps_the_event_uncommitted_for_the_existing_feed_to_retry
    select("v-edit", content: "manual answer")
    @context.read_error = CybrosAgent::TransportError.new("brief outage")
    @events.resume

    assert_equal 3, @run.event_position.sequence
    assert_equal "failed", @run.snapshot.status
    assert_equal "old-run", @run.snapshot.run_public_id
    @events.resume
    assert_equal 4, @run.event_position.sequence
    assert_equal "manual answer", @run.snapshot.text
  end

  def test_a_deleted_historical_turn_does_not_end_the_host_during_replay
    select("v-deleted", content: "deleted answer")
    @context.read_error = CybrosAgent::Api::NotFound.new("gone", code: "turn_not_found")
    append("turn_status", turn_public_id: "t-2", variant_public_id: "v-next", status: "running")
    @events.resume

    assert_equal 5, @run.event_position.sequence
    assert_equal "t-2", @run.snapshot.turn
    assert_equal "running", @run.snapshot.status
    assert @events.alive?
  end

  def test_selection_recovers_a_seal_that_arrived_before_its_durable_event
    select("v-edit", content: "manual answer")
    deliver(transcript_item("turn", turn: "t-1", variant: "v-edit",
      turn_row: settled_turn_item("manual answer").turn))
    assert_empty @run.snapshot.text
    refute @run.transcript_settled?

    @events.resume
    assert_equal "manual answer", @run.snapshot.text
    assert @run.transcript_settled?
  end

  def test_selection_tells_a_stream_reader_to_replace_the_previous_answer
    deliver(transcript_item("text_delta", turn: "t-1", variant: "v-old", run_id: "old-run", text: "partial answer"))
    frames = []
    @run.listen { |frame| frames << [frame.type, frame.payload] }
    select("v-edit", content: "manual answer")
    @events.resume

    assert_equal ["stream_reset", { "reason" => "replaced" }], frames[0]
    assert_equal ["text_delta", { "text" => "manual answer" }], frames[1]
    assert_equal "manual answer", @run.snapshot.text
  end

  private

    def deliver(*items)
      @context.socket = Socket.new(items, ending: StopIteration)
      assert_raises(StopIteration) { @run.follow_transcript }
    end

    def append(type, **payload)
      @sequence = @sequence.to_i + 1
      @context.append(event(@sequence, type, payload.transform_keys(&:to_s)))
    end

    def select(id, content:, run_id: nil)
      variant = CybrosAgent::Api::ConversationVariant.new(public_id: id, source: run_id ? "run" : "edit",
        status: "completed", model: nil, content_preview: content, content: content, active: true,
        run_public_id: run_id)
      @context.deck = CybrosAgent::Api::ConversationVariantDeck.new(items: [variant], turn_public_id: "t-1", turn_inherited: false)
      append("turn_variant", turn_public_id: "t-1", variant_public_id: id, run_public_id: run_id, activated: true)
    end
end
