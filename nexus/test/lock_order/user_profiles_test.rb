require "test_helper"
require_relative "../test_helpers/lock_order_test_helper"

class UserProfilesLockOrderTest < ActionDispatch::IntegrationTest
  include LockOrderTestHelper

  test "settings rename locks the User before its narration cursor" do
    member = users(:member)
    sign_in_as member

    sequences = assert_ladder_order("settings rename") do
      patch settings_profile_path, params: { profile: { handle: "renamed-member" } }
      assert_redirected_to settings_path
    end

    assert_equal "renamed-member", member.reload.handle
    assert_equal %w[users conversation_event_cursors], sequences.flatten.uniq
  end

  test "steward rename locks the Agent Profile before its narration cursor" do
    owner = users(:owner)
    member = create_agent_member(steward: owner)
    sign_in_as owner

    sequences = assert_ladder_order("steward rename") do
      patch agent_handle_path(member.public_id), params: { handle: { handle: "renamed-agent" } }
      assert_redirected_to agent_path(member.public_id)
    end

    assert_equal "renamed-agent", member.reload.handle
    assert_equal %w[users conversation_event_cursors], sequences.flatten.uniq
  end
end
