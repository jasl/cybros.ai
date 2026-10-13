require "test_helper"

class HandleChangesTest < ActionDispatch::IntegrationTest
  test "overlapping settings renames reserve the last released handle and narrate each committed change" do
    member = users(:member)
    sign_in_as member
    original = member.handle

    after_profile_load(member, scope_column: "account_id") do
      patch settings_profile_path, params: {
        profile: { display_name: "New display name", handle: "last-name" },
      }
    end

    assert_redirected_to settings_path
    assert_equal "New display name", member.reload.display_name
    assert_serial_renames(member, original: original)
  end

  test "overlapping steward renames reserve the last released handle and narrate each committed change" do
    owner = users(:owner)
    member = create_agent_member(steward: owner)
    sign_in_as owner
    original = member.handle

    after_profile_load(member, scope_column: "steward_id") do
      patch agent_handle_path(member.public_id), params: { handle: { handle: "last-name" } }
    end

    assert_redirected_to agent_path(member.public_id)
    assert_serial_renames(member, original: original)
  end

  private

    # Finish another rename after the request read its profile row. The
    # query result still contains the old handle, reproducing the stale
    # request image without relying on the timing of two HTTP threads.
    def after_profile_load(member, scope_column:)
      renamed = false
      subscriber = lambda do |*, payload|
        next if renamed || payload[:name] != "User Load"
        next unless payload[:sql].include?(%Q("users"."#{scope_column}" =))

        renamed = true
        member.update!(handle: "middle-name")
      end

      ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") { yield }
      assert renamed, "the competing rename must run after the controller's scoped profile read"
    end

    def assert_serial_renames(member, original:)
      assert_equal "last-name", member.reload.handle
      assert_equal "middle-name", member.previous_handle
      assert_equal [[original, "middle-name"], ["middle-name", "last-name"]],
        member.conversation_event_items.order(:sequence).map { |item| item.payload.values_at("old", "new") }

      other = users(:curator)
      assert_not other.update(handle: "middle-name"), "the last released name keeps its cooldown"
      assert_equal [:reserved], other.errors.details.fetch(:handle).map { |error| error.fetch(:error) }
    end
end
