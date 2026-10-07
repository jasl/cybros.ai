require_relative "support/host_follower_harness"

class HostFollowerViewStateTest < Minitest::Test
  include RhoTest::HostFollowerHarness

  class Context < RhoTest::HostFollowerHarness::Context
    attr_accessor :socket, :deck, :read_error, :progress_socket

    def initialize
      super([])
      @events = []
    end

    def append(event) = @events << event
    def transcript(realtime:) = -> { @socket }
    def progress(realtime:) = -> { @progress_socket }
    def turns = self

    def variants(_turn)
      if @read_error
        error, @read_error = @read_error, nil
        raise error
      end
      @deck
    end

    def feed(realtime: nil, items: nil, **options)
      CybrosAgent::KernelFeed.new(replay: ->(cursor) {
        CybrosAgent::Api::ConversationEventPage.new(items: @events.drop(cursor.to_i),
          next_after: nil, watermark: @events.length)
      }, **options)
    end
  end

  def setup
    @context = Context.new
    @context.deck = CybrosAgent::Api::ConversationVariantDeck.new(
      items: [settled_turn_item("the removed answer").turn.active_variant],
      turn_public_id: "t-1", turn_inherited: false)
    @moves = []
    @run = Rho::HostFollower.new(host: CONVERSATION, context: @context, realtime: Realtime.new,
      sleeper: ->(_) { Fiber.yield }, on_turn: ->(run) { @moves << [run.snapshot.turn, run.snapshot.run_public_id] })
    @reader = Fiber.new { @run.follow }
    emit("turn_status", turn_public_id: "t-1", variant_public_id: "v-1", run_public_id: "al-1",
      status: "completed", run_status: "completed")
    @context.socket = Socket.new([settled_turn_item("the removed answer")], ending: StopIteration)
    assert_raises(StopIteration) { @run.follow_transcript }
    assert_equal "the removed answer", @run.snapshot.text
  end

  def teardown
    @run.stop
    @reader.resume if @reader.alive?
  end

  def test_undo_removes_the_deleted_tail_from_the_followers_next_snapshot_without_ending_the_host
    emit("turn_deleted", turn_public_id: "t-1", position: 1)

    assert_empty @run.snapshot.text
    assert_nil @run.snapshot.turn
    assert_nil @run.snapshot.run_public_id
    assert_equal [nil, nil], @moves.last, "the host store must stop pointing at the deleted turn and run"
    assert_follow_continues
  end

  def test_hiding_the_current_turn_removes_its_body_from_new_readers
    emit("visibility", turn_public_id: "t-1", visibility: "hidden", inherited: false)

    assert_empty @run.snapshot.text
    assert_follow_continues
  end

  def test_concealing_a_pinned_current_turn_removes_its_body_from_new_readers
    emit("soft_delete", turn_public_id: "t-1", concealed: true, inherited: false)

    assert_empty @run.snapshot.text
    assert_follow_continues
  end

  def test_exclusion_from_model_context_keeps_the_visible_answer
    emit("visibility", turn_public_id: "t-1", visibility: "excluded_from_context", inherited: false)

    assert_equal "the removed answer", @run.snapshot.text
    assert_follow_continues
  end

  def test_visibility_and_concealment_restore_the_body_only_when_both_allow_it
    emit("visibility", turn_public_id: "t-1", visibility: "hidden", inherited: false)
    emit("soft_delete", turn_public_id: "t-1", concealed: true, inherited: false)
    emit("visibility", turn_public_id: "t-1", visibility: "visible", inherited: false)

    assert_empty @run.snapshot.text, "restoring visibility does not undo concealment"
    assert_equal "t-1", @run.snapshot.turn
    assert_equal "al-1", @run.snapshot.run_public_id

    emit("soft_delete", turn_public_id: "t-1", concealed: false, inherited: false)
    assert_equal "the removed answer", @run.snapshot.text
    assert @run.transcript_settled?
  end

  def test_hiding_a_live_turn_preserves_its_execution_identity_but_rejects_a_late_seal
    emit("turn_status", turn_public_id: "t-1", variant_public_id: "v-1", run_public_id: "al-1",
      status: "running", run_status: "running")
    emit("visibility", turn_public_id: "t-1", visibility: "hidden", inherited: false)
    deliver(settled_turn_item("the removed answer"))
    emit("attention_required", turn_public_id: "t-1", variant_public_id: "v-1", run_public_id: "al-1",
      reason: "approval_required", blocked_task_keys: ["tool"])

    assert_empty @run.snapshot.text
    assert_equal "t-1", @run.snapshot.turn
    assert_equal "al-1", @run.snapshot.run_public_id
    assert_equal ["tool"], @run.snapshot.attention.blocked_task_keys
    refute @run.turn_settled?
  end

  def test_an_undone_turn_cannot_return_through_a_late_state_note_or_transcript_frame
    emit("turn_deleted", turn_public_id: "t-1", position: 1)
    emit("turn_status", turn_public_id: "t-1", variant_public_id: "v-1", run_public_id: "al-1",
      run_status: "completed")
    emit("task_status", turn_public_id: "t-1", variant_public_id: "v-1", run_public_id: "al-1",
      task_key: "r1", kind: "model_task", status: "completed")
    deliver(settled_turn_item("the removed answer"))

    assert_empty @run.snapshot.text
    assert_empty @run.snapshot.tasks
    assert_nil @run.snapshot.turn
    assert_nil @run.snapshot.run_public_id
    assert @reader.alive?
  end

  def test_a_restore_read_failure_keeps_the_previous_view_and_cursor_for_retry
    emit("visibility", turn_public_id: "t-1", visibility: "hidden", inherited: false)
    @context.read_error = CybrosAgent::TransportError.new("brief outage")
    emit("visibility", turn_public_id: "t-1", visibility: "visible", inherited: false)

    assert_equal 2, @run.event_position.sequence
    assert_empty @run.snapshot.text
    deliver(settled_turn_item("late hidden seal"))
    assert_empty @run.snapshot.text

    @reader.resume
    assert_equal 3, @run.event_position.sequence
    assert_equal "the removed answer", @run.snapshot.text
  end

  def test_a_later_deleted_turn_does_not_end_the_host_while_replaying_its_restore
    emit("soft_delete", turn_public_id: "t-1", concealed: true, inherited: false)
    @context.read_error = CybrosAgent::Api::NotFound.new("gone", code: "turn_not_found")
    emit("soft_delete", turn_public_id: "t-1", concealed: false, inherited: false)

    assert_equal 3, @run.event_position.sequence
    assert_empty @run.snapshot.text
    assert @reader.alive?
  end

  def test_activating_a_candidate_keeps_the_current_turn_hidden_until_restored
    emit("visibility", turn_public_id: "t-1", visibility: "hidden", inherited: false)
    emit("turn_variant", turn_public_id: "t-1", variant_public_id: "v-1", activated: true)

    assert_empty @run.snapshot.text
    emit("visibility", turn_public_id: "t-1", visibility: "visible", inherited: false)
    assert_equal "the removed answer", @run.snapshot.text
  end

  def test_restoring_a_running_turn_does_not_treat_the_previous_answer_as_its_seal
    emit("turn_variant", turn_public_id: "t-1", variant_public_id: "v-2", regenerating: true)
    emit("turn_status", turn_public_id: "t-1", variant_public_id: "v-2", run_public_id: "al-2",
      status: "running", run_status: "running")
    original = @context.deck.active
    @context.deck = @context.deck.with(items: [original,
      original.with(public_id: "v-2", status: "running", active: false, content: nil, run_public_id: "al-2")])
    emit("visibility", turn_public_id: "t-1", visibility: "hidden", inherited: false)
    emit("visibility", turn_public_id: "t-1", visibility: "visible", inherited: false)

    assert_empty @run.snapshot.text
    refute @run.transcript_settled?
  end

  def test_restore_recovers_a_completed_candidate_when_its_seal_arrived_before_the_visibility_event
    emit("turn_status", turn_public_id: "t-1", variant_public_id: "v-1", run_public_id: "al-1",
      status: "running", run_status: "running")
    emit("visibility", turn_public_id: "t-1", visibility: "hidden", inherited: false)
    @context.deck = @context.deck.with(items: [@context.deck.active.with(content: "finished while restoring")])
    deliver(settled_turn_item("finished while restoring"))
    assert_empty @run.snapshot.text, "the local view has not observed the visibility event yet"

    emit("visibility", turn_public_id: "t-1", visibility: "visible", inherited: false)
    emit("turn_status", turn_public_id: "t-1", variant_public_id: "v-1", run_public_id: "al-1",
      status: "completed", run_status: "completed")

    assert_equal "finished while restoring", @run.snapshot.text
    assert @run.transcript_settled?
  end

  def test_restore_recovers_a_canceled_regenerations_fallback_before_its_terminal_event
    assert_fallback_restored(source_present: true)
  end

  def test_restore_recovers_the_fallback_when_the_finished_source_candidate_was_concealed
    assert_fallback_restored(source_present: false)
  end

  def test_hiding_clears_only_that_turns_progress_and_rejects_its_late_frames
    emit("turn_status", turn_public_id: "t-2", variant_public_id: "v-2", run_public_id: "al-2",
      status: "running", run_status: "running")
    progress(progress_frame("t-1", "al-1", "background"), progress_frame("t-2", "al-2", "hide this"))
    assert_equal 2, @run.snapshot.frames.length
    emit("visibility", turn_public_id: "t-2", visibility: "hidden", inherited: false)
    progress(progress_frame("t-2", "al-2", "late hidden output"), progress_frame("t-1", "al-1", "still background"))

    assert_equal ["background", "still background"], @run.snapshot.frames.map { |frame| frame.dig("payload", "text_tail") }
  end

  def test_undo_does_not_silence_a_previous_turns_live_background_progress
    emit("turn_status", turn_public_id: "t-2", variant_public_id: "v-2", run_public_id: "al-2",
      status: "completed", run_status: "completed")
    progress(progress_frame("t-1", "al-1", "background"), progress_frame("t-2", "al-2", "delete this"))
    emit("turn_deleted", turn_public_id: "t-2", position: 2)
    progress(progress_frame("t-2", "al-2", "late deleted output"), progress_frame("t-1", "al-1", "still background"))

    assert_equal ["background", "still background"], @run.snapshot.frames.map { |frame| frame.dig("payload", "text_tail") }
    assert_nil @run.snapshot.turn
  end

  def test_a_delayed_restore_does_not_seal_a_candidate_that_the_server_is_still_running
    emit("visibility", turn_public_id: "t-1", visibility: "hidden", inherited: false)
    @context.deck = @context.deck.with(items: [@context.deck.active.with(status: "running", content: nil)])
    emit("visibility", turn_public_id: "t-1", visibility: "visible", inherited: false)
    refute @run.transcript_settled?, "the restore read must not reuse the old candidate's seal"
    emit("turn_status", turn_public_id: "t-1", variant_public_id: "v-1", run_public_id: "al-1",
      status: "running", run_status: "running")

    assert_empty @run.snapshot.text
    refute @run.transcript_settled?
  end

  private

    def assert_fallback_restored(source_present:)
      emit("turn_variant", turn_public_id: "t-1", variant_public_id: "v-2", regenerating: true)
      emit("turn_status", turn_public_id: "t-1", variant_public_id: "v-2", run_public_id: "al-2",
        status: "running", run_status: "running")
      emit("visibility", turn_public_id: "t-1", visibility: "hidden", inherited: false)
      if source_present
        original = @context.deck.active
        @context.deck = @context.deck.with(items: [original,
          original.with(public_id: "v-2", status: "canceled", active: false, content: nil, run_public_id: "al-2")])
      end
      deliver(transcript_item("turn", turn: "t-1", variant: "v-2", run_id: "al-2",
        turn_row: settled_turn_item("the removed answer").turn))
      assert_empty @run.snapshot.text

      emit("visibility", turn_public_id: "t-1", visibility: "visible", inherited: false)
      emit("turn_status", turn_public_id: "t-1", variant_public_id: "v-2", run_public_id: "al-2",
        status: "completed", run_status: "canceled")

      assert_equal "the removed answer", @run.snapshot.text
      assert @run.transcript_settled?
    end

    def emit(type, **payload)
      @sequence = @sequence.to_i + 1
      @context.append(CybrosAgent::Api::ConversationEvent.new(sequence: @sequence, cursor: @sequence.to_s,
        public_id: "event-#{@sequence}", type: type, payload: payload.transform_keys(&:to_s),
        resource_type: "conversation", resource_public_id: CONVERSATION.public_id,
        occurred_at: "2026-09-20T00:00:00Z"))
      @reader.resume
    end

    def deliver(item)
      @context.socket = Socket.new([item], ending: StopIteration)
      assert_raises(StopIteration) { @run.follow_transcript }
    end

    def progress(*frames)
      @context.progress_socket = Socket.new(frames, ending: StopIteration)
      assert_raises(StopIteration) { @run.follow_progress }
    end

    def progress_frame(turn, run_id, text)
      CybrosAgent::Api::ProgressFrame.new(type: "executor_progress", run_public_id: run_id,
        conversation_public_id: CONVERSATION.public_id, task_key: "r1t0", tool_name: "bash",
        process_id: nil, executor_public_id: "ex-1", at: "2026-09-20T00:00:00Z",
        payload: { "turn_public_id" => turn, "text_tail" => text })
    end

    def assert_follow_continues
      assert_equal 2, @run.event_position.sequence
      assert @reader.alive?, "a view-state change is not the end of the conversation"
      emit("turn_status", turn_public_id: "t-2", variant_public_id: "v-2", run_public_id: "al-2",
        status: "running", run_status: "running")
      assert_equal "t-2", @run.snapshot.turn
      assert_equal "running", @run.snapshot.status
      deliver(settled_turn_item("the next answer", turn: "t-2"))
      assert_equal "the next answer", @run.snapshot.text
    end
end
