require "test_helper"

class InputExecutionTest < Minitest::Test
  include CybrosAgent::Api::RunProjections

  def setup
    @events = []
    @watermark = 0
    @variants = []
    @materialization = nil
    @run = run_state("running")
    @calls = []
  end

  def event(sequence, type, **payload)
    CybrosAgent::Api::Event.new(public_id: "event-#{sequence}", sequence:, cursor: "c#{sequence}",
      type:, resource_type: "conversation", resource_public_id: "conversation", occurred_at: "2026-10-14T00:00:00Z",
      payload: payload.transform_keys(&:to_s))
  end

  def materialized(sequence = 1, input: "mine", turn: "turn", variant: "original", run_id: "run")
    event(sequence, "input_materialized", input_public_id: input, turn_public_id: turn,
      variant_public_id: variant, run_public_id: run_id)
  end

  def variant(public_id = "original", status: "running", source: "inference", origin: nil, run_id: "run", content: nil, active: false)
    CybrosAgent::Api::Variant.new(public_id:, source:, status:, model: nil, content_preview: nil,
      content:, active:, run_public_id: run_id, origin_variant_public_id: origin)
  end

  def run_state(status, attention: nil, failure_reason: nil)
    shape(CybrosAgent::Api::Run, { "public_id" => "run", "status" => status,
      "attention" => attention, "failure_reason" => failure_reason })
  end

  def identity(variant: "original", run_id: "run")
    CybrosAgent::InputMaterialization::Result.new(turn: "turn", variant:, run_public_id: run_id)
  end

  def readers
    {
      replay: ->(cursor) {
        @calls << [:replay, cursor]
        sequence = cursor ? cursor.delete_prefix("c").to_i : 0
        CybrosAgent::Api::EventPage.new(items: @events.select { |item| item.sequence > sequence },
          next_after: nil, watermark: [@watermark, @events.last&.sequence.to_i].max)
      },
      variants: ->(turn) {
        @calls << [:variants, turn]
        raise @variants_error if @variants_error

        CybrosAgent::Api::VariantDeck.new(items: @variants, turn_public_id: turn, turn_inherited: false)
      },
      run: ->(run) { @calls << [:run, run]; @run },
    }
  end

  def observer(position: CybrosAgent::KernelFeed::Position.start, decisions: nil)
    CybrosAgent::InputExecution.new(input_public_id: "mine", position:, decisions:,
      materialization: ->(input) { @calls << [:materialization, input]; @materialization }, **readers)
  end

  def known(execution: identity, decisions: nil)
    CybrosAgent::InputExecution.for_execution(execution:, decisions:, **readers)
  end

  def test_materialization_remains_lightweight_and_does_not_borrow_another_input
    @events << materialized(input: "another", turn: "other-turn")
    tracking = observer
    assert_same tracking, tracking.refresh
    assert_nil tracking.result
    assert_nil tracking.recover
    assert_nil tracking.snapshot

    @events << materialized(2)
    assert_equal identity, tracking.refresh.result
    assert_equal "c2", tracking.position.cursor
    assert @calls.all? { |kind, _| kind == :replay }
  end

  def test_blocks_and_compaction_are_progress_until_this_input_materializes
    @events = [event(1, "input_blocked", input_public_id: "mine", blocked_reason: "run_held"),
      event(2, "turn_status", turn_public_id: "summary", variant_public_id: "summary-variant",
        run_public_id: "summary-run", turn_kind: "compaction_summary")]
    tracking = observer.refresh
    assert_nil tracking.blocked_reason
    assert_equal "summary", tracking.compaction.turn
    @events << event(3, "input_blocked", input_public_id: "mine", blocked_reason: "unknown_model")
    assert_equal "unknown_model", tracking.refresh.blocked_reason
    @events << materialized(4)
    assert_equal identity, tracking.refresh.result
    assert_nil tracking.blocked_reason
    assert @calls.all? { |kind, _| kind == :replay }
  end

  def test_expired_materialization_uses_the_original_read_without_advancing_an_invented_cursor
    @watermark = 20
    @materialization = CybrosAgent::Api::InputMaterialization.new(input_public_id: "mine",
      turn_public_id: "turn", variant_public_id: "original", run_public_id: "run")
    tracking = observer.refresh
    assert_equal identity, tracking.result
    assert_equal CybrosAgent::KernelFeed::Position.start, tracking.position
    assert_equal [[:replay, nil], [:materialization, "mine"]], @calls
  end

  def test_recovery_follows_only_the_originals_automatic_fallback_and_preserves_the_original_result
    @variants = [variant(status: "failed", run_id: nil),
      variant("fallback-1", source: "fallback", origin: "original", status: "failed", run_id: nil),
      variant("fallback-2", source: "fallback", origin: "fallback-1", status: "completed", run_id: nil, content: "original answer"),
      variant("manual", run_id: nil, active: true, status: "completed", content: "different answer"),
      variant("manual-fallback", source: "fallback", origin: "manual", status: "completed", run_id: nil, content: "also different")]
    @events = [event(1, "turn_status", turn_public_id: "turn", variant_public_id: "original", status: "running")]
    original = identity(run_id: nil)
    tracking = known(execution: original)
    snapshot = tracking.recover
    assert_equal "fallback-2", snapshot.execution.variant
    assert_equal "original answer", snapshot.content
    assert_equal "completed", snapshot.status
    assert_predicate snapshot, :terminal?
    assert_same original, tracking.result
    assert_same snapshot, tracking.snapshot
    refute @calls.any? { |kind, _| kind == :run }
  end

  def test_current_candidate_and_run_win_over_older_retained_status_and_attention
    @variants = [variant(status: "completed", content: "done")]
    @run = run_state("completed")
    @events = [event(1, "turn_status", turn_public_id: "turn", variant_public_id: "original", run_public_id: "run",
      status: "running", run_status: "needs_attention")]
    snapshot = known.recover
    assert_equal "completed", snapshot.status
    assert_equal "completed", snapshot.run_status
    assert_nil snapshot.attention
    assert_predicate snapshot, :terminal?
    refute_predicate snapshot, :needs_attention?
    assert_equal [[:run, "run"]], @calls.select { |kind, _| kind == :run }
  end

  def test_retry_does_not_display_an_old_failure_after_the_current_candidate_resumes
    @variants = [variant(status: "running")]
    @events = [event(1, "turn_status", turn_public_id: "turn", variant_public_id: "original", run_public_id: "run",
      status: "failed", failure_reason: "old failure", failure_reason_key: "old_key")]
    snapshot = known.recover
    assert_equal "running", snapshot.status
    assert_nil snapshot.failure_reason
    assert_nil snapshot.failure_reason_key
    refute_predicate snapshot, :terminal?
  end

  def test_failed_candidate_is_held_until_the_current_run_is_terminal
    @variants = [variant(status: "failed", content: "partial")]
    @run = run_state("needs_attention", attention: { "reason" => "halt_failure", "blocked_task_keys" => ["tool"] },
      failure_reason: "The tool did not complete")
    @events = [event(1, "turn_status", turn_public_id: "turn", variant_public_id: "original", run_public_id: "run",
      status: "failed", failure_reason_key: "tool_uncertain")]
    tracking = known
    held = tracking.recover
    refute_predicate held, :terminal?
    assert_predicate held, :needs_attention?
    assert_equal "halt_failure", held.attention.reason
    assert_equal "tool_uncertain", held.failure_reason_key
    assert_equal "The tool did not complete", held.failure_reason
    assert_equal "partial", held.content

    @run = run_state("canceled")
    assert_predicate tracking.recover, :terminal?
  end

  def test_direct_failure_and_cancellation_are_terminal_without_a_run_read
    %w[failed canceled].each do |status|
      @variants = [variant(status:, run_id: nil)]
      snapshot = known(execution: identity(run_id: nil)).recover
      assert_predicate snapshot, :terminal?
      assert_nil snapshot.run_status
    end
    refute @calls.any? { |kind, _| kind == :run }
  end

  def test_a_timed_out_reply_is_terminal_even_while_its_run_remains_active
    @variants = [variant(status: "timed_out", content: "partial reply")]
    @run = run_state("running")
    snapshot = known.recover
    assert_equal "timed_out", snapshot.status
    assert_equal "running", snapshot.run_status
    assert_equal "partial reply", snapshot.content
    assert_predicate snapshot, :terminal?
  end

  def test_current_run_failure_details_survive_expired_events_and_replace_older_failure_metadata
    @variants = [variant(status: "failed")]
    @run = run_state("needs_attention", failure_reason: "current failure")
      .with(turn: CybrosAgent::Api::RunTurn.new(status: "failed", public_id: "turn", failure_reason_key: "current_key"))
    @events = [event(1, "turn_status", turn_public_id: "turn", variant_public_id: "original", run_public_id: "run",
      status: "failed", failure_reason: "old failure", failure_reason_key: "old_key")]
    tracking = known
    snapshot = tracking.recover
    assert_equal "current failure", snapshot.failure_reason
    assert_equal "current_key", snapshot.failure_reason_key
    @events.clear
    @watermark = 20
    assert_equal "current_key", tracking.recover.failure_reason_key
  end

  def test_retry_can_recover_by_run_when_the_variant_is_not_known
    @variants = [variant(status: "running"), variant("unrelated", active: true, run_id: "other-run", content: "other")]
    snapshot = known(execution: identity(variant: nil)).recover
    assert_equal identity, snapshot.execution
    refute_predicate snapshot, :terminal?
  end

  def test_retained_facts_survive_a_missing_deck_candidate_without_borrowing_active_content
    @variants = [variant("manual", active: true, run_id: "other-run", status: "completed", content: "other")]
    @run = run_state("completed")
    @events = [event(1, "turn_status", turn_public_id: "turn", variant_public_id: "original", run_public_id: "run", status: "completed"),
      event(2, "turn_status", turn_public_id: "turn", variant_public_id: "manual", run_public_id: "other-run", status: "failed"),
      event(3, "turn_status", turn_public_id: "other-turn", variant_public_id: "original", run_public_id: "run", status: "canceled")]
    snapshot = known(execution: identity(variant: nil)).recover
    assert_equal identity, snapshot.execution
    assert_equal "completed", snapshot.status
    assert_nil snapshot.variant
    assert_nil snapshot.content
    assert_predicate snapshot, :terminal?
  end

  def test_legacy_events_without_variant_still_correlate_to_a_known_run
    @run = run_state("needs_attention")
    @events = [event(1, "turn_status", turn_public_id: "turn", run_public_id: "run", status: "failed")]
    snapshot = known(execution: identity(variant: nil)).recover
    assert_equal "failed", snapshot.status
    assert_nil snapshot.execution.variant
    refute_predicate snapshot, :terminal?
  end

  def test_a_missing_candidate_uses_its_own_event_status_beside_a_completed_displayed_turn
    @variants = [variant("manual", active: true, run_id: nil, status: "completed", content: "other")]
    %w[failed canceled].each do |status|
      @events = [event(1, "turn_status", turn_public_id: "turn", variant_public_id: "original",
        status: "completed", variant_status: status, failure_reason_key: "declined")]
      snapshot = known(execution: identity(run_id: nil)).recover
      assert_equal status, snapshot.status
      assert_predicate snapshot, :terminal?
      assert_nil snapshot.content
    end
  end

  def test_each_retained_transition_replaces_candidate_status_but_run_only_notes_do_not
    @events = [event(1, "turn_status", turn_public_id: "turn", variant_public_id: "original", run_public_id: "run",
      status: "completed", variant_status: "failed", failure_reason_key: "old_key"),
      event(2, "turn_status", turn_public_id: "turn", variant_public_id: "original", run_public_id: "run", status: "running"),
      event(3, "turn_status", turn_public_id: "turn", variant_public_id: "original", run_public_id: "run", run_status: "running")]
    tracking = known
    snapshot = tracking.recover
    assert_equal "running", snapshot.status
    assert_nil snapshot.failure_reason_key
    refute_predicate snapshot, :terminal?

    @events << event(4, "turn_status", turn_public_id: "turn", variant_public_id: "original", run_public_id: "run", status: "failed")
    assert_nil tracking.recover.failure_reason_key
    @events << event(5, "turn_status", turn_public_id: "turn", variant_public_id: "original", run_public_id: "run", status: "completed")
    assert_predicate tracking.recover, :terminal?
  end

  def test_missing_retained_execution_never_becomes_the_active_manual_regeneration
    @variants = [variant("manual", active: true, run_id: nil, status: "completed", content: "other")]
    snapshot = known(execution: identity(run_id: nil)).recover
    assert_equal "original", snapshot.execution.variant
    assert_nil snapshot.status
    assert_nil snapshot.content
    refute_predicate snapshot, :terminal?
  end

  def test_unknown_status_words_remain_readable_without_concluding_the_execution_finished
    @variants = [variant(status: "future_variant_state")]
    @run = run_state("future_run_state")
    snapshot = known.recover
    assert_equal "future_variant_state", snapshot.status
    assert_equal "future_run_state", snapshot.run_status
    refute_predicate snapshot, :terminal?
  end

  def test_completed_reply_and_its_runs_background_attention_remain_independent
    @variants = [variant(status: "completed", content: "final reply")]
    @run = run_state("running", attention: { "reason" => "awaiting_human", "blocked_task_keys" => ["background-ask"] })
    snapshot = known.recover
    assert_predicate snapshot, :terminal?
    assert_equal "final reply", snapshot.content
    assert_equal "awaiting_human", snapshot.attention.reason
    assert_equal ["background-ask"], snapshot.attention.blocked_task_keys
  end

  def test_decisions_are_an_explicit_read_and_missing_adapter_support_is_not_an_empty_list
    @variants = [variant]
    @run = run_state("running", attention: { "reason" => "awaiting_human", "blocked_task_keys" => ["ask"] })
    choices = []
    tracking = known(decisions: ->(run) { @calls << [:decisions, run]; choices })
    snapshot = tracking.recover
    assert_equal "awaiting_human", snapshot.attention.reason
    refute_predicate snapshot, :needs_attention?
    refute_predicate snapshot, :terminal?
    refute @calls.any? { |kind, _| kind == :decisions }
    assert_same choices, tracking.decisions
    assert_equal [:decisions, "run"], @calls.last
    error = assert_raises(ArgumentError) { known.decisions }
    assert_match(/decisions callback/, error.message)
    assert_empty known(execution: identity(run_id: nil)).decisions
  end

  def test_recovery_errors_remain_visible_and_do_not_replace_the_last_snapshot
    @variants = [variant(status: "completed", content: "kept")]
    tracking = known
    previous = tracking.recover
    @variants_error = CybrosAgent::TransportError.new("the read failed")
    assert_raises(CybrosAgent::TransportError) { tracking.recover }
    assert_same previous, tracking.snapshot
  end

  def test_construction_requires_an_input_or_an_exact_execution_without_doing_io
    assert_raises(ArgumentError) { CybrosAgent::InputExecution.new(**readers) }
    assert_raises(ArgumentError) { CybrosAgent::InputExecution.new(input_public_id: "mine", execution: identity, **readers) }
    assert_raises(ArgumentError) { CybrosAgent::InputExecution.new(input_public_id: "mine", **readers) }
    assert_raises(ArgumentError) { known(execution: identity(variant: nil, run_id: nil)) }
    assert_raises(ArgumentError) { known(execution: identity.with(turn: nil)) }
    assert_empty @calls
  end
end
