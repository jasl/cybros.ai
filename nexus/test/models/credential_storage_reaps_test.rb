require "test_helper"

# Device-authorization expiry and retention converge without becoming an
# authorization dependency.
class CredentialStorageReapsTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:cybros)
    @member = create_agent_member(account: @account, display_name: "Reaped", agent_identifier: "install-reap")
  end

  test "DeviceAuthorization.reap processes at most one bounded batch per invocation" do
    live = 3.times.map { mint_authorization }
    DeviceAuthorization.where(id: live.map(&:id)).update_all(expires_at: 1.minute.ago)

    old_terminal = 3.times.map { mint_authorization }
    DeviceAuthorization.where(id: old_terminal.map(&:id))
      .update_all(status: "canceled", updated_at: 8.days.ago)

    fresh_terminal = mint_authorization
    DeviceAuthorization.where(id: fresh_terminal.id)
      .update_all(status: "consumed", updated_at: 1.hour.ago)

    processed = 3.times.map { DeviceAuthorization.reap(batch_size: 2) }

    assert_equal [2, 2, 2], processed.map { |pass| pass[:scanned] }
    assert processed.all? { |result| result[:scanned] <= 2 }
    assert_equal 6, processed.sum { |result| result[:expired] + result[:deleted] }
    assert live.all? { |authorization| authorization.reload.expired? }
    assert old_terminal.none? { |authorization| DeviceAuthorization.exists?(authorization.id) }
    assert DeviceAuthorization.exists?(fresh_terminal.id), "recent terminal rows are retained"
    assert_equal 0, DeviceAuthorization.reap(batch_size: 2)[:scanned]
  end

  private

    def mint_authorization
      DeviceAuthorizations::Issue.call(
        account: @account, agent_identifier: "install-#{SecureRandom.hex(4)}",
        agent_display_name: "R",         requested_executor_display_name: "App").authorization
    end
end
