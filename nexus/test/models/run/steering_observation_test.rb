require "test_helper"

class Run::SteeringObservationTest < ActiveJob::TestCase
  setup do
    @human = users(:member)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(accounts(:cybros))
    @conversation = Conversation.create!(workspace: @workspace, creating_user: @human)
    @seam = create_run_backed_turn(conversation: @conversation, acting_user: @human)
  end

  test "a current guarded input proves acceptance and waiting even while its run is paused" do
    input = accept!
    @seam.run.update!(status: "paused")

    observation = observe(input.public_id)

    assert_equal input, observation.input
    assert_predicate observation, :accepted?
    assert_predicate observation, :waiting?
    assert_not observation.consumed?
    assert_not observation.canceled?
    assert_nil observation.task
  end

  test "consumption links the exact task on the original run after the displayed execution changes" do
    input = accept!
    grow!(@seam.run, model("consume"))
    Runs::ScheduleReady.call(run_id: @seam.run.id)
    task = @seam.run.tasks.find_by!(node_key: "consume")
    assert_not Input.exists?(input.id)
    replacement = replace_run
    grow!(replacement, model("consume"))

    observation = observe(input.public_id)

    assert_nil observation.input
    assert_predicate observation, :accepted?
    assert_predicate observation, :consumed?
    assert_not observation.waiting?
    assert_not observation.canceled?
    assert_equal task, observation.task
    assert_equal @seam.variant, observation.task.run.variant
  end

  test "cancellation is proved by the guarded deletion event" do
    input = accept!
    outcome = Conversations::Inputs::Destroy.call(Conversations::Inputs::Destroy::Command.new(
      host: @conversation, acting_user: @human, input_public_id: input.public_id))
    assert_predicate outcome, :accepted?

    observation = observe(input.public_id)

    assert_nil observation.input
    assert_predicate observation, :accepted?
    assert_predicate observation, :canceled?
    assert_not observation.waiting?
    assert_not observation.consumed?
    assert_nil observation.task
  end

  test "acceptance alone never proves what happened after the input disappeared" do
    input = accept!
    input.destroy!

    observation = observe(input.public_id)

    assert_predicate observation, :accepted?
    assert_not observation.waiting?
    assert_not observation.consumed?
    assert_not observation.canceled?

    EventItem.where(host: @conversation).delete_all
    assert_no_evidence(observe(input.public_id))
  end

  test "missing evidence and evidence on another host remain unknown" do
    public_id = SecureRandom.uuid_v7
    assert_no_evidence(observe(public_id))
    other = Conversation.create!(workspace: @workspace, creating_user: @human)
    append("input_accepted", public_id, host: other, key: public_id,
      expected_steering_run_public_id: @seam.run.public_id)
    append("input_materialized", public_id, host: other,
      run_public_id: @seam.run.public_id, task_key: "consume")

    assert_no_evidence(observe(public_id))
  end

  test "current unguarded inputs and inputs guarded to another run are outside the observation" do
    input = accept!
    other = replace_run
    assert_raises(ActiveRecord::RecordNotFound) { observe(input.public_id, run: other) }

    unguarded = accept!(target: nil)
    assert_raises(ActiveRecord::RecordNotFound) { observe(unguarded.public_id, run: other) }
  end

  test "explicit acceptance and terminal targets on another run are concealed" do
    other_id = SecureRandom.uuid_v7
    accepted_id = SecureRandom.uuid_v7
    append("input_accepted", accepted_id, key: accepted_id, expected_steering_run_public_id: other_id)
    consumed_id = SecureRandom.uuid_v7
    append("input_materialized", consumed_id, run_public_id: other_id, task_key: "consume")
    canceled_id = SecureRandom.uuid_v7
    append("input_deleted", canceled_id, expected_steering_run_public_id: other_id, steer_canceled: true)

    [accepted_id, consumed_id, canceled_id].each do |public_id|
      assert_raises(ActiveRecord::RecordNotFound) { observe(public_id) }
    end
  end

  test "old acceptance sender identity and unguarded deletion do not establish a target" do
    accepted_id = SecureRandom.uuid_v7
    append("input_accepted", accepted_id, key: accepted_id, run_public_id: @seam.run.public_id)
    canceled_id = SecureRandom.uuid_v7
    append("input_deleted", canceled_id, steer_canceled: true)

    assert_no_evidence(observe(accepted_id))
    assert_no_evidence(observe(canceled_id))
  end

  test "ordinary queued materialization does not prove a correction entered a model request" do
    public_id = SecureRandom.uuid_v7
    append("input_materialized", public_id, run_public_id: @seam.run.public_id,
      turn_public_id: @seam.turn.public_id, variant_public_id: @seam.variant.public_id)

    assert_no_evidence(observe(public_id))
  end

  test "retained exact consumption remains evidence without acceptance or a surviving task" do
    public_id = SecureRandom.uuid_v7
    append("input_materialized", public_id, run_public_id: @seam.run.public_id, task_key: "expired")

    observation = observe(public_id)

    assert_predicate observation, :accepted?
    assert_predicate observation, :consumed?
    assert_not observation.waiting?
    assert_not observation.canceled?
    assert_nil observation.task
    EventItem.where(host: @conversation).delete_all
    assert_no_evidence(observe(public_id))
  end

  private

    def replace_run
      @seam.variant.update!(status: "completed")
      variant = @seam.turn.variants.create!(position: 1, status: "running", source: "run",
        origin_variant: @seam.variant)
      @seam.turn.update!(active_variant: variant)
      variant.create_run!(workspace: @workspace, creating_user: @human,
        status: "running", approval_mode: "bypass")
    end

    def accept!(target: @seam.run.public_id)
      outcome = Conversations::Inputs::Create.call(Conversations::Inputs::Create::Command.new(
        host: @conversation, acting_user: @human, kind: "message", role: "user",
        entries: [{ "text" => "change course" }], visible_in_context: true,
        delivery_mode: "steer", context_mode: nil, context_options: nil,
        expected_context_revision: nil, expected_tail_turn_public_id: nil,
        expected_steering_run_public_id: target,
        provider_id: nil, model_ref: nil, reasoning_effort: nil, request_options: nil))
      assert_predicate outcome, :accepted?
      outcome.value
    end

    def observe(public_id, run: @seam.run)
      Run::SteeringObservation.new(run: run, input_public_id: public_id)
    end

    def append(type, public_id, host: @conversation, key: SecureRandom.uuid_v7, **payload)
      Event::Append.call(host: host, idempotency_key: key,
        items: [{ type: type, payload: payload.stringify_keys.merge("input_public_id" => public_id) }])
    end

    def assert_no_evidence(observation)
      assert_nil observation.input
      assert_nil observation.task
      assert_not observation.accepted?
      assert_not observation.waiting?
      assert_not observation.consumed?
      assert_not observation.canceled?
    end
end
