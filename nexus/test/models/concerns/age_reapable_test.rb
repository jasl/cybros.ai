require "test_helper"

class AgeReapableTest < ActiveSupport::TestCase
  REAPERS = [
    AgentLoopAppendReceipt, AgentLoopCreateReceipt, ConversationCommandReceipt,
    ConversationEventItem, OneShotCreateReceipt, WorkspaceCommandReceipt,
  ].freeze

  test "the six age reapers share one idiom and each names its retention" do
    REAPERS.each do |model|
      assert_includes model.ancestors, AgeReapable, model.name
      assert_kind_of ActiveSupport::Duration, model::RETENTION, model.name
      assert_equal AgeReapable::ClassMethods, model.method(:reap).owner, "#{model.name} redefines reap"
    end
  end

  test "reap deletes past the retention window, oldest first, and leaves young rows alone" do
    old, older, young = %w[old older young].map { |key| receipt(key) }
    WorkspaceCommandReceipt.where(id: old.id).update_all(created_at: 25.hours.ago)
    WorkspaceCommandReceipt.where(id: older.id).update_all(created_at: 26.hours.ago)

    assert_equal 1, WorkspaceCommandReceipt.reap(batch: 1)
    assert_not WorkspaceCommandReceipt.exists?(older.id)
    assert_equal 1, WorkspaceCommandReceipt.reap
    assert_equal 0, WorkspaceCommandReceipt.reap
    assert WorkspaceCommandReceipt.exists?(young.id)
  end

  private

    def receipt(key)
      WorkspaceCommandReceipt.create!(
        account: workspaces(:shared).account, workspace: workspaces(:shared), acting_user: users(:member),
        operation: "workspace_create", idempotency_key: key, request_digest: SecureRandom.hex(32),
        response_status: 201, response_body: { "ok" => true }
      )
    end
end
