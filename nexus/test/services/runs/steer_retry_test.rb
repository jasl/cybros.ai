require "test_helper"

class Runs::SteerRetryTest < ActiveJob::TestCase
  include InvocationHarness

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(@account)
  end

  test "an interrupted round retains its landed steer when resumed without another input" do
    run, input = start_steered_round
    pause_round(run)
    resume_round(run)

    assert_equal [Runs::InputComposition::ABORT_MARKER, "original plan", "keep the tests"],
      request_texts(round(run))
    assert_landing(run, [input], ["keep the tests"])
  end

  test "a resumed round appends new steers after the ones its earlier generation read" do
    run, first = start_steered_round
    pause_round(run)
    second = steer(run, "use Ruby")
    resume_round(run)

    assert_equal ["original plan", "keep the tests", "use Ruby"], request_texts(round(run))
    assert_landing(run, [first, second], ["keep the tests", "use Ruby"])

    # A repeated wake does not materialize either input a second time.
    schedule(run)
    assert_landing(run, [first, second], ["keep the tests", "use Ruby"])
  end

  test "an invocation automatic retry retains the directive from the failed request" do
    run, input = start_steered_round
    invocation = round(run).selected_model_invocation
    admitted = ModelInvocations::AdmitQueuedWork.call.admitted.find do |candidate|
      candidate.attempt.model_invocation_id == invocation.id
    end
    assert_not_nil admitted
    apply_via(admitted.attempt, json_response(503, { "error" => { "message" => "overloaded" } }))
    assert_equal "queued", invocation.reload.status
    invocation.update!(next_admission_at: nil)
    retried = ModelInvocations::AdmitQueuedWork.call.admitted.find do |candidate|
      candidate.attempt.model_invocation_id == invocation.id
    end
    assert_not_nil retried
    assert_equal 2, retried.attempt.ordinal
    assert_equal 0, round(run).execution_generation

    assert_equal ["original plan", "keep the tests"], request_texts(round(run))
    assert_landing(run, [input], ["keep the tests"])
  end

  test "an explicit retry after a halt retains the directive from the failed request" do
    run, input = start_steered_round
    fail_round(run)
    schedule(run)
    assert_equal "needs_attention", run.reload.status

    result = Runs::Tasks::Retry.call(Runs::Tasks::Retry::Command.new(
      run: run, task_key: "main", acting_user: @human
    ))
    assert_predicate result, :accepted?
    schedule(run)

    assert_equal ["original plan", "keep the tests"], request_texts(round(run))
    assert_landing(run, [input], ["keep the tests"])
  end

  private

    def start_steered_round
      run = seed(model("main", "prompt" => "original plan"))
      input = steer(run, "keep the tests")
      result = Runs::Start.call(Runs::Start::Command.new(
        run: run, acting_user: @human
      ))
      assert_predicate result, :accepted?
      schedule(run)
      assert_equal ["original plan", "keep the tests"], request_texts(round(run))
      assert_not Input.exists?(input.id)
      [run, input]
    end

    def steer(run, text)
      result = loop_input!(run, acting_user: @human, text: text)
      assert_predicate result, :accepted?
      result.value
    end

    def pause_round(run)
      result = Runs::Pause.call(Runs::Pause::Command.new(
        run: run, acting_user: @human, force: true
      ))
      assert_predicate result, :accepted?
      Runs::ConvergeTerminalSteps.call
      assert_equal "queued", round(run).status
      assert_equal 1, round(run).execution_generation
      clear_enqueued_jobs
    end

    def resume_round(run)
      result = Runs::Resume.call(Runs::Resume::Command.new(
        run: run, acting_user: @human
      ))
      assert_predicate result, :accepted?
      schedule(run)
    end

    def fail_round(run)
      invocation_id = round(run).selected_model_invocation_id
      admitted = ModelInvocations::AdmitQueuedWork.call.admitted.find do |candidate|
        candidate.attempt.model_invocation_id == invocation_id
      end
      assert_not_nil admitted
      apply_via(admitted.attempt, json_response(400, { "error" => { "message" => "bad request" } }))
      assert_equal "failed", ModelInvocation.find(invocation_id).status
      Runs::ConvergeTerminalSteps.call
      clear_enqueued_jobs
    end

    def schedule(run)
      Runs::ScheduleReady.call(run_id: run.id)
      clear_enqueued_jobs
    end

    def round(run) = run.tasks.find_by!(node_key: "main")

    def request_texts(node)
      node.invocation_body("request").content_body_entries.map do |entry|
        entry.content_fragment.payload.dig("parts", 0, "text")
      end
    end

    def assert_landing(run, inputs, texts)
      node = round(run)
      assert_equal texts, Runs::Steers::Landed.texts_by_round([node]).fetch(node.id)
      assert_empty run.inputs
      landed = run.event_items.where(item_type: "input_materialized")
      assert_equal inputs.map(&:public_id).sort,
        landed.map { |item| item.payload.fetch("input_public_id") }.sort
    end
end
