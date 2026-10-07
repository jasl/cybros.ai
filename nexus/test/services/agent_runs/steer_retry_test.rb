require "test_helper"

class AgentRuns::SteerRetryTest < ActiveJob::TestCase
  include InvocationHarness

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(@account)
  end

  test "an interrupted round retains its landed steer when resumed without another input" do
    agent_run, input = start_steered_round
    pause_round(agent_run)
    resume_round(agent_run)

    assert_equal [AgentRuns::InputComposition::ABORT_MARKER, "original plan", "keep the tests"],
      request_texts(round(agent_run))
    assert_landing(agent_run, [input], ["keep the tests"])
  end

  test "a resumed round appends new steers after the ones its earlier generation read" do
    agent_run, first = start_steered_round
    pause_round(agent_run)
    second = steer(agent_run, "use Ruby")
    resume_round(agent_run)

    assert_equal ["original plan", "keep the tests", "use Ruby"], request_texts(round(agent_run))
    assert_landing(agent_run, [first, second], ["keep the tests", "use Ruby"])

    # A repeated wake does not materialize either input a second time.
    schedule(agent_run)
    assert_landing(agent_run, [first, second], ["keep the tests", "use Ruby"])
  end

  test "a node automatic retry retains the directive from the failed request" do
    agent_run, input = start_steered_round(retry_budget: 1)
    fail_round(agent_run)
    assert_equal "queued", round(agent_run).status
    schedule(agent_run)

    assert_equal ["original plan", "keep the tests"], request_texts(round(agent_run))
    assert_landing(agent_run, [input], ["keep the tests"])
  end

  test "an explicit retry after a halt retains the directive from the failed request" do
    agent_run, input = start_steered_round
    fail_round(agent_run)
    schedule(agent_run)
    assert_equal "needs_attention", agent_run.reload.status

    result = AgentRuns::Tasks::Retry.call(AgentRuns::Tasks::Retry::Command.new(
      agent_run: agent_run, task_key: "main", acting_user: @human
    ))
    assert_predicate result, :accepted?
    schedule(agent_run)

    assert_equal ["original plan", "keep the tests"], request_texts(round(agent_run))
    assert_landing(agent_run, [input], ["keep the tests"])
  end

  private

    def start_steered_round(retry_budget: 0)
      agent_run = seed(model("main", "prompt" => "original plan", "retry" => retry_budget))
      input = steer(agent_run, "keep the tests")
      result = AgentRuns::Start.call(AgentRuns::Start::Command.new(
        agent_run: agent_run, acting_user: @human
      ))
      assert_predicate result, :accepted?
      schedule(agent_run)
      assert_equal ["original plan", "keep the tests"], request_texts(round(agent_run))
      assert_not ConversationInput.exists?(input.id)
      [agent_run, input]
    end

    def steer(agent_run, text)
      result = loop_input!(agent_run, acting_user: @human, text: text)
      assert_predicate result, :accepted?
      result.value
    end

    def pause_round(agent_run)
      result = AgentRuns::Pause.call(AgentRuns::Pause::Command.new(
        agent_run: agent_run, acting_user: @human, force: true
      ))
      assert_predicate result, :accepted?
      AgentRuns::ConvergeTerminalSteps.call
      assert_equal "queued", round(agent_run).status
      assert_equal 1, round(agent_run).execution_generation
      clear_enqueued_jobs
    end

    def resume_round(agent_run)
      result = AgentRuns::Resume.call(AgentRuns::Resume::Command.new(
        agent_run: agent_run, acting_user: @human
      ))
      assert_predicate result, :accepted?
      schedule(agent_run)
    end

    def fail_round(agent_run)
      invocation_id = round(agent_run).selected_model_invocation_id
      admitted = ModelInvocations::AdmitQueuedWork.call.admitted.find do |candidate|
        candidate.attempt.model_invocation_id == invocation_id
      end
      assert_not_nil admitted
      apply_via(admitted.attempt, json_response(400, { "error" => { "message" => "bad request" } }))
      assert_equal "failed", ModelInvocation.find(invocation_id).status
      AgentRuns::ConvergeTerminalSteps.call
      clear_enqueued_jobs
    end

    def schedule(agent_run)
      AgentRuns::ScheduleReady.call(agent_run_id: agent_run.id)
      clear_enqueued_jobs
    end

    def round(agent_run) = agent_run.agent_run_tasks.find_by!(node_key: "main")

    def request_texts(node)
      node.invocation_body("request").content_body_entries.map do |entry|
        entry.content_fragment.payload.dig("parts", 0, "text")
      end
    end

    def assert_landing(agent_run, inputs, texts)
      node = round(agent_run)
      assert_equal texts, AgentRuns::Steers::Landed.texts_by_round([node]).fetch(node.id)
      assert_empty agent_run.conversation_inputs
      landed = agent_run.conversation_event_items.where(item_type: "input_materialized")
      assert_equal inputs.map(&:public_id).sort,
        landed.map { |item| item.payload.fetch("input_public_id") }.sort
    end
end
