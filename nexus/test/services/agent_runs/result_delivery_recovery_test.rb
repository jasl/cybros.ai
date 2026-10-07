require "test_helper"

class AgentRuns::ResultDeliveryRecoveryTest < ActiveJob::TestCase
  include InvocationHarness
  include RunLaneTestHelper

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @agent = users(:agent)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(@account)
    @conversation = Conversation.create!(workspace: @workspace, creating_user: @human,
      answering_user: @agent)
    declare_tools!(@agent, tools: [Nexus::Tools::DELEGATE_TASK, Nexus::Tools::ASK, READ_TOOL])
  end

  test "recurring recovery delivers a settled background result after its mail wake is lost" do
    agent_run = delivered_loop

    assert_enqueued_with(job: AgentRuns::ResultDeliveryJob, args: [agent_run.id]) do
      answer(agent_run, "r2t0-model-1", "the check passed")
    end
    assert_equal "completed", agent_run.reload.status
    tip = loop_node(agent_run, "r2t0-model-1")
    assert_nil tip.result_delivered_at
    assert_equal 0, @conversation.conversation_inputs.count

    # Production commits primary state before enqueueing on its independent
    # queue database. Dropping the hint models a process death in that gap.
    clear_enqueued_jobs
    perform_enqueued_jobs(only: AgentRuns::ResultDeliveryJob) do
      2.times do
        AgentRuns::ScheduleSweepJob.perform_now
        AgentRuns::ConvergeTerminalSteps.call
        AgentRuns::DrainSweep.call
        AgentRuns::Parks::TimeoutSweep.call
        Conversations::Turns::Converge.call
      end
    end

    assert_equal 1, @conversation.conversation_inputs.count,
      "the recurring floor must rediscover the durable unmailed result"
    assert_not_nil tip.reload.result_delivered_at
  end

  test "a failed delivery stamp rolls back its input and receipt together" do
    agent_run = delivered_loop
    answer(agent_run, "r2t0-model-1", "the check passed")
    mailer = AgentRuns::ResultDelivery.new(agent_run.reload)

    assert_no_difference [-> { @conversation.conversation_inputs.count }, -> { ConversationCommandReceipt.count }] do
      mailer.stub(:stamp, ->(_tip) { raise IOError, "delivery interrupted" }) do
        assert_raises(IOError) { mailer.call }
      end
    end
    tip = loop_node(agent_run, "r2t0-model-1")
    assert_nil tip.result_delivered_at

    travel 25.hours
    assert_equal [:delivered], mailer.call
    assert_not_nil tip.reload.result_delivered_at
    travel 25.hours
    assert_equal [], mailer.call
    assert_equal 1, @conversation.conversation_inputs.count
  end

  test "a delivered loop's pause retains its completed background mail" do
    agent_run = delivered_loop(branches: 2)
    answer(agent_run, "r2t0-model-1", "the first check passed")
    AgentRuns::Pause.call(AgentRuns::Pause::Command.graceful(agent_run:, acting_user: @human))
    clear_enqueued_jobs

    perform_enqueued_jobs(only: AgentRuns::ResultDeliveryJob) { AgentRuns::ScheduleSweepJob.perform_now }

    assert_equal "paused", agent_run.reload.status
    assert_equal 1, @conversation.conversation_inputs.count
    assert_equal "completed", agent_run.conversation_turn.reload.status
    assert_equal "running", loop_node(agent_run, "r2t1-model-1").status
  end

  test "an expired background ask does not swallow an already completed sibling's mail" do
    agent_run = delivered_loop(branches: 2)
    answer(agent_run, "r2t0-model-1", "the first check passed")
    answer(agent_run, "r2t1-model-1", "asking", calls: [{
      id: "question", name: "ask", arguments: { prompt: "which file?" }.to_json,
    }])
    dispatch_tools(agent_run)
    ask = agent_run.agent_run_tasks.where(type: AgentRunTasks::AwaitTask.sti_name).sole
    ask.update_columns(await_started_at: 2.days.ago)
    AgentRuns::Parks::TimeoutSweep.call
    assert_equal "needs_attention", agent_run.reload.status
    clear_enqueued_jobs

    perform_enqueued_jobs(only: AgentRuns::ResultDeliveryJob) { AgentRuns::ScheduleSweepJob.perform_now }

    assert_equal "needs_attention", agent_run.reload.status
    assert_equal 1, @conversation.conversation_inputs.count
    assert_equal "completed", agent_run.conversation_turn.reload.status
    assert_equal "timed_out", ask.reload.status
  end

  test "a stopped delivered loop never wakes another turn from a queued mail job or recovery" do
    agent_run = delivered_loop(branches: 2)
    answer(agent_run, "r2t0-model-1", "the first check passed")
    AgentRuns::Stop.call(AgentRuns::Stop::Command.new(agent_run:, acting_user: @human, force: false))
    assert_equal "canceling", agent_run.reload.status
    assert_equal [], AgentRuns::ResultDelivery.call(agent_run)
    answer(agent_run, "r2t1-model-1", "the last check passed")
    assert_equal "canceled", agent_run.reload.status
    clear_enqueued_jobs

    AgentRuns::ResultDeliveryJob.perform_now(agent_run.id)
    perform_enqueued_jobs(only: AgentRuns::ResultDeliveryJob) { AgentRuns::ScheduleSweepJob.perform_now }

    assert_equal 0, @conversation.conversation_inputs.count
    assert_equal "completed", agent_run.conversation_turn.reload.status
  end

  test "recovery advances past a full window of already read detached history" do
    consumed_loop = delivered_loop
    answer(consumed_loop, "r2t0-model-1", "already read")
    tip = loop_node(consumed_loop, "r2t0-model-1")
    tip.update_columns(result_delivered_at: Time.current)
    retained_ids = AgentRunTask.insert_all!(Array.new(3) do |index|
      tip.attributes.except("id").merge("node_key" => "retained_#{index}", "result_delivered_at" => nil)
    end, returning: %w[id]).rows.flatten
    AgentRunTask.where(id: loop_node(consumed_loop, "r2").id)
      .update_all(input_from_node_keys: %w[retained_0 retained_1 retained_2])
    assert_not AgentRuns::ResultDelivery.pending?(consumed_loop.reload)

    ready_loop = delivered_loop
    answer(ready_loop, "r2t0-model-1", "still owed")
    clear_enqueued_jobs
    first = AgentRuns::ScheduleSweep.call(schedule_after_id: nil, result_delivery_after_id: retained_ids.first - 1, batch: 2)
    assert_equal 2, first[:scanned]
    assert_equal 0, first[:result_delivery_woken]
    assert_equal [nil, retained_ids.second], first.cursor
    assert_predicate first, :more?

    perform_enqueued_jobs(only: AgentRuns::ResultDeliveryJob) do
      second = AgentRuns::ScheduleSweep.call(schedule_after_id: first.cursor.first,
        result_delivery_after_id: first.cursor.last, batch: 2)
      assert_equal 1, second[:result_delivery_woken]
      assert_nil second.cursor.first, "an exhausted phase stays parked for this chain"
    end
    assert_equal 1, @conversation.conversation_inputs.count
    assert_not_nil loop_node(ready_loop, "r2t0-model-1").reload.result_delivered_at
  end

  test "a failed mail enqueue advances the window and does not fence a healthy sibling" do
    poisoned = delivered_loop
    answer(poisoned, "r2t0-model-1", "first result")
    healthy = delivered_loop
    answer(healthy, "r2t0-model-1", "next result")
    attempts = []
    errors = []
    reported_context = nil
    enqueue = ->(id) do
      attempts << id
      raise IOError, "queue unavailable" if id == poisoned.id
    end
    result = nil
    report = ->(error, context:, **) do
      errors << error
      reported_context = context
    end
    Rails.error.stub(:report, report) do
      AgentRuns::ResultDeliveryJob.stub(:perform_later, enqueue) do
        result = AgentRuns::ScheduleSweep.call(schedule_after_id: nil,
          result_delivery_after_id: loop_node(poisoned, "r2t0-model-1").id - 1, batch: 2)
      end
    end

    assert_equal [poisoned.id, healthy.id], attempts
    assert_equal ["queue unavailable"], errors.map(&:message)
    assert_equal poisoned.public_id, reported_context.fetch(:run_public_id)
    assert_not reported_context.key?(:agent_run_id)
    assert_equal 1, result[:result_delivery_woken]
    assert_equal [nil, loop_node(healthy, "r2t0-model-1").id], result.cursor
    assert_nil loop_node(poisoned, "r2t0-model-1").reload.result_delivered_at
  end

  test "a full queue leaves one attempt per periodic pass without accumulating retry chains" do
    agent_run = delivered_loop
    answer(agent_run, "r2t0-model-1", "the check passed")
    @conversation.reload.update!(input_queue_limit: 1)
    blocker = post_input!(@conversation, acting_user: @human, text: "hold the queue")
    clear_enqueued_jobs
    clear_performed_jobs

    3.times do |index|
      perform_enqueued_jobs(only: AgentRuns::ResultDeliveryJob, at: Time.current) { AgentRuns::ScheduleSweepJob.perform_now }
      assert_equal index + 1, performed_jobs.count { |job| job[:job] == AgentRuns::ResultDeliveryJob }
      assert_no_enqueued_jobs(only: AgentRuns::ResultDeliveryJob)
      assert_nil loop_node(agent_run, "r2t0-model-1").reload.result_delivered_at
    end
    blocker.destroy!
    perform_enqueued_jobs(only: AgentRuns::ResultDeliveryJob) { AgentRuns::ScheduleSweepJob.perform_now }
    assert_equal 1, @conversation.conversation_inputs.count
    assert_not_nil loop_node(agent_run, "r2t0-model-1").reload.result_delivered_at
  end

  private

    def delivered_loop(branches: 1)
      _turn, agent_run = materialize_loop_reply!(@conversation, agent: @agent,
        text: "run background checks")
      schedule_loop!(agent_run)
      calls = Array.new(branches) do |index|
        { id: "background_check_#{index}", name: "delegate_task",
          arguments: { prompt: "check result #{index}" }.to_json }
      end
      answer(agent_run, "r1", "delegating", calls:)
      dispatch_tools(agent_run)
      answer(agent_run, "r2", "I will report the checks later")
      Conversations::Turns::Converge.call
      assert_predicate agent_run.reload, :delivered?
      assert_equal "running", agent_run.status
      agent_run
    end

    def dispatch_tools(agent_run)
      perform_enqueued_jobs(only: [AgentRuns::DelegateTaskToolJob, AgentRuns::AskJob, AgentRuns::ScheduleJob]) do
        AgentRuns::ScheduleReady.call(agent_run_id: agent_run.id)
      end
    end

    def answer(agent_run, key, text, calls: [])
      invocation_id = loop_node(agent_run, key).selected_model_invocation_id
      ModelInvocations::AdmitQueuedWork.call
      clear_enqueued_jobs
      attempt = ModelInvocationAttempt.where(model_invocation_id: invocation_id).order(:id).last
      apply_via(attempt, sse_success(text, tool_calls: calls))
      AgentRuns::ConvergeTerminalSteps.call
      AgentRuns::ScheduleReady.call(agent_run_id: agent_run.id) if calls.empty?
    end
end
