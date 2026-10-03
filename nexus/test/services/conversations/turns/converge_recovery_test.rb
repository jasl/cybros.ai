require "test_helper"

class Conversations::Turns::ConvergeRecoveryTest < ActiveJob::TestCase
  include InvocationHarness
  include ActiveSupport::Testing::ConstantStubbing

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(@account)
  end

  test "a retained reply failure cannot monopolize the recurring continuation" do
    retained = completed_reply
    healthy = completed_reply

    with_retained_settlement(retained) do |attempts|
      continuation = run_recovery_chain

      assert_equal "completed", healthy.reload.status,
        "later replies must settle even while the first reply's transaction keeps rolling back"
      assert_not_nil healthy.active_variant.model_invocation.reload.terminal_event_recorded_at
      assert_equal "running", retained.reload.status
      assert_nil retained.active_variant.model_invocation.reload.terminal_event_recorded_at
      assert_nil continuation, "a recovery chain ends after its source window is exhausted"
      assert_equal [retained.id, healthy.id], attempts,
        "the retained row is attempted only once per continuation chain"

      Conversations::Turns::ConvergeJob.perform_now
      assert_equal [retained.id, healthy.id, retained.id], attempts,
        "the next recurring wake retries the failed reply"
    end
  end

  test "a retained loop settlement failure cannot monopolize the recurring continuation" do
    retained = held_reply
    healthy = held_reply

    with_retained_settlement(retained) do |attempts|
      continuation = run_recovery_chain

      assert_equal "failed", healthy.reload.status,
        "the later held loop must settle its turn past a retained failure"
      assert_equal "failed", healthy.active_variant.status
      assert_equal "running", retained.reload.status
      assert_equal "running", retained.active_variant.status
      assert_nil continuation, "a recovery chain ends even when a loop remains on its frontier"
      assert_equal [retained.id, healthy.id], attempts

      Conversations::Turns::ConvergeJob.perform_now
      assert_equal [retained.id, healthy.id, retained.id], attempts,
        "the next recurring wake retries the failed loop settlement"
    end
  end

  test "each phase parks independently while full windows of healthy pairs continue" do
    retained = completed_reply
    loops = Array.new(3) { running_reply }

    with_retained_settlement(retained) do |attempts|
      first = Conversations::Turns::Converge.call(batch: 2,
        cursors: { "replace" => loops.first.agent_loop.id }).value

      assert_equal 7, first[:scanned], "all source rows consume budget, even pairs needing no update"
      assert_equal 0, first[:recorded]
      assert_equal({ "reply" => nil, "settle" => loops.first.variant.id,
                     "reopen" => loops.second.agent_loop.id, "replace" => loops.last.agent_loop.id }, first.cursor)
      assert_predicate first, :more?
      assert_equal [retained.id], attempts

      second = nil
      assert_no_queries_match(/FROM "model_invocations"/) do
        second = Conversations::Turns::Converge.call(batch: 2, cursors: first.cursor).value
      end
      assert_equal 3, second[:scanned]
      assert_equal 0, second[:recorded]
      assert_equal({ "reply" => nil, "settle" => loops.last.variant.id,
                     "reopen" => nil, "replace" => nil }, second.cursor)
      assert_predicate second, :more?, "the full settle source continues despite having no eligible pair"
      assert_equal [retained.id], attempts, "a partial failed reply phase stays parked"

      third = Conversations::Turns::Converge.call(batch: 2, cursors: second.cursor).value
      assert_equal 0, third[:scanned]
      assert_equal({ "reply" => nil, "settle" => nil, "reopen" => nil, "replace" => nil }, third.cursor)
      assert_not third.more?
      assert_no_queries do
        parked = Conversations::Turns::Converge.call(batch: 2, cursors: third.cursor).value
        assert_equal 0, parked[:scanned]
        assert_not parked.more?
      end

      Conversations::Turns::Converge.call(batch: 2)
      assert_equal [retained.id, retained.id], attempts, "only a fresh recurring wake retries parked failures"
    end
  end

  test "a zero budget reads no source and schedules no continuation" do
    target = held_reply
    clear_enqueued_jobs
    result = nil

    assert_no_queries { result = Conversations::Turns::Converge.call(batch: 0).value }

    assert_equal 0, result[:scanned]
    assert_equal 0, result[:recorded]
    assert_not result.more?
    stub_const(Conversations::Turns::ConvergeJob, :BATCH, 0) do
      assert_no_enqueued_jobs(only: Conversations::Turns::ConvergeJob) do
        Conversations::Turns::ConvergeJob.perform_now
      end
    end
    assert_equal "running", target.reload.status
  end

  test "the job forwards its precise loop option without starting a global pass" do
    retained = held_reply
    target = held_reply
    clear_enqueued_jobs

    assert_no_enqueued_jobs(only: Conversations::Turns::ConvergeJob) do
      Conversations::Turns::ConvergeJob.perform_now(target.conversation_id,
        { "agent_loop_id" => target.active_variant.agent_loop.id })
    end

    assert_equal "failed", target.reload.status
    assert_equal "running", retained.reload.status
  end

  private

    def completed_reply
      conversation = Conversation.create!(workspace: @workspace, creating_user: @human,
        answering_user: users(:agent))
      input = Conversations::Inputs::Create.call(Conversations::Inputs::Create::Command.new(
        host: conversation, acting_user: @human, kind: "direct_reply", role: "user",
        entries: [{ "text" => "answer me" }], visible_in_context: true, delivery_mode: "queue",
        context_mode: nil, context_options: nil, expected_context_revision: nil,
        expected_tail_turn_public_id: nil, provider_id: "dev", model_ref: "mock-text",
        reasoning_effort: nil, request_options: nil
      ))
      assert_predicate input, :accepted?
      assert_equal 1, Conversations::Inputs::ApplyNext.drain(conversation_id: conversation.id)
      invocation = conversation.model_invocations.sole
      attempt = ModelInvocations::AdmitQueuedWork.call.admitted
        .find { |candidate| candidate.attempt.model_invocation_id == invocation.id }.attempt
      apply_via(attempt, sse_success("the reply"))
      assert_predicate invocation.reload, :completed?
      conversation.conversation_turns.sole
    end

    def held_reply
      seam = running_reply
      AgentLoops::Transition.agent_loop(seam.agent_loop,
        status: "needs_attention", attention_reason: "halt_failure")
      seam.turn
    end

    def running_reply
      conversation = Conversation.create!(workspace: @workspace, creating_user: @human)
      create_loop_backed_turn(conversation: conversation, acting_user: @human)
    end

    # Fail after the normal writes: the existing per-row rescue must roll
    # those writes back, then let the continuation reach the next source row.
    def with_retained_settlement(retained)
      settle = Conversations::TranscriptStream.method(:settled_turn)
      attempts = []
      failing = ->(turn, **keys) do
        attempts << turn.id
        raise IOError, "transcript unavailable" if turn.id == retained.id

        settle.call(turn, **keys)
      end
      Rails.error.stub(:report, ->(*) { }) do
        Conversations::TranscriptStream.stub(:settled_turn, failing) do
          stub_const(Conversations::Turns::ConvergeJob, :BATCH, 1) { yield attempts }
        end
      end
    end

    def run_recovery_chain
      arguments = []
      continuation = nil
      3.times do
        clear_enqueued_jobs
        Conversations::Turns::ConvergeJob.perform_now(*arguments)
        continuation = enqueued_jobs.find { |job| job[:job] == Conversations::Turns::ConvergeJob }
        break if continuation.nil?

        arguments = continuation.fetch(:args)
      end
      continuation
    end
end
