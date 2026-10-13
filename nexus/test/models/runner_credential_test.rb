require "test_helper"

# A runner is a machine, not a principal, so its transport credential has no owning member at all —
# the address is the whole subject. Everything a member credential derives from its User must
# therefore be supplied independently or be absent by contract.
class RunnerCredentialTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:cybros)
    @runner = @account.task_executors.create!(
      executor_kind: :runner,
      display_name: "Workshop laptop",
      registration_identifier: "laptop-install",
      manager: users(:owner),
      assignment_scope: :user_private
    )
  end

  test "a runner's transport credential authenticates with no owning member" do
    minted = mint_runner_credential

    token = minted.token
    assert_nil token.user
    assert_predicate token, :executor_transport_plane?
    assert_equal @runner, token.task_executor
    assert token.executor_usable?
    assert_equal token, AccessToken.authenticate_executor_token(minted.secret)
    # There is no member plane to reach: the credential names an address.
    assert_not token.usable?
    assert_nil AccessToken.authenticate_token(minted.secret)
  end

  test "a member credential still requires its member" do
    orphan = @account.access_tokens.build(
      credential_plane: :member,
      name: "Orphan", source: :oauth_device,
      lookup_id: SecureRandom.base58(24), secret_digest: "seed",
      user_authority_generation: 0
    )

    assert_not orphan.valid?
    assert orphan.errors.of_kind?(:user, :blank)
  end

  test "a manager's removal leaves the runner's transport credential alone" do
    minted = mint_runner_credential
    users(:member).change_role(to: :admin)
    @account.transfer_ownership(to: users(:member).reload, by: users(:owner))

    # Removal waits for the departing Human's Workspace ownership, so the former owner hands both
    # fixtures over first.
    [workspaces(:shared), workspaces(:dedicated)].each do |workspace|
      result = Workspaces::TransferOwnership.call(
        workspace: workspace, by: users(:owner), to: users(:member),
        lock_version: workspace.lock_version
      )
      assert_equal :transferred, result.outcome
    end

    assert_equal :removed, users(:owner).reload.remove

    # The machine keeps finishing already-directed work; ending it is an
    # explicit revocation, which is what the manager surface exists for.
    assert minted.token.reload.executor_usable?
    assert_not @runner.reload.manager.active?, "the manager axis moved"
  end

  test "revoking the runner fences its transport credential immediately" do
    minted = mint_runner_credential

    assert_equal :revoked, @runner.revoke

    assert_not minted.token.reload.executor_usable?
    assert_nil AccessToken.authenticate_executor_token(minted.secret)
  end

  # A tools provider is a machine under the same identity model: transport only, no member, revoke
  # fences it the same way.
  test "a tools provider's transport credential is the runner's shape" do
    provider = @account.task_executors.create!(
      executor_kind: :tool_provider, display_name: "Provider box",
      registration_identifier: "provider-install", manager: users(:owner), assignment_scope: :user_private
    )
    minted = mint_runner_credential(provider)

    token = minted.token
    assert_nil token.user
    assert_predicate token, :executor_transport_plane?
    assert_equal token, AccessToken.authenticate_executor_token(minted.secret)
    assert_nil AccessToken.authenticate_token(minted.secret)

    assert_equal :revoked, provider.revoke
    assert_nil AccessToken.authenticate_executor_token(minted.secret)
  end

  private

    def mint_runner_credential(machine = @runner)
      family = @account.refresh_token_families.create!(
        access_token_name: "Runner connection",
        task_executor: machine,
        credential_epoch: machine.credential_epoch,
        last_used_at: Time.current
      )
      parts = AccessToken::DIGESTED.mint_parts
      token = @account.access_tokens.create!(
        refresh_token_family: family,
        credential_plane: :executor_transport,
        name: "Runner connection",
        source: :oauth_device,
        lookup_id: parts.lookup_id,
        secret_digest: parts.digest,
        expires_at: AccessToken::OAUTH_TTL.from_now,
        task_executor: machine,
        credential_epoch: machine.credential_epoch
      )

      AgentMembershipTestHelper::BoundCredential.new(token: token, secret: parts.raw)
    end
end
