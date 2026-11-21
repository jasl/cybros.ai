require "test_helper"

class RunCreateReceiptTest < ActiveSupport::TestCase
  test "the stored key is bounded in bytes" do
    run = Run.create!(workspace: workspaces(:shared), creating_user: users(:member), approval_mode: "bypass")
    receipt = RunCreateReceipt.new(account: run.account, workspace: run.workspace,
      creating_user: run.creating_user, run: run, request_digest: SecureRandom.hex(32),
      idempotency_key: "界" * 85)

    assert_predicate receipt, :valid?
    receipt.idempotency_key += "a"
    assert_not receipt.valid?
    assert receipt.errors.of_kind?(:idempotency_key, :too_long)
  end
end
