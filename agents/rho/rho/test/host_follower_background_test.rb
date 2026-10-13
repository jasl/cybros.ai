require "test_helper"

class HostFollowerBackgroundTest < Minitest::Test
  class Context
    def initialize
      @events = []
    end

    def append(type, payload)
      sequence = @events.length + 1
      @events << CybrosAgent::Api::ConversationEvent.new(sequence: sequence, cursor: sequence.to_s,
        public_id: "event-#{sequence}", type: type, payload: payload,
        resource_type: "conversation", resource_public_id: "conversation", occurred_at: "2026-09-20T00:00:00Z")
    end

    def feed(realtime: nil, items: nil, **options)
      CybrosAgent::KernelFeed.new(replay: ->(cursor) {
        CybrosAgent::Api::ConversationEventPage.new(items: @events.drop(cursor.to_i),
          next_after: nil, watermark: @events.length)
      }, **options)
    end

    def children = CybrosAgent::Api::Page.new(items: [], next_after: nil)
  end

  def setup
    @context = Context.new
    @attention = []
    @moves = []
    @received = []
    @run = Rho::HostFollower.new(host: Rho::Host::Conversation.new(public_id: "conversation"),
      context: @context, sleeper: ->(_seconds) { Fiber.yield },
      on_turn: ->(run) { @moves << [run.snapshot.turn, run.snapshot.run_public_id] },
      on_attention: ->(_run, attention, run_id) { @attention << [run_id, attention.reason] })
    @run.listen { |event| @received << event }
    @reader = Fiber.new { @run.follow }
    @old = identity("old-turn", "old-variant", "old-run")
    @current = identity("current-turn", "current-variant", "current-run")
  end

  def teardown
    @run.stop
    @reader.resume if @reader.alive?
  end

  def test_old_background_tasks_cannot_replace_the_current_turns_task_table
    advance_turn
    emit("task_status", @current, task_key: "r1", kind: "model_task", status: "dispatched")
    emit("task_status", @current, task_key: "r1t0", kind: "tool_task", status: "dispatched")
    emit("task_deadline_extended", @current, task_key: "r1t0", timeout_ms: 5_000)

    emit("task_deadline_extended", @old, task_key: "r1t0", timeout_ms: 9_000)
    assert_equal 5_000, @run.snapshot.tasks.last.extension_ms
    emit("task_status", @old, task_key: "r1t0", kind: "tool_task", status: "failed", error_key: "tool_timeout")
    emit("round_result", @old, task_key: "r1", status: "completed")
    emit("task_status", @old, task_key: "r2t0-ask-1", kind: "await_task", status: "dispatched")

    assert_equal [["r1", "model_task", "dispatched", nil], ["r1t0", "tool_task", "dispatched", 5_000]],
      @run.snapshot.tasks.map { |task| [task.task_key, task.kind, task.status, task.extension_ms] }
    assert_nil @run.snapshot.tasks.first.error_key
  end

  def test_old_background_attention_keeps_its_source_without_overwriting_the_current_ask
    advance_turn
    emit("attention_required", @current, reason: "awaiting_human", blocked_task_keys: ["r2t0-ask-1"])
    emit("attention_required", @old, reason: "approval_required", blocked_task_keys: ["r1t0"])

    assert_equal "awaiting_human", @run.snapshot.attention.reason
    assert_equal ["r2t0-ask-1"], @run.snapshot.attention.blocked_task_keys
    assert_equal [["current-run", "awaiting_human"], ["old-run", "approval_required"]], @attention
    assert_equal "old-run", @received.last.payload.fetch("run_public_id"),
      "the conversation's raw event feed still carries its background work"
  end

  def test_a_previous_candidates_background_note_cannot_move_the_current_run
    regenerate
    emit("attention_required", @current, reason: "awaiting_human", blocked_task_keys: ["r2t0-ask-1"])
    moves = @moves.dup
    emit("turn_status", @old, run_status: "completed")

    assert_equal "current-run", @run.snapshot.run_public_id
    assert_equal "running", @run.snapshot.run_status
    assert_equal "awaiting_human", @run.snapshot.attention.reason
    assert_equal moves, @moves
    refute @run.turn_settled?
  end

  def test_candidate_identity_keeps_old_work_out_before_the_new_runs_birth_note
    regenerate(birth: false)
    emit("task_status", @old, task_key: "r1", kind: "model_task", status: "completed")
    emit("turn_status", @old, run_status: "completed")
    emit("attention_required", @old, reason: "halt_failure", blocked_task_keys: ["r1"])

    assert_nil @run.snapshot.run_public_id
    assert_empty @run.snapshot.tasks
    assert_nil @run.snapshot.attention
    assert_equal [["old-run", "halt_failure"]], @attention

    emit("task_status", @current, task_key: "r1", kind: "model_task", status: "waiting")
    assert_equal ["waiting"], @run.snapshot.tasks.map(&:status), "birth tasks precede the run's status note"
    emit("turn_status", @current, run_status: "running")
    assert_equal "current-run", @run.snapshot.run_public_id
  end

  def test_a_loopless_next_reply_stays_clear_of_previous_background_work
    @current = identity("current-turn", "current-variant", nil)
    advance_turn
    emit("task_status", @old, task_key: "r1", kind: "model_task", status: "completed")
    emit("attention_required", @old, reason: "halt_failure", blocked_task_keys: ["r1"])

    assert_nil @run.snapshot.run_public_id
    assert_empty @run.snapshot.tasks
    assert_nil @run.snapshot.attention
    assert_equal [["old-run", "halt_failure"]], @attention
  end

  def test_background_result_mail_survives_after_the_next_turn_starts
    advance_turn
    emit("input_accepted", @old, origin: "task_result", input_public_id: "receipt", task_key: "r1t0")

    assert_equal [{ task_key: "r1t0", run_public_id: "old-run", input_public_id: "receipt", origin: "task_result" }],
      @run.snapshot.delivered_results
    assert_equal "current-run", @run.snapshot.run_public_id
    assert_equal %w[old-run current-run], @run.snapshot.run_public_ids
    assert @run.backs?("old-run")
  end

  private

    def identity(turn, variant, run_id)
      { "turn_public_id" => turn, "variant_public_id" => variant, "run_public_id" => run_id }.compact
    end

    def emit(type, source, **payload)
      @context.append(type, source.merge(payload.transform_keys(&:to_s)))
      @reader.resume
    end

    def advance_turn
      emit("turn_status", @old, status: "running", run_status: "running")
      emit("turn_status", @old, status: "completed", run_status: "running")
      emit("turn_status", @current, status: "running")
      emit("turn_status", @current, run_status: "running") if @current["run_public_id"]
    end

    def regenerate(birth: true)
      @current = identity("old-turn", "current-variant", "current-run")
      emit("turn_status", @old, status: "running", run_status: "running")
      emit("turn_status", @old, status: "completed", run_status: "running")
      emit("turn_variant", @current.except("run_public_id"), regenerating: true)
      emit("turn_status", @current.except("run_public_id"), status: "running")
      emit("turn_status", @current, run_status: "running") if birth
    end
end
