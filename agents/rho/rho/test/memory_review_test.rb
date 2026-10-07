require "test_helper"
require_relative "support/memory_review_fixtures"

class MemoryReviewTest < Minitest::Test
  Fixtures = RhoTest::MemoryReviewFixtures
  PATH = "user/review.md".freeze

  def setup
    @now = Time.utc(2026, 10, 7, 1)
    @workspace = Fixtures::Workspace.new
    @conversation = @workspace.conversation_row
    @memory = @conversation.memory
    @followed, @forgotten = [], []
  end

  def test_review_is_opt_in_and_enable_starts_after_existing_work
    old = source(position: 7)
    review.settled(settlement(old))
    assert_empty @workspace.forks
    assert_empty @memory.rows

    result = review.enable(path: PATH, model: "test/reviewer")
    assert result.fetch("enabled")
    assert_equal PATH, result.fetch("path")
    assert_equal "test/reviewer", result.fetch("model")
    review.settled(settlement(old))
    assert_empty @workspace.forks

    fresh = source(position: 8)
    review.settled(settlement(fresh))
    assert_equal "test/reviewer", input.fetch("model")
    assert_equal fresh.active_variant.prompt_text, input.fetch("prompt")
    assert_equal 2, @workspace.rows.length
  end

  def test_formal_result_places_one_raw_model_input_in_a_dedicated_side
    enable
    turn = source
    review.settled(settlement(turn))
    review.settled(settlement(turn))

    assert_equal 1, @workspace.forks.length
    assert_equal({ side: true, title: "Memory review", idempotency_key: review.state.pending.idempotency_key }, @workspace.forks.first)
    fields = side.inputs.creates.fetch(0)
    assert_equal "raw", fields.fetch(:context_mode)
    assert_empty fields.fetch(:tool_names)
    assert_equal({ "max_output_tokens" => 2048 }, fields.fetch(:configuration))
    assert_equal Rho::MemoryReview::Review::INSTRUCTIONS, fields.fetch(:instructions)
    assert_equal JSON.parse(Rho::MemoryReview::Review.prompt(input)), JSON.parse(fields.fetch(:entries).first.fetch("parts").first.fetch("text"))
    assert_equal ["side-1"], @followed.uniq
    assert review.status.fetch("pending"), "the kernel input owns unfinished model work"
    assert_nil review.status.fetch("outcome")
  end

  def test_unknown_fork_response_replays_the_persisted_key_and_never_creates_a_second_side
    enable
    turn = source
    @workspace.lose_fork = true
    assert_raises(CybrosAgent::TransportError) { review.settled(settlement(turn)) }
    pending = review.state.pending
    assert_nil pending.review_conversation_public_id

    review.resume
    assert_equal 2, @workspace.rows.length
    assert_equal 2, @workspace.forks.length
    assert_equal @workspace.forks.first, @workspace.forks.last
    assert_equal pending.idempotency_key, review.state.pending.idempotency_key
    assert_equal 1, side.inputs.creates.length
  end

  def test_unknown_input_response_replays_the_same_key_and_exact_body
    enable
    @workspace.lose_input = true
    assert_raises(CybrosAgent::TransportError) { review.settled(settlement(source)) }
    assert_nil review.state.pending.input_public_id
    submitted = side.inputs.creates.first

    review.resume
    assert_equal 1, @workspace.forks.length
    assert_equal 1, side.inputs.records.length
    assert_equal [submitted, submitted], side.inputs.creates
    assert_equal "input-1", review.state.pending.input_public_id
  end

  def test_pending_recovery_must_succeed_before_a_later_source_can_replace_any_state
    enable
    first = source
    @workspace.lose_fork = true
    assert_raises(CybrosAgent::TransportError) { review.settled(settlement(first)) }
    pending = review.state.pending
    second = source(position: 2)
    @workspace.lose_fork = true
    assert_raises(CybrosAgent::TransportError) { review.settled(settlement(second)) }
    assert_equal pending, review.state.pending
    assert_equal first.position, review.state.after_position

    review.settled(settlement(second))
    assert_equal 2, review.state.after_position
    assert_equal first.public_id, input.fetch("turn_public_id")
    assert_equal 2, @workspace.rows.length
    finish_review
    review.settled(settlement(second))
    assert_equal 2, @workspace.rows.length, "busy sources were consumed, never replayed"
    review.settled(settlement(source(position: 3)))
    assert_equal 3, @workspace.rows.length
  end

  def test_explicit_resume_recovers_a_settled_input_without_reissuing_model_work
    prepare_review
    side.settle(content: proposal)
    result = review.resume

    assert_equal "updated", result.fetch("outcome")
    assert_equal "side-1-run", result.fetch("run_public_id")
    refute result.fetch("pending")
    review.resume
    assert_equal 1, side.inputs.creates.length
    assert_equal ["side-1"], @forgotten
  end

  def test_read_only_or_absent_roots_skills_and_sides_cannot_be_review_destinations
    @conversation.memory_context = { "bindings" => [{ "name" => "user", "access" => "read" }] }
    assert_raises(Rho::Error) { enable }
    assert_empty @memory.rows
    @conversation.memory_context = { "bindings" => [] }
    assert_raises(Rho::Error) { enable }
    @conversation.memory_context = nil
    assert_raises(Rho::Error) { enable(path: "user/skills/example") }
    assert_empty @memory.rows
    prepare_review
    assert_raises(Rho::Error) { Rho::MemoryReview.new(workspace: @workspace, conversation_public_id: side.public_id).enable(path: PATH) }
  end

  def test_expired_ambiguous_acceptance_never_reuses_an_expired_create_key
    enable
    @workspace.lose_fork = true
    assert_raises(CybrosAgent::TransportError) { review.settled(settlement(source)) }
    @now += Rho::MemoryReview::SUBMISSION_SECONDS

    result = review.resume
    assert_equal 1, @workspace.forks.length
    assert_equal "skipped", result.fetch("outcome")
    refute result.fetch("pending")
  end

  def test_deleted_document_is_not_recreated_until_explicit_initialization
    enable
    first = source
    review.settled(settlement(first))
    previous_id = @memory.rows.fetch(PATH).public_id
    @memory.rows.delete(PATH)
    review.settled(settlement(source(position: 2)))
    assert_empty @memory.rows
    assert_equal 1, @workspace.forks.length
    assert_equal "skipped", review.status.fetch("outcome")
    refute review.status.fetch("pending")
    assert_equal 1, side.cancellations

    enable
    refute_equal previous_id, @memory.rows.fetch(PATH).public_id
    review.settled(settlement(source(position: 3)))
    assert_equal 2, @workspace.forks.length
  end

  def test_recreated_same_path_does_not_satisfy_the_enabled_document_identity
    enable
    @memory.rows.delete(PATH)
    @memory.write(PATH, "A new document", expected_public_id: nil, expected_lock_version: nil)
    review.settled(settlement(source))

    assert_empty @workspace.forks
    assert_equal "A new document", @memory.rows.fetch(PATH).content
  end

  def test_an_oversized_existing_document_is_preserved_without_placing_review_work
    enable
    content = "A" * (Rho::MemoryReview::DOCUMENT_BYTES + 1)
    @memory.correct(PATH, content)
    turn = source
    review.settled(settlement(turn))

    assert_empty @workspace.forks
    assert_equal content, @memory.rows.fetch(PATH).content
    assert_equal turn.position, review.state.after_position
    assert_equal 1, @memory.writes.length
  end

  def test_newer_correction_before_completion_wins_over_both_notes_and_index
    prepare_review
    @memory.correct(PATH, "Correct preference: green")
    finish_review(content: JSON.generate(content: "Old preference: blue", summary: "Learned the old preference"))

    assert_equal "skipped", review.status.fetch("outcome")
    assert_equal "Correct preference: green", @memory.rows.fetch(PATH).content
    assert_equal 1, @memory.writes.length
  end

  def test_cas_refuses_a_correction_between_the_final_read_and_write
    prepare_review
    @memory.before_write = -> { @memory.correct(PATH, "Corrected at the write boundary") }
    finish_review

    assert_equal "skipped", review.status.fetch("outcome")
    assert_equal "Corrected at the write boundary", @memory.rows.fetch(PATH).content
    assert_equal 1, side.inputs.creates.length
  end

  def test_forgetting_during_review_or_after_success_never_replays_old_source
    turn = prepare_review
    @memory.rows.delete(PATH)
    finish_review(content: JSON.generate(content: "Private fact", summary: "A past answer"))
    review.settled(settlement(turn))
    assert_empty @memory.rows
    assert_equal 1, @workspace.forks.length

    enable
    fresh = source(position: 2, prompt: "An unrelated new request", answer: "Only the new result")
    review.settled(settlement(fresh))
    assert_equal "An unrelated new request", input.fetch("prompt")
    refute_includes input.fetch("answer"), "Private fact"
  end

  def test_changed_memory_bindings_skip_the_old_source_and_keep_the_group_destination
    group = { "bindings" => [{ "name" => "group", "scope" => "conversation", "access" => "read_write",
      "conversation_public_id" => "shared-room" }] }
    @conversation.memory_context = group
    enable(path: "group/review.md")
    review.settled(settlement(source(memory_context: group)))
    assert_equal "group/review.md", input.fetch("path")
    assert_equal group, input.fetch("memory_context")
    assert_equal ["group/review.md"], @memory.reads.uniq

    @conversation.memory_context = { "bindings" => [] }
    finish_review
    assert_equal "skipped", review.status.fetch("outcome")
    assert_equal 1, @memory.writes.length
  end

  def test_bindings_changed_before_selection_do_not_read_a_different_scope
    enable
    turn = source
    @conversation.memory_context = { "bindings" => [] }
    reads = @memory.reads.length
    review.settled(settlement(turn))

    assert_empty @workspace.forks
    assert_equal reads, @memory.reads.length
  end

  def test_expired_review_cancels_its_side_and_never_applies_the_old_answer
    prepare_review
    @now += Rho::MemoryReview::SUBMISSION_SECONDS
    finish_review

    assert_equal "skipped", review.status.fetch("outcome")
    assert_equal 1, side.cancellations
    assert_equal Rho::MemoryReview::INITIAL_CONTENT, @memory.rows.fetch(PATH).content
  end

  def test_review_updates_one_document_with_inspectable_dated_source_pointers
    prepare_review
    finish_review
    content = @memory.rows.fetch(PATH).content
    assert_equal "updated", review.status.fetch("outcome")
    assert_includes content, "Use concise replies."
    assert_includes content, "Past work (2026-10-07T00:00:00Z): Completed the migration tests."
    assert_includes content, "conversation conversation-1; turn turn-1; run source-1"
    assert_equal "side-1", review.status.fetch("review_conversation_public_id")
    assert_equal "side-1-run", review.status.fetch("run_public_id")
  end

  def test_unchanged_invalid_and_failed_proposals_leave_the_saved_document_alone
    prepare_review
    finish_review(content: JSON.generate(content: input.fetch("content"), summary: ""))
    assert_equal "unchanged", review.status.fetch("outcome")
    assert_equal 1, @memory.writes.length

    review.settled(settlement(source(position: 2)))
    finish_review(content: "not JSON")
    assert_equal "failed", review.status.fetch("outcome")
    refute review.status.fetch("pending")
    review.settled(settlement(source(position: 3)))
    finish_review(status: "failed")
    assert_equal "failed", review.status.fetch("outcome")
    refute review.status.fetch("pending")
    assert_equal 1, @memory.writes.length
    assert_equal "completed", @conversation.turns.rows.fetch("turn-1").status
  end

  def test_summary_and_source_identifiers_must_fit_the_same_document_budget
    prepare_review
    finish_review(content: JSON.generate(content: "A" * Rho::MemoryReview::DOCUMENT_BYTES, summary: "A new summary"))

    assert_equal "failed", review.status.fetch("outcome")
    assert_equal Rho::MemoryReview::INITIAL_CONTENT, @memory.rows.fetch(PATH).content
    assert_equal 1, @memory.writes.length
  end

  def test_disable_cancels_queued_input_and_live_side_without_touching_the_source
    prepare_review
    canceled_side = side
    result = review.disable

    assert_equal "canceled", result.fetch("outcome")
    refute result.fetch("pending")
    assert_equal ["input-1"], canceled_side.inputs.deletions
    assert_equal 1, canceled_side.cancellations
    assert_equal 0, @conversation.cancellations
    assert_equal Rho::MemoryReview::INITIAL_CONTENT, @memory.rows.fetch(PATH).content
    review.resume
    assert_equal 1, canceled_side.inputs.creates.length
  end

  def test_a_canceled_model_side_clears_pending_and_cannot_be_replayed
    prepare_review
    finish_review(status: "canceled")
    assert_equal "canceled", review.status.fetch("outcome")
    refute review.status.fetch("pending")
    review.resume
    assert_equal 1, side.inputs.creates.length
    assert_equal 1, @memory.writes.length
  end

  def test_a_blocked_or_deleted_side_clears_pending_without_new_model_work
    prepare_review
    side.inputs.records["input-1"] = side.inputs.records.fetch("input-1").with(state: "blocked")
    assert_equal "failed", review.resume.fetch("outcome")
    refute review.status.fetch("pending")
    review.settled(settlement(source(position: 2)))
    @workspace.rows.delete(side.public_id)
    assert_equal "canceled", review.resume.fetch("outcome")
    refute review.status.fetch("pending")
  end

  def test_a_replaced_source_is_never_applied
    turn = prepare_review
    @conversation.turns.rows[turn.public_id] = turn.with(active_variant: turn.active_variant.with(run_public_id: "replacement"))
    finish_review
    assert_equal "skipped", review.status.fetch("outcome")
    assert_equal 1, @memory.writes.length
  end

  def test_a_forked_store_snapshot_does_not_enable_review_but_the_side_marker_finds_its_source
    prepare_review
    child = Rho::MemoryReview.new(workspace: @workspace, conversation_public_id: side.public_id)
    refute child.status.fetch("enabled")
    assert_nil child.status.fetch("run_public_id")
    assert_equal "conversation-1", Rho::MemoryReview.source_for(workspace: @workspace, conversation_public_id: side.public_id)
  end

  def test_noncompleted_and_hidden_source_turns_never_place_review_work
    enable
    %w[failed canceled].each do |status|
      turn = source.with(status: status)
      @conversation.turns.rows[turn.public_id] = turn
      review.settled(settlement(turn))
    end
    turn = source.with(visibility: "hidden")
    @conversation.turns.rows[turn.public_id] = turn
    review.settled(settlement(turn))
    assert_empty @workspace.forks
  end

  def test_utf8_source_is_bounded_without_breaking_characters
    enable
    review.settled(settlement(source(prompt: "界" * 10_000, answer: "🙂" * 10_000)))
    %w[prompt answer].each do |field|
      assert_predicate input.fetch(field), :valid_encoding?
      assert_operator input.fetch(field).bytesize, :<=, Rho::MemoryReview::SOURCE_BYTES / 2
    end
    assert_operator JSON.generate(input).bytesize, :<, 64 * 1024
  end

  private

    def review
      Rho::MemoryReview.new(workspace: @workspace, conversation_public_id: "conversation-1", clock: -> { @now },
        follow: ->(id) { @followed << id }, forget: ->(id) { @forgotten << id })
    end

    def enable(path: PATH) = review.enable(path: path)

    def source(position: 1, prompt: "Remember a useful preference", answer: "The verified answer", memory_context: nil)
      model = CybrosAgent::Api::ConversationModel.new(provider_id: "test", model_ref: "model", reasoning_effort: nil)
      variant = Fixtures::Variant.new(run_public_id: "source-#{position}", status: "completed", memory_context: memory_context,
        prompt_text: prompt, content: answer, model: model)
      turn = Fixtures::Turn.new(public_id: "turn-#{position}", position: position, kind: "direct_reply", status: "completed",
        visibility: "visible", inherited: false, active_variant: variant, created_at: "2026-10-07T00:00:00Z")
      @conversation.turns.rows[turn.public_id] = turn
      turn
    end

    def settlement(turn, conversation_public_id: "conversation-1")
      Rho::TurnSettlement.new(workspace_public_id: "workspace", conversation_public_id: conversation_public_id,
        turn_public_id: turn.public_id, run_public_id: turn.active_variant.run_public_id, status: turn.status,
        model: "test/model", memory_context: turn.active_variant.memory_context)
    end

    def prepare_review
      enable
      turn = source
      review.settled(settlement(turn))
      turn
    end

    def input = review.state.pending.input
    def side = @workspace.conversation(review.status.fetch("review_conversation_public_id"))
    def proposal = JSON.generate(content: "# Stable notes\nUse concise replies.", summary: "Completed the migration tests.")

    def finish_review(content: proposal, status: "completed")
      current = side
      turn = current.settle(content: content, status: status)
      review.settled(settlement(turn, conversation_public_id: current.public_id))
    end
end
