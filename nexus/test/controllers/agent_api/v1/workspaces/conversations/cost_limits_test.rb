require "test_helper"
require_relative "../../../../../test_helpers/conversation_api_test_helper"

class AgentAPI::V1::Workspaces::Conversations::CostLimitsTest < ActionDispatch::IntegrationTest
  include ConversationAPITestHelper

  setup { @account.update!(cost_unit: "USD") }

  test "create includes the limit in its idempotency envelope and full projection" do
    post conversations_path, headers: auth("limited"), as: :json,
      params: { conversation: { cost_limit: "0.125" } }
    assert_response :created
    detail = response.parsed_body.fetch("conversation")
    assert_equal "0.125", detail.fetch("cost_limit")
    assert_equal false, detail.fetch("cost_limit_reached")

    post conversations_path, headers: auth("limited"), as: :json,
      params: { conversation: { cost_limit: "0.125" } }
    assert_response :created
    assert_equal detail.fetch("public_id"), response.parsed_body.dig("conversation", "public_id")

    post conversations_path, headers: auth("limited"), as: :json,
      params: { conversation: { cost_limit: nil } }
    assert_response :conflict
    assert_equal "idempotency_envelope_mismatch", response.parsed_body.dig("error", "code")

    get conversations_path, headers: auth
    assert_not response.parsed_body.fetch("conversations").sole.key?("cost_limit"), "lists remain lean"
  end

  test "patch distinguishes omission from null and retains optimistic conflict handling" do
    conversation = create_conversation!
    patch_limit(conversation, "0")
    assert_response :success
    detail = response.parsed_body.fetch("conversation")
    assert_equal "0.0", detail.fetch("cost_limit")
    assert_equal true, detail.fetch("cost_limit_reached")

    patch conversation_path(conversation), headers: auth, as: :json,
      params: { conversation: { title: "Edited", lock_version: detail.fetch("lock_version") } }
    assert_response :success
    assert_equal "0.0", response.parsed_body.dig("conversation", "cost_limit")

    patch conversation_path(conversation), headers: auth, as: :json,
      params: { conversation: { cost_limit: "10", lock_version: detail.fetch("lock_version") } }
    assert_response :conflict
    assert_equal "stale_object", response.parsed_body.dig("error", "code")
    assert_equal 0.to_d, conversation.reload.cost_limit

    patch_limit(conversation, nil)
    assert_response :success
    assert_nil response.parsed_body.fetch("conversation").fetch("cost_limit")
    assert_equal false, response.parsed_body.dig("conversation", "cost_limit_reached")
  end

  test "invalid amounts and absent cost units fail without mutating the row" do
    conversation = create_conversation!
    ["invalid", "NaN", "Infinity", "-1", "1e20", "1e-19", ""].each do |amount|
      patch_limit(conversation, amount)
      assert_response :unprocessable_entity
      assert_equal "validation_failed", response.parsed_body.dig("error", "code")
      assert_nil conversation.reload.cost_limit
    end
    @account.update!(cost_unit: nil)
    patch_limit(conversation, "1")
    assert_response :unprocessable_entity
  end

  test "archive keeps cost-only repair writable while ordinary edits stay refused" do
    conversation = create_conversation!
    conversation.update!(archived_at: Time.current, cost_limit: "0")
    patch conversation_path(conversation), headers: auth, as: :json,
      params: { conversation: { cost_limit: "2", ignored: "unchanged", lock_version: conversation.lock_version } }
    assert_response :success
    assert_equal "2.0", response.parsed_body.dig("conversation", "cost_limit")

    patch conversation_path(conversation), headers: auth, as: :json,
      params: { conversation: { cost_limit: nil, title: "renamed", lock_version: conversation.reload.lock_version } }
    assert_response :conflict
    assert_equal "conversation_archived", response.parsed_body.dig("error", "code")
    assert_equal "2.0", conversation.reload.cost_limit.to_s("F")
    patch_limit(conversation, nil)
    assert_response :success
    assert conversation.reload.archived?
  end

  test "the cap follows existing full read and concealed access for another member" do
    conversation = create_conversation!
    @token = create_access_token_fixture(user: users(:curator), name: "Participant")
    %w[full read none].zip([200, 403, 404]).each do |level, status|
      conversation.reload.update!(access_default: level)
      patch_limit(conversation, "3")
      assert_response status
    end
    assert_equal 3.to_d, conversation.reload.cost_limit
  end

  private

    def patch_limit(conversation, value)
      patch conversation_path(conversation), headers: auth, as: :json,
        params: { conversation: { cost_limit: value, lock_version: conversation.reload.lock_version } }
    end
end
