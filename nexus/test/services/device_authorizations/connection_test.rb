require "test_helper"

# Connection sessions. Every winning consume is a signed-in client, and an Agent is single-instance:
# the profile has at most one current delivery address, so connecting again re-pairs that address
# and supersedes the session that held it, rather than opening a second one beside it.
class DeviceAuthorizations::ConnectionTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:cybros)
    @owner = users(:owner)
  end

  def connect_and_consume(identifier: "shared-program", name: "App")
    grant = connect_only(identifier:, name:)
    DeviceAuthorizations::Consume.call(authorization: grant)
  end

  def connect_only(identifier: "shared-program", name: "App")
    grant = DeviceAuthorizations::Issue.call(
      account: @account, agent_identifier: identifier,
      agent_display_name: "Shared program",
      requested_executor_display_name: name).authorization
    DeviceAuthorizations::Connect.call(authorization: grant, connector: @owner)
    grant.reload
  end

  test "connecting a program twice re-pairs its one address under one profile" do
    desktop = connect_and_consume(name: "Desktop")
    laptop = connect_and_consume(name: "Laptop")

    # Both member credentials map to the same agent User, as they always did.
    assert_equal desktop.access_token.user, laptop.access_token.user
    profile = desktop.access_token.user

    # And to the same address, which is what changed: one agent, one place.
    address = desktop.executor_access_token.task_executor
    assert_equal 1, profile.task_executors.count
    assert_equal address, laptop.executor_access_token.task_executor
    assert_equal 2, address.reload.credential_epoch
    assert_equal "Laptop", address.display_name, "the newest connection names the address"
  end

  test "the re-paired connection fences the one it replaced, on both planes" do
    desktop = connect_and_consume(name: "Desktop")
    laptop = connect_and_consume(name: "Laptop")

    assert_nil AccessToken.authenticate_executor_token(desktop.executor_access_secret),
      "the epoch advance fences the previous transport credential"
    assert_nil AccessToken.authenticate_token(desktop.access_secret),
      "the superseded lineage takes the previous member credential with it"

    assert AccessToken.authenticate_token(laptop.access_secret)
    assert AccessToken.authenticate_executor_token(laptop.executor_access_secret)
  end

  test "a connected grant cannot take the address back after another grant wins" do
    first = connect_and_consume(identifier: "pairing-winner", name: "First")
    profile = first.access_token.user
    older = connect_only(identifier: "pairing-winner", name: "Older")
    newer = connect_only(identifier: "pairing-winner", name: "Newer")

    winner = DeviceAuthorizations::Consume.call(authorization: newer)
    loser = DeviceAuthorizations::Consume.call(authorization: older)

    assert_equal :minted, winner.outcome
    assert_equal :access_denied, loser.outcome
    assert older.reload.invalidated?
    assert_equal winner.access_token, AccessToken.authenticate_token(winner.access_secret)
    assert_equal winner.executor_access_token,
      AccessToken.authenticate_executor_token(winner.executor_access_secret)
    assert_equal "Newer", TaskExecutor.address_for(profile).display_name
  end

  test "revoke makes an already connected grant stale and a fresh ceremony can reconnect" do
    first = connect_and_consume(identifier: "revoked-pairing", name: "First")
    profile = first.access_token.user
    old_address = first.executor_access_token.task_executor
    stale = connect_only(identifier: "revoked-pairing", name: "Stale")

    assert_equal :revoked, profile.revoke_connection

    assert_no_difference -> { TaskExecutor.count } do
      result = DeviceAuthorizations::Consume.call(authorization: stale)
      assert_equal :access_denied, result.outcome
    end
    assert stale.reload.invalidated?
    assert_predicate old_address.reload, :revoked?

    fresh = connect_only(identifier: "revoked-pairing", name: "Fresh")
    replacement = DeviceAuthorizations::Consume.call(authorization: fresh)

    assert_equal :minted, replacement.outcome
    assert_not_equal old_address, replacement.executor_access_token.task_executor
    assert_equal "Fresh", TaskExecutor.address_for(profile).display_name
  end

  test "an absent-address snapshot cannot revive a replacement after it is revoked" do
    first = connect_and_consume(identifier: "absent-pairing", name: "First")
    profile = first.access_token.user
    assert_equal :revoked, profile.revoke_connection

    stale = connect_only(identifier: "absent-pairing", name: "Stale")
    newer = connect_only(identifier: "absent-pairing", name: "Newer")
    winner = DeviceAuthorizations::Consume.call(authorization: newer)
    assert_equal :minted, winner.outcome
    assert_equal :revoked, profile.revoke_connection

    assert_no_difference -> { TaskExecutor.count } do
      loser = DeviceAuthorizations::Consume.call(authorization: stale)
      assert_equal :access_denied, loser.outcome
    end
    assert stale.reload.invalidated?

    fresh = connect_only(identifier: "absent-pairing", name: "Fresh")
    replacement = DeviceAuthorizations::Consume.call(authorization: fresh)
    assert_equal :minted, replacement.outcome
    assert_equal "Fresh", TaskExecutor.address_for(profile).display_name
  end

  # The address is the profile's and outlives any one session, so supersession must not take it down
  # — only the steward's revoke does.
  test "supersession keeps the address alive; revoking credentials ends it" do
    desktop = connect_and_consume(name: "Desktop")
    profile = desktop.access_token.user
    address = desktop.executor_access_token.task_executor

    connect_and_consume(name: "Laptop")
    assert_predicate address.reload, :active?
    assert_equal address, TaskExecutor.address_for(profile)

    assert_equal :revoked, profile.revoke_connection
    assert_predicate address.reload, :revoked?
    assert_nil TaskExecutor.address_for(profile)
  end

  # The name a client gave itself lives on the address, once. A lineage used
  # to freeze its own copy for a world where several lineages shared a profile
  # and each needed its own label; with one address per profile, written and
  # renamed by the same consume, the copy could only ever agree with it.
  test "a connection is named by the address it re-paired" do
    result = connect_and_consume(name: "Desktop")

    assert_equal "Desktop", result.executor_access_token.task_executor.display_name
    assert_equal "Desktop", result.access_token.refresh_token_family.task_executor.display_name
  end

  # Supersession is total, with no carve-out to reason about: every agent connection carries an
  # address, so every live lineage of a profile is one the next connection replaces.
  test "supersession spares nothing, because there is no addressless lineage" do
    first = connect_and_consume(name: "Desktop")
    profile = first.access_token.user

    connect_and_consume(name: "Laptop")

    assert_equal 1, profile.refresh_token_families.live.count
    assert_nil AccessToken.authenticate_token(first.access_secret)
  end
end
