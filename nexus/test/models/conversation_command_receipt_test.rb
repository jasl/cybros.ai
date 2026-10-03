require "test_helper"

class ConversationCommandReceiptTest < ActiveSupport::TestCase
  test "metadata operation receipts retain their response size bound" do
    receipt = ConversationCommandReceipt.new(
      account: accounts(:cybros), workspace: workspaces(:shared), acting_user: users(:member),
      operation: "conversation_create", idempotency_key: "oversized-response",
      request_digest: SecureRandom.hex(32), response_status: 201,
      response_body: { "text" => "x" * Nexus::SizeBounds.fetch(:workspace_command_response_bound) }
    )

    assert_not receipt.valid?
    assert receipt.errors.of_kind?(:response_body, :content_too_large)
  end
end
