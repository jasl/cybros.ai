require "test_helper"

# THE STATUS VOCABULARY, ASKED THE WAY A CLIENT ASKS IT.
#
# This gem is the one place the kernel's status words live on the client
# side; rho derives from here and holds none of its own. The bug this
# guards is specific and has happened: a hand-written list of "live"
# statuses in a second repository went blind the day the kernel split
# `running` into the words that say WHO is being waited on, and the
# acceptance gate that read it waited half a day instead of failing.
class RunTaskVocabularyTest < Minitest::Test
  def task(status, kind: "tool_task")
    CybrosAgent::Api::RunTask.new(
      key: "t", kind: kind, status: status, lifetime: "conversation", wake: "auto",
      on_failure: nil, failure_resolution: nil,
      tool_name: nil, result: nil, error: nil, visibility: nil,
      created_at: nil, started_at: nil, completed_at: nil
    )
  end

  # A call out at the person's machine, and a question waiting on the
  # person: both are IN FLIGHT, and neither is `running`.
  def test_a_park_is_started_and_live_but_not_running
    %w[dispatched awaiting_input].each do |status|
      subject = task(status)

      assert_predicate subject, :live?
      assert_predicate subject, :started?
      refute_predicate subject, :running?, "#{status} is not the kernel doing it"
      refute_predicate subject, :terminal?
    end
  end

  def test_running_means_the_kernel_is_doing_it
    subject = task("running")

    assert_predicate subject, :running?
    assert_predicate subject, :started?
    assert_predicate subject, :live?
  end

  # Authored and unspent: live, but nothing has begun.
  def test_a_pre_start_status_is_live_and_not_started
    %w[waiting needs_approval].each do |status|
      subject = task(status)

      assert_predicate subject, :live?
      refute_predicate subject, :started?, "#{status} has spent nothing yet"
    end
  end

  def test_every_terminal_status_is_neither_live_nor_started
    CybrosAgent::Api::TASK_TERMINAL_STATUSES.each do |status|
      subject = task(status)

      assert_predicate subject, :terminal?
      refute_predicate subject, :live?
      refute_predicate subject, :started?
    end
  end

  # The sweep's word for a claimed, non-replayable call whose executor
  # expired with no result: settled, so terminal — and
  # adjudicable like a failure, which is what `repairable_tasks` reads.
  def test_uncertain_is_terminal_and_failed_so_an_adjudicator_lists_it
    subject = task("uncertain")

    assert_predicate subject, :terminal?
    refute_predicate subject, :live?
    refute_predicate subject, :started?
    assert_predicate subject, :failed?
    assert_equal 1, CybrosAgent::Api::RunProgress.new(uncertain: 1).uncertain,
      "the bucket the kernel sends is named, never dropped on the floor"
  end

  # A status this gem predates must not read as terminal — a client that
  # treated an unknown word as finished would stop following a live run.
  def test_an_unknown_status_is_live_rather_than_finished
    subject = task("some_future_word")

    refute_predicate subject, :terminal?
    assert_predicate subject, :live?
    assert_predicate subject, :started?
  end

  # The progress block is FLAT, one count per status, because that is what
  # the kernel sends. It asked for `counts`/`active_task_keys` for a long
  # time and every bucket read empty.
  def test_progress_reads_the_flat_shape_the_kernel_sends
    progress = CybrosAgent::Api::RunProgress.new(total: 3, waiting: 1, dispatched: 2)

    assert_equal 3, progress.total
    assert_equal 1, progress.waiting
    assert_equal 2, progress.dispatched
    assert_equal 0, progress.awaiting_input, "an absent bucket reads zero, never nil"
  end
end
