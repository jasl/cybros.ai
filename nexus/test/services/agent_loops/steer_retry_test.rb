require "test_helper"

class AgentLoops::SteerRetryTest < ActiveJob::TestCase
  include InvocationHarness

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(@account)
  end

  test "an interrupted round retains its landed steer when resumed without another input" do
    agent_loop, input = start_steered_round
    pause_round(agent_loop)
    resume_round(agent_loop)

    assert_equal [AgentLoops::InputComposition::ABORT_MARKER, "original plan", "keep the tests"],
      request_texts(round(agent_loop))
    assert_landing(agent_loop, [input], ["keep the tests"])
  end

  test "a resumed round appends new steers after the ones its earlier generation read" do
    agent_loop, first = start_steered_round
    pause_round(agent_loop)
    second = steer(agent_loop, "use Ruby")
    resume_round(agent_loop)

    assert_equal ["original plan", "keep the tests", "use Ruby"], request_texts(round(agent_loop))
    assert_landing(agent_loop, [first, second], ["keep the tests", "use Ruby"])

    # A repeated wake does not materialize either input a second time.
    schedule(agent_loop)
    assert_landing(agent_loop, [first, second], ["keep the tests", "use Ruby"])
  end

  test "a node automatic retry retains the directive from the failed request" do
    agent_loop, input = start_steered_round(retry_budget: 1)
    fail_round(agent_loop)
    assert_equal "queued", round(agent_loop).status
    schedule(agent_loop)

    assert_equal ["original plan", "keep the tests"], request_texts(round(agent_loop))
    assert_landing(agent_loop, [input], ["keep the tests"])
  end

  test "an explicit retry after a halt retains the directive from the failed request" do
    agent_loop, input = start_steered_round
    fail_round(agent_loop)
    schedule(agent_loop)
    assert_equal "needs_attention", agent_loop.reload.status

    result = AgentLoops::Tasks::Retry.call(AgentLoops::Tasks::Retry::Command.new(
      agent_loop: agent_loop, task_key: "main", acting_user: @human
    ))
    assert_predicate result, :accepted?
    schedule(agent_loop)

    assert_equal ["original plan", "keep the tests"], request_texts(round(agent_loop))
    assert_landing(agent_loop, [input], ["keep the tests"])
  end

  private

    def start_steered_round(retry_budget: 0)
      agent_loop = seed(model("main", "prompt" => "original plan", "retry" => retry_budget))
      input = steer(agent_loop, "keep the tests")
      result = AgentLoops::Start.call(AgentLoops::Start::Command.new(
        agent_loop: agent_loop, acting_user: @human
      ))
      assert_predicate result, :accepted?
      schedule(agent_loop)
      assert_equal ["original plan", "keep the tests"], request_texts(round(agent_loop))
      assert_not ConversationInput.exists?(input.id)
      [agent_loop, input]
    end

    def steer(agent_loop, text)
      result = loop_input!(agent_loop, acting_user: @human, text: text)
      assert_predicate result, :accepted?
      result.value
    end

    def pause_round(agent_loop)
      result = AgentLoops::Pause.call(AgentLoops::Pause::Command.new(
        agent_loop: agent_loop, acting_user: @human, force: true
      ))
      assert_predicate result, :accepted?
      AgentLoops::ConvergeTerminalSteps.call
      assert_equal "queued", round(agent_loop).status
      assert_equal 1, round(agent_loop).execution_generation
      clear_enqueued_jobs
    end

    def resume_round(agent_loop)
      result = AgentLoops::Resume.call(AgentLoops::Resume::Command.new(
        agent_loop: agent_loop, acting_user: @human
      ))
      assert_predicate result, :accepted?
      schedule(agent_loop)
    end

    def fail_round(agent_loop)
      invocation_id = round(agent_loop).selected_model_invocation_id
      admitted = ModelInvocations::AdmitQueuedWork.call.admitted.find do |candidate|
        candidate.attempt.model_invocation_id == invocation_id
      end
      assert_not_nil admitted
      apply_via(admitted.attempt, json_response(400, { "error" => { "message" => "bad request" } }))
      assert_equal "failed", ModelInvocation.find(invocation_id).status
      AgentLoops::ConvergeTerminalSteps.call
      clear_enqueued_jobs
    end

    def schedule(agent_loop)
      AgentLoops::ScheduleReady.call(agent_loop_id: agent_loop.id)
      clear_enqueued_jobs
    end

    def round(agent_loop) = agent_loop.agent_loop_nodes.find_by!(node_key: "main")

    def request_texts(node)
      node.invocation_body("request").content_body_entries.map do |entry|
        entry.content_fragment.payload.dig("parts", 0, "text")
      end
    end

    def assert_landing(agent_loop, inputs, texts)
      node = round(agent_loop)
      assert_equal texts, AgentLoops::Steers::Landed.texts_by_round([node]).fetch(node.id)
      assert_empty agent_loop.conversation_inputs
      landed = agent_loop.conversation_event_items.where(item_type: "input_materialized")
      assert_equal inputs.map(&:public_id).sort,
        landed.map { |item| item.payload.fetch("input_public_id") }.sort
    end
end
