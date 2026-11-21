require "test_helper"
require_relative "../test_helpers/row_lock_test_helper"

class SsoProviderManagementTest < ActiveSupport::TestCase
  include RowLockTestHelper
  uses_transaction :test_concurrent_disables_leave_an_enabled_login_method,
    :test_policy_enforcement_and_unlink_cannot_both_remove_the_final_login_method

  test "concurrent disables leave an enabled login method" do
    account = accounts(:cybros)
    providers = %w[first second].map do |name|
      account.sso_providers.create!(name: name, protocol: "oidc", issuer: "https://#{name}.example.test",
        enabled: true, tested_at: Time.current).tap do |provider|
        account.users.active.where(kind: :human).each do |user|
          provider.sso_connections.create!(identity: user.identity, subject: user.public_id)
        end
      end
    end
    assert SsoProvider.set_policy(account, sso_only: true)
    held = hold_row_lock(Account, account.id)
    calls = providers.map do |provider|
      start_database_call { SsoProvider.find(provider.id).set_enabled(false, expected_version: provider.lock_version) }
    end
    wait_until_waiting_on_lock(*calls.map(&:pid))
    release_row_lock(held)
    assert_equal [false, true], calls.map { |call| finish_database_call(call) }.sort_by(&:to_s)
    assert_equal 1, account.sso_providers.where(enabled: true).count
    assert_empty SsoProvider.uncovered_users(account, sso_only: true)
  ensure
    release_row_lock(held) if held&.thread&.alive?
    calls&.each { |call| stop_database_call(call) }
    account&.update!(sso_only: false)
    providers&.each { |provider| provider.reload.destroy! }
  end

  test "policy enforcement and unlink cannot both remove the final login method" do
    account = accounts(:cybros)
    provider = account.sso_providers.create!(name: "Corporate", protocol: "oidc", issuer: "https://corporate.example.test",
      enabled: true, tested_at: Time.current)
    account.users.active.where(kind: :human).each do |user|
      provider.sso_connections.create!(identity: user.identity, subject: user.public_id)
    end
    binding = provider.sso_connections.find_by!(identity: users(:owner).identity)
    held = hold_row_lock(Account, account.id)
    enforce = start_database_call { SsoProvider.set_policy(Account.find(account.id), sso_only: true) }
    unlink = start_database_call { SsoConnection.find(binding.id).disconnect }
    wait_until_waiting_on_lock(enforce.pid, unlink.pid)
    release_row_lock(held)
    enforced = finish_database_call(enforce)
    assert_equal !enforced, finish_database_call(unlink)
    assert_equal enforced, account.reload.sso_only?
    assert_equal enforced, SsoConnection.exists?(binding.id)
  ensure
    release_row_lock(held) if held&.thread&.alive?
    [enforce, unlink].compact.each { |operation| stop_database_call(operation) }
    account&.update!(sso_only: false)
    provider&.reload&.destroy!
  end

  test "tightening admission keeps the old group live until affected members have another sign-in method" do
    account = accounts(:cybros)
    provider = account.sso_providers.create!(name: "Staff", protocol: "oidc", issuer: "https://staff.example.test",
      client_id: "client", client_secret: "secret", enabled: true, tested_at: Time.current, admission_version: 1)
    member = users(:member)
    binding = provider.sso_connections.create!(identity: member.identity, subject: "42", admission_version: 1)
    member.identity.update_column(:password_digest, nil)
    assert provider.save_settings({ required_group: "company" }, expected_version: provider.lock_version)
    account.with_lock { refute provider.accept_test(expected_version: provider.lock_version) }
    assert_nil provider.reload.required_group
    assert SsoConnection.available.exists?(binding.id)
    member.identity.update_column(:password_digest, users(:owner).identity.password_digest)
    account.with_lock { assert provider.accept_test(expected_version: provider.lock_version) }
    assert_equal "company", provider.reload.required_group
    assert binding.reload
    refute SsoConnection.available.exists?(binding.id)
  end

  test "unlink rechecks a mixed-mode preview under the policy committed since then" do
    account = accounts(:cybros)
    provider = account.sso_providers.create!(name: "Staff", protocol: "oidc", issuer: "https://staff.example.test", enabled: true)
    connection = provider.sso_connections.create!(identity: users(:member).identity, subject: "42")
    assert connection.removable?
    Account.find(account.id).update!(sso_only: true)
    refute connection.disconnect
    assert connection.reload
  end
end
