require "test_helper"

class ModelInvocations::ExecuteAttemptCompletionTest < ActiveJob::TestCase
  include InvocationHarness

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(@account)
  end

  %i[inference_request conversation agent_run].each do |owner|
    test "a completed #{owner} wakes only its own invocation and leaves other terminal work to recovery" do
      retained = public_send("#{owner}_attempt")
      apply_via(retained, sse_success("retained"))
      target = public_send("#{owner}_attempt")
      clear_enqueued_jobs

      fake_dispatch(sse_success("target")) do
        ModelInvocations::ExecuteAttempt.call(attempt: target, host: "solid_queue")
      end

      wakes = completion_wakes
      assert_equal 1, wakes.length, "one invocation has one completion owner"
      assert_equal expected_wake(target.model_invocation), [wakes.sole[:job], wakes.sole[:args]]
      clear_enqueued_jobs
      wakes.sole[:job].perform_now(*wakes.sole[:args])

      assert_not_nil target.model_invocation.reload.terminal_event_recorded_at
      assert_completed_owner(target.model_invocation)
      assert_nil retained.model_invocation.reload.terminal_event_recorded_at,
        "the precise wake must not become a global recovery pass"
      assert_empty completion_wakes, "precise completion must not start a continuation chain"

      assert_no_difference -> { terminal_item_count(target.model_invocation) } do
        wakes.sole[:job].perform_now(*wakes.sole[:args])
      end
      assert_nil retained.model_invocation.reload.terminal_event_recorded_at

      wakes.sole[:job].perform_now
      assert_not_nil retained.model_invocation.reload.terminal_event_recorded_at,
        "the existing recurring entrypoint still recovers a lost completion wake"
    end
  end

  test "a pre-IO refusal precisely wakes its completion owner without dispatching" do
    attempt = inference_request_attempt
    ModelProviderConfig.find_by!(account: @account, provider_id: "dev").update!(enabled: false)
    clear_enqueued_jobs

    ModelInvocations::ExecutionAdapter.stub(:for, ->(*) { flunk "disabled provider reached IO" }) do
      ModelInvocations::ExecuteAttempt.call(attempt: attempt, host: "solid_queue")
    end

    assert_equal "failed", attempt.model_invocation.reload.status
    assert_equal [expected_wake(attempt.model_invocation)], completion_wakes.map { |job| [job[:job], job[:args]] }
  end

  test "a transient requeue wakes admission without waking a completion owner" do
    attempt = inference_request_attempt
    clear_enqueued_jobs

    fake_dispatch(json_response(503, { "error" => { "message" => "overloaded" } })) do
      ModelInvocations::ExecuteAttempt.call(attempt: attempt, host: "solid_queue")
    end

    assert_equal "queued", attempt.model_invocation.reload.status
    assert_empty completion_wakes
    assert_enqueued_with(job: ModelInvocations::AdmitQueuedWorkJob)
  end

  test "a precise stale completion job never scans unrelated terminal work" do
    retained = inference_request_attempt
    apply_via(retained, sse_success("retained"))
    clear_enqueued_jobs

    InferenceRequests::ConvergeTerminalEventsJob.perform_now({ "invocation_id" => 0 })
    AgentRuns::ConvergeTerminalStepsJob.perform_now(0, { "invocation_id" => 0 })
    Conversations::Turns::ConvergeJob.perform_now(0, { "invocation_id" => 0 })

    assert_nil retained.model_invocation.reload.terminal_event_recorded_at
    assert_empty completion_wakes
  end

  test "a deadline terminalization wakes only the timed out invocation owner" do
    attempt = inference_request_attempt
    ModelInvocationAttempt.where(id: attempt.id).update_all(deadline_at: 1.minute.ago)
    clear_enqueued_jobs

    assert_equal 1, ModelInvocations::DeadlineSweep.call[:timed_out]

    assert_equal "timed_out", attempt.model_invocation.reload.status
    assert_equal [expected_wake(attempt.model_invocation)], completion_wakes.map { |job| [job[:job], job[:args]] }
  end

  test "an admission refusal wakes only its invocation owner" do
    inference_request = InferenceRequest.create!(workspace: @workspace, account: @account,
      creating_user: @human, workload: "text_generation")
    invocation = DevModelLane.create_invocation!(inference_request: inference_request)
    ModelProviderConfig.find_by!(account: @account, provider_id: "dev").update!(enabled: false)
    clear_enqueued_jobs

    assert_empty ModelInvocations::AdmitQueuedWork.call.admitted

    assert_equal "failed", invocation.reload.status
    assert_equal [expected_wake(invocation)], completion_wakes.map { |job| [job[:job], job[:args]] }
  end

  test "precise jobs leave live and differently owned invocations unchanged" do
    attempt = inference_request_attempt
    options = { "invocation_id" => attempt.model_invocation_id }
    clear_enqueued_jobs

    InferenceRequests::ConvergeTerminalEventsJob.perform_now(options)
    AgentRuns::ConvergeTerminalStepsJob.perform_now(0, options)
    Conversations::Turns::ConvergeJob.perform_now(0, options)

    assert_equal "running", attempt.model_invocation.reload.status
    assert_nil attempt.model_invocation.terminal_event_recorded_at
    assert_empty completion_wakes

    apply_via(attempt, sse_success("retained"))
    AgentRuns::ConvergeTerminalStepsJob.perform_now(0, options)
    Conversations::Turns::ConvergeJob.perform_now(0, options)

    assert_nil attempt.model_invocation.reload.terminal_event_recorded_at
    assert_empty completion_wakes
  end

  test "a rolled back terminalization never publishes its precise completion wake" do
    attempt = inference_request_attempt
    invocation = attempt.model_invocation
    clear_enqueued_jobs

    ApplicationRecord.transaction(requires_new: true) do
      invocation.with_lock do
        invocation.terminalize(status: "failed", reason_key: "provider_error")
        invocation.converge_owner_later
      end
      assert_empty completion_wakes, "the owner must not see uncommitted terminal state"
      raise ActiveRecord::Rollback
    end

    assert_equal "running", invocation.reload.status
    assert_empty completion_wakes
  end

  def inference_request_attempt = admitted_attempt

  def conversation_attempt
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
    admit(conversation.model_invocations.sole)
  end

  def agent_run_attempt
    agent_run = seed(model("round"))
    assert_predicate AgentRuns::Start.call(AgentRuns::Start::Command.new(
      agent_run: agent_run, acting_user: @human
    )), :accepted?
    AgentRuns::ScheduleReady.call(agent_run_id: agent_run.id)
    admit(agent_run.model_invocations.sole)
  end

  private

    def admit(invocation)
      ModelInvocations::AdmitQueuedWork.call.admitted
        .find { |candidate| candidate.attempt.model_invocation_id == invocation.id }.attempt
    end

    def completion_wakes
      enqueued_jobs.select do |job|
        [InferenceRequests::ConvergeTerminalEventsJob, Conversations::Turns::ConvergeJob,
         AgentRuns::ConvergeTerminalStepsJob].include?(job[:job])
      end.map do |job|
        { job: job[:job], args: ActiveJob::Arguments.deserialize(job[:args]) }
      end
    end

    def expected_wake(invocation)
      options = { "invocation_id" => invocation.id }
      case invocation.purpose
      when ModelInvocation::INFERENCE_REQUEST_PURPOSE
        [InferenceRequests::ConvergeTerminalEventsJob, [options]]
      when ModelInvocation::CONVERSATION_REPLY_PURPOSE
        [Conversations::Turns::ConvergeJob, [invocation.conversation_id, options]]
      else
        [AgentRuns::ConvergeTerminalStepsJob, [0, options]]
      end
    end

    def terminal_item_count(invocation)
      case invocation.purpose
      when ModelInvocation::INFERENCE_REQUEST_PURPOSE
        InferenceRequestEventItem.where(inference_request_id: invocation.inference_request_id).count
      when ModelInvocation::CONVERSATION_REPLY_PURPOSE
        invocation.conversation.conversation_event_items.count
      else
        invocation.agent_run.conversation_event_items.count
      end
    end

    def assert_completed_owner(invocation)
      case invocation.purpose
      when ModelInvocation::INFERENCE_REQUEST_PURPOSE
        result = InferenceRequestEventItem.find_by!(inference_request_id: invocation.inference_request_id, item_type: "result")
        assert_equal "completed", result.payload.dig("result", "status")
      when ModelInvocation::CONVERSATION_REPLY_PURPOSE
        turn = invocation.conversation.conversation_turns.sole
        assert_equal "completed", turn.status
        assert_equal "Mock: target", turn.active_variant.content_preview
      else
        node = invocation.agent_run.agent_run_tasks.find_by!(selected_model_invocation_id: invocation.id)
        assert_equal "completed", node.status
      end
    end
end
