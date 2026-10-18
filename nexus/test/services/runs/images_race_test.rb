require "test_helper"
require_relative "../../test_helpers/row_lock_test_helper"

class Runs::ImagesRaceTest < ActiveSupport::TestCase
  include RowLockTestHelper
  include InvocationHarness

  self.use_transactional_tests = false

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    DevModelLane.ensure_enabled!(@account)
    created = create_loop(model("picture", "workload" => "image_generation", "model" => { "model" => "dev/mock-image" }),
      workspace: workspaces(:shared), creating_user: @human, default_runner_executor_public_id: nil)
    assert_predicate created, :created?
    @run = created.run
    Runs::Start.call(Runs::Start::Command.new(run: @run, acting_user: @human))
    Runs::ScheduleReady.call(run_id: @run.id)
    ModelInvocations::AdmitQueuedWork.call
    @invocation = @run.tasks.sole.selected_model_invocation
    apply_via(@invocation.attempts.last, json_response(200, {
      "created" => 0, "data" => [{ "b64_json" => [png_bytes].pack("m0") }],
    }))
  end

  teardown do
    release_row_lock(@held) if @held
    stop_database_call(@call) if @call
    Runs::Reap.destroy_aggregate(@run.reload) if @run
    UsageRecord.where(model_invocation_public_id: @invocation.public_id).delete_all if @invocation
  end

  test "a creator lock can stop the run while image publication waits without inverting the FK edge" do
    @held = hold_row_lock(User, @human.id, before_commit: ->(creator) {
      Runs::Stop.call(Runs::Stop::Command.forced(run: Run.find(@run.id), acting_user: creator))
    })
    @call = start_database_call { Runs::ConvergeTerminalSteps.call(invocation_id: @invocation.id) }
    wait_until_transitively_blocked_by(@held.pid, @call.pid)
    release_row_lock(@held)
    @held = nil
    finish_database_call(@call)
    @call = nil
    assert_equal "canceled", @run.tasks.sole.status
    assert_nil @run.tasks.sole.output_body
    assert_equal 0, ContentUpload.joins(:content_bodies).where(content_bodies: { task_id: @run.tasks.select(:id) }).count
  end
end
