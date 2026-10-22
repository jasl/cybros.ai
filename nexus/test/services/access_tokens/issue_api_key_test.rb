require "test_helper"

class AccessTokensIssueAPIKeyTest < ActiveSupport::TestCase
  setup do
    @owner = users(:owner)
    @agent = @owner.build_agent(display_name: "Key application")
    @agent.save!
  end

  test "member keys have independent revocation and no expiry or refresh family" do
    first = issue_member("First")
    second = issue_member("Second")

    assert_equal :issued, first.outcome
    assert_predicate first.token, :api_key?
    assert_nil first.token.expires_at
    assert_nil first.token.refresh_token_family
    assert_nil first.token.executor
    assert_nil first.token.identity_recovery_generation
    assert_no_match(/#{Regexp.escape(first.secret.split(".").last)}/, first.token.attributes.values.join(" "))
    travel 5.years do
      assert_equal first.token, AccessToken.authenticate_token(first.secret)
    end
    AccessTokens::Revoke.call(first.token)
    assert_nil AccessToken.authenticate_token(first.secret)
    assert_equal second.token, AccessToken.authenticate_token(second.secret)
    assert_nil AccessToken.authenticate_executor_token(second.secret)
    assert_nil AccessToken.authenticate_platform_token(second.secret)
  end

  test "executor keys reuse the one address and preserve the other keys and member access" do
    member = issue_member("Member")
    first = AccessTokens::IssueAgentExecutorKey.call(agent: @agent, name: "First executor")
    address = first.token.executor
    epoch = address.credential_epoch
    second = AccessTokens::IssueAgentExecutorKey.call(agent: @agent, name: "Second executor")

    assert_equal :issued, first.outcome
    assert_equal address, second.token.executor
    assert_equal epoch, address.reload.credential_epoch
    assert_equal 1, @agent.executors.live.count
    assert_nil first.token.refresh_token_family
    assert_nil first.token.expires_at
    assert_nil AccessToken.authenticate_token(first.secret)
    assert_equal first.token, AccessToken.authenticate_executor_token(first.secret)
    AccessTokens::Revoke.call(first.token)
    assert_nil AccessToken.authenticate_executor_token(first.secret)
    assert_equal second.token, AccessToken.authenticate_executor_token(second.secret)
    assert_equal member.token, AccessToken.authenticate_token(member.secret)
  end

  test "independent runner keys are transport credentials with no Agent member subject" do
    runner = connect_runner(manager: @owner).executor_access_token.executor
    first = AccessTokens::IssueAPIKey.call(user: nil, executor: runner, name: "First")
    second = AccessTokens::IssueAPIKey.call(user: nil, executor: runner, name: "Second")

    assert_equal :issued, first.outcome
    assert_nil first.token.user
    assert_nil first.token.user_authority_generation
    assert_equal @owner, runner.manager
    assert_predicate runner, :user_private?
    assert_nil AccessToken.authenticate_token(first.secret)
    AccessTokens::Revoke.call(first.token)
    assert_nil AccessToken.authenticate_executor_token(first.secret)
    assert_equal second.token, AccessToken.authenticate_executor_token(second.secret)
    runner.re_pair(display_name: runner.display_name)
    assert_nil AccessToken.authenticate_executor_token(second.secret)
  end

  test "connection revocation fences member keys even before an address exists" do
    old = issue_member("Before connection")
    assert_nil Executor.address_for(@agent)

    @agent.revoke_connection

    assert_nil AccessToken.authenticate_token(old.secret)
    fresh = issue_member("After revocation")
    assert_equal fresh.token, AccessToken.authenticate_token(fresh.secret)
    assert_nil AccessToken.authenticate_token(old.secret)
  end

  test "OAuth replacement fences static keys and mints usable credentials for the same identity" do
    member = issue_member("Member")
    transport = AccessTokens::IssueAgentExecutorKey.call(agent: @agent, name: "Executor")
    address = transport.token.executor

    replacement = connect_agent_session(steward: @owner, agent_identifier: @agent.agent_identifier)

    assert_equal :minted, replacement.outcome
    assert_equal @agent, replacement.access_token.user
    assert_equal address, replacement.executor_access_token.executor
    assert_nil AccessToken.authenticate_token(member.secret)
    assert_nil AccessToken.authenticate_executor_token(transport.secret)
    assert_equal replacement.access_token, AccessToken.authenticate_token(replacement.access_secret)
    assert_equal replacement.executor_access_token,
      AccessToken.authenticate_executor_token(replacement.executor_access_secret)
  end

  test "removal and restore never revive static member or executor keys" do
    member = issue_member("Member")
    executor = AccessTokens::IssueAgentExecutorKey.call(agent: @agent, name: "Executor")
    @agent.remove

    assert_nil AccessToken.authenticate_token(member.secret)
    assert_nil AccessToken.authenticate_executor_token(executor.secret)
    assert_equal :not_issuable, issue_member("Removed").outcome
    @agent.restore
    assert_nil AccessToken.authenticate_token(member.secret)
    assert_nil AccessToken.authenticate_executor_token(executor.secret)
  end

  test "Human and named definition issuance is refused including a collected declarer" do
    assert_equal :not_issuable, AccessTokens::IssueAPIKey.call(user: @owner, name: "Human").outcome
    definition = Users::DeclareNamedAgent.call(caller: @agent, name: "reviewer", scope: "steward",
      description: "Reviews work.", configuration: {
        tool_definitions: [], approval_mode: nil, approval_rules: nil,
        prompt_mechanism: "default", prompt_template: nil, compaction_policy: nil,
      }).user
    definition.update_columns(derived_from_id: nil)

    assert_predicate definition.reload, :named_agent?
    assert_equal :not_issuable, AccessTokens::IssueAPIKey.call(user: definition, name: "Definition").outcome
    assert_equal :not_issuable, AccessTokens::IssueAgentExecutorKey.call(agent: definition, name: "Definition").outcome
    assert_nil Executor.address_for(definition)
  end

  test "an invalid first executor key leaves no registration behind" do
    assert_no_difference -> { Executor.count } do
      result = AccessTokens::IssueAgentExecutorKey.call(agent: @agent, name: "")
      assert_equal :invalid, result.outcome
      assert result.token.errors.of_kind?(:name, :blank)
      assert_nil result.secret
    end
  end

  private

    def issue_member(name)
      AccessTokens::IssueAPIKey.call(user: @agent, name: name)
    end
end
