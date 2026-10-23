require "test_helper"
require_relative "../../test_helpers/row_lock_test_helper"

class InferenceRequests::CreateConcurrencyTest < ActiveSupport::TestCase
  include RowLockTestHelper
  include RunLaneTestHelper
  include ActiveJob::TestHelper

  self.use_transactional_tests = false

  setup do
    @account = accounts(:cybros)
    @workspace = workspaces(:shared)
    @creator = create_agent_member
    DevModelLane.ensure_enabled!(@account)
    declare_tools!(@creator)
    @conversation = Conversation.create!(workspace: @workspace, creating_user: @creator)
    post_input!(@conversation, acting_user: @creator, kind: "direct_reply", text: "Plan the project",
      provider_id: "dev", model_ref: "mock-text")
  end

  teardown do
    if @creator
      InferenceRequestCreateReceipt.where(acting_user: @creator).delete_all
      InferenceRequest.where(creating_user: @creator).destroy_all
      Run.where(creating_user: @creator).find_each { |run| Runs::Reap.destroy_aggregate(run) }
      destroy_memory_owner!(@conversation&.reload)
      @creator.with_lock do
        MemoryCollections::Drain.call(owner: @creator, budget: 64)
      end
      Speaker.where(user: @creator).destroy_all
      @creator.destroy!
      ContentFragment.where.missing(:content_body_entries).delete_all
    end
  end

  test "a conversation reply and an independent inference request can be created together" do
    turn_inserted = Queue.new
    continue_materialization = Queue.new
    materializing = start_database_call do
      owner = Thread.current
      pause_after_turn = lambda do |_name, _started, _finished, _id, payload|
        if Thread.current == owner && payload.fetch(:sql).start_with?('INSERT INTO "turns"')
          # The real turn insert already holds KEY SHARE on its author through
          # the FK. Its backing Run will next reference the same Workspace.
          turn_inserted << true
          continue_materialization.pop
        end
      end
      ActiveSupport::Notifications.subscribed(pause_after_turn, "sql.active_record") do
        Conversations::Inputs::ApplyNext.call(conversation_id: @conversation.id)
      end
    end
    Timeout.timeout(RowLockTestHelper::ROW_LOCK_WAIT_TIMEOUT) { turn_inserted.pop }

    creating = start_database_call { create_inference_request }
    wait_until_transitively_blocked_by(materializing.pid, creating.pid)
    continue_materialization << true

    reply = finish_database_call(materializing)
    materializing = nil
    inference = finish_database_call(creating)
    creating = nil

    assert_predicate reply, :accepted?
    assert_predicate inference, :created?
    assert_equal "running", reply.value.active_variant.run.status
    assert_equal "queued", InferenceRequest.find_by!(
      public_id: inference.accepted.fetch("inference_request_public_id")
    ).model_invocation.status
    assert_equal 1, Run.where(creating_user: @creator).count
    assert_equal 1, InferenceRequest.where(creating_user: @creator).count
  ensure
    continue_materialization << true if continue_materialization
    stop_database_call(materializing) if materializing
    stop_database_call(creating) if creating
  end

  private

    def create_inference_request
      command = InferenceRequests::Create::Command.new(
        workspace: Workspace.find(@workspace.id), creating_user: User.find(@creator.id),
        workload: "text_generation", submitted: DevModelLane.submission_for("text_generation"),
        configuration: {}, input: "Name the project", upload_public_ids: [],
        billing_subject: nil, idempotency_key: SecureRandom.uuid
      )
      InferenceRequests::Create.call(command: command, port: DevModelLane.port)
    end
end
