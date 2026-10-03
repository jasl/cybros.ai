module AgentMembershipTestHelper
  BoundCredential = Data.define(:token, :secret)

  # Advance an executor's credential epoch the way a winning reconnect consume does: one model-owned
  # transition that fences every older-epoch credential. There is no external epoch-management
  # command.
  def advance_credential_epoch(executor)
    executor.re_pair(display_name: executor.display_name)
  end

  # A stewarded agent member without repeating the kind/role/steward kwargs at
  # every call site. Every ordinary Agent starts with its exact program
  # identifier; tests that assert it pass an explicit stable value.
  def create_agent_member(account: accounts(:cybros), steward: users(:owner),
                          display_name: "Agent",
                          agent_identifier: "install-#{SecureRandom.hex(8)}")
    account.users.create!(
      kind: :agent, role: :member, steward: steward,
      display_name: display_name, agent_identifier: agent_identifier
    )
  end

  # One completed device connection, driven through the real services so a management-surface test
  # works with the same session/address shape a real client leaves behind.
  def connect_agent_session(steward:, agent_identifier:, device_name: "Desktop",
                            display_name: "Shared program")
    grant = DeviceAuthorizations::Issue.call(
      account: steward.account, agent_identifier: agent_identifier,
      agent_display_name: display_name,
      requested_executor_display_name: device_name
    ).authorization
    DeviceAuthorizations::Connect.call(authorization: grant, connector: steward)
    DeviceAuthorizations::Consume.call(authorization: grant.reload)
  end

  # The combined shape A+B (r-modes M2): one ceremony that pairs the agent's
  # address AND a private runner under the connecting human — rho in full mode.
  def connect_combined_session(steward:, agent_identifier:, runner_identifier: "rho",
                               device_name: "Desktop", display_name: "Shared program")
    grant = DeviceAuthorizations::Issue.call(
      account: steward.account, agent_identifier: agent_identifier,
      agent_display_name: display_name,
      requested_executor_display_name: device_name,
      runner_identifier: runner_identifier, runner_display_name: device_name
    ).authorization
    DeviceAuthorizations::Connect.call(authorization: grant, connector: steward)
    DeviceAuthorizations::Consume.call(authorization: grant.reload)
  end

  # Branch B for either machine kind: a runner by default, a tools provider
  # when `executor_kind:` says so — the same ceremony, the requested kind.
  def connect_runner(manager:, runner_identifier: "workshop-install",
                     display_name: "Workshop laptop", assignment_scope: :user_private,
                     executor_kind: :runner)
    existing = TaskExecutor.runner_for(
      account_id: manager.account_id,
      manager_id: manager.id,
      runner_identifier: runner_identifier
    )
    grant = DeviceAuthorizations::Issue.call(
      account: manager.account, runner_identifier: runner_identifier,
      runner_display_name: display_name, requested_executor_kind: executor_kind.to_s
    ).authorization
    DeviceAuthorizations::Connect.call(
      authorization: grant,
      connector: manager,
      account_wide: assignment_scope.to_s == "account_wide",
      expected_live_runner:
        DeviceAuthorizations::Connect.live_runner_precondition(existing)
    )
    DeviceAuthorizations::Consume.call(authorization: grant.reload)
  end

  # A device-connected executor credential fixture for authentication and
  # fencing tests. Production issuance remains owned by Device Flow consume.
  def create_bound_credential(executor:, name: "Bound")
    member = executor.agent_profile
    family = member.refresh_token_families.create!(
      account: member.account,
      access_token_name: name,
      task_executor: executor,
      credential_epoch: executor.credential_epoch,
      user_authority_generation: member.authority_generation,
      last_used_at: Time.current
    )
    parts = AccessToken::DIGESTED.mint_parts
    token = member.access_tokens.create!(
      refresh_token_family: family,
      credential_plane: :executor_transport,
      name: name,
      source: :oauth_device,
      lookup_id: parts.lookup_id,
      secret_digest: parts.digest,
      expires_at: AccessToken::OAUTH_TTL.from_now,
      task_executor: executor,
      credential_epoch: executor.credential_epoch,
      user_authority_generation: member.authority_generation
    )

    BoundCredential.new(token: token, secret: parts.raw)
  end
end
