require "test_helper"

# Every Runner has one Human manager, so this surface follows management authority rather than
# assignment scope.
class RunnersTest < ActionDispatch::IntegrationTest
  setup do
    @owner = users(:owner)
    @member = users(:member)
    sign_in_as @owner
  end

  test "the index lists every runner managed by the signed-in human and shows its scope" do
    connect_runner(manager: @owner, runner_identifier: "mine-private",
      display_name: "My laptop")
    connect_runner(manager: @owner, runner_identifier: "mine-wide",
      display_name: "My farm", assignment_scope: :account_wide)
    connect_runner(manager: @member, runner_identifier: "theirs",
      display_name: "Their laptop")
    private_runner = @owner.managed_runners.find_by!(runner_identifier: "mine-private")
    account_wide_runner = @owner.managed_runners.find_by!(runner_identifier: "mine-wide")
    their_runner = @member.managed_runners.sole

    get runners_path

    assert_response :success
    assert_select "title", text: /My runners/
    assert_select "a[href=?]", oauth_device_path, text: "Connect runner"
    assert_select "tr[data-runner-id='#{private_runner.public_id}']", text: /Private.*Ready/m do
      assert_select "button[data-turbo-confirm]", text: "Revoke credentials" do |buttons|
        assert_equal(
          "Revoke credentials for My laptop? It stops working immediately and keeps its registration — starting the same Runner product and connecting again restores it.",
          buttons.sole["data-turbo-confirm"]
        )
      end
      assert_select "button[data-turbo-confirm]", text: "Revoke runner" do |buttons|
        assert_equal(
          "Revoke My laptop? This cannot be undone: the machine loses this identity and reconnecting registers a new runner.",
          buttons.sole["data-turbo-confirm"]
        )
      end
    end
    assert_select "tr[data-runner-id='#{account_wide_runner.public_id}']", text: /Account-wide/
    assert_select "tr[data-runner-id='#{their_runner.public_id}']", count: 0
    assert_select "body", text: /mine-private|mine-wide/, count: 0
    assert_select "body", text: /Installation ID/, count: 0
  end

  # PRESENCE beside each machine (r-modes M4): the pong-verified socket's
  # word, the contact sample as the tooltip — display, never a gate.
  test "the index shows each runner's presence" do
    NexusServer.register
    online = connect_runner(manager: @owner, runner_identifier: "online", display_name: "Online box")
      .executor_access_token.task_executor
    offline = connect_runner(manager: @owner, runner_identifier: "offline", display_name: "Offline box")
      .executor_access_token.task_executor
    unseen = connect_runner(manager: @owner, runner_identifier: "unseen", display_name: "Unseen box")
      .executor_access_token.task_executor
    online.update!(last_seen_at: Time.current)
    online.mark_connected("socket-1")
    offline.update!(last_seen_at: 3.minutes.ago)

    get runners_path

    assert_response :success
    assert_select "th", text: "Presence"
    assert_select "th", text: "Last seen", count: 0
    assert_select "tr[data-runner-id='#{online.public_id}'] td[title='#{online.reload.last_seen_at.iso8601}']",
      text: /Online/
    assert_select "tr[data-runner-id='#{offline.public_id}'] td", text: /Offline · last seen 3 minutes ago/
    assert_select "tr[data-runner-id='#{unseen.public_id}'] td", text: /Not yet seen/
  end

  # Both machine kinds answer to their manager and share the one revoke surface; the page says which
  # is which beside the name.
  test "the index names each machine's kind: a tools provider lists beside a runner" do
    connect_runner(manager: @owner, runner_identifier: "mine-runner", display_name: "My laptop")
    connect_runner(manager: @owner, runner_identifier: "mine-provider", display_name: "My memory service",
      executor_kind: :tools_provider)
    runner = @owner.managed_runners.find_by!(runner_identifier: "mine-runner")
    provider = @owner.managed_runners.find_by!(runner_identifier: "mine-provider")

    get runners_path

    assert_response :success
    assert_select "tr[data-runner-id='#{runner.public_id}']" do
      assert_select "[data-executor-kind]", text: "Runner"
    end
    assert_select "tr[data-runner-id='#{provider.public_id}']", text: /My memory service/ do
      assert_select "[data-executor-kind]", text: "Tools provider"
      assert_select "button[data-turbo-confirm]", text: "Revoke runner"
    end
  end

  test "the index query count does not grow with the number of displayed runners" do
    connect_runner(manager: @owner, runner_identifier: "runner-0")

    get runners_path
    assert_response :success
    one_runner_queries = page_render_query_count { get runners_path }

    5.times do |index|
      connect_runner(manager: @owner, runner_identifier: "runner-#{index + 1}")
    end
    six_runner_queries = page_render_query_count { get runners_path }

    assert_response :success
    assert_select "tr[data-runner-id]", 6
    assert_operator one_runner_queries, :>, 0
    assert_equal one_runner_queries, six_runner_queries,
      "rendering more runner rows must not add SQL queries"
  end

  test "the index labels the logical registration time rather than its latest re-pair" do
    registered_at = 2.days.ago.change(usec: 0)
    travel_to registered_at do
      connect_runner(manager: @owner, runner_identifier: "mine",
        display_name: "Original laptop")
    end
    runner = @owner.managed_runners.sole

    connect_runner(manager: @owner, runner_identifier: "mine",
      display_name: "Replacement laptop")

    assert_equal registered_at, runner.reload.created_at
    assert_equal "Replacement laptop", runner.display_name

    get runners_path

    assert_response :success
    assert_select "th", text: "Registered"
    assert_select "th", text: "Connected", count: 0
    assert_select "tr[data-runner-id='#{runner.public_id}']" do
      assert_select "td[title=?]", registered_at.iso8601
    end
  end

  test "an account-wide runner remains manageable by its manager" do
    connect_runner(manager: @owner, runner_identifier: "farm", display_name: "Farm",
      assignment_scope: :account_wide)
    runner = @owner.managed_runners.sole

    get runners_path

    assert_response :success
    assert_select "tr[data-runner-id='#{runner.public_id}']", text: /Account-wide/
    delete runner_credentials_path(runner.public_id)
    assert_redirected_to runners_path
    assert_predicate runner.reload, :active?
  end

  test "revoking credentials stops the machine now but keeps its identity" do
    result = connect_runner(manager: @owner)
    runner = @owner.managed_runners.sole

    delete runner_credentials_path(runner.public_id)

    assert_redirected_to runners_path
    assert_equal I18n.t("runners.credentials.destroy.revoked"), flash[:notice]
    assert_predicate runner.reload, :active?
    assert_nil AccessToken.authenticate_executor_token(result.executor_access_secret)

    get runners_path
    assert_response :success
    assert_select "tr[data-runner-id='#{runner.public_id}']" do
      assert_select "span", text: "No credential"
    end
  end

  test "revoking the runner is terminal" do
    result = connect_runner(manager: @owner)
    runner = @owner.managed_runners.sole

    delete runner_path(runner.public_id)

    assert_redirected_to runners_path
    assert_equal I18n.t("runners.destroy.revoked"), flash[:notice]
    assert_predicate runner.reload, :revoked?
    assert_nil AccessToken.authenticate_executor_token(result.executor_access_secret)

    terminal_epoch = runner.credential_epoch
    delete runner_credentials_path(runner.public_id)
    assert_redirected_to runners_path
    assert_equal terminal_epoch, runner.reload.credential_epoch,
      "a stale credentials URL must not mutate a terminal registration"

    get runners_path
    assert_response :success
    assert_select "body", text: /No runners connected/
    assert_select "body", text: /follow the link it prints/
    assert_select "a", text: "Connect a device", count: 0
  end

  test "another human's runner is not found rather than forbidden" do
    connect_runner(manager: @member, runner_identifier: "theirs")
    theirs = @member.managed_runners.sole

    delete runner_path(theirs.public_id)
    assert_response :not_found
    delete runner_credentials_path(theirs.public_id)
    assert_response :not_found
    assert_predicate theirs.reload, :active?
  end

  test "the surface requires an authenticated human" do
    sign_out
    get runners_path
    assert_redirected_to new_session_path(return_to: runners_path)
  end

  private

    def page_render_query_count
      count = 0
      page_rows_loaded = false
      subscriber = lambda do |_name, _started, _finished, _unique_id, payload|
        next if payload[:cached] || payload[:name] == "SCHEMA"

        page_rows_loaded ||= payload[:sql].include?('FROM "task_executors"') &&
          payload[:sql].include?("ORDER BY")
        next unless page_rows_loaded

        count += 1 if payload[:sql].match?(
          /FROM "(?:access_tokens|refresh_tokens|refresh_token_families)"/
        )
      end

      connection = ActiveRecord::Base.lease_connection
      connection.clear_query_cache
      connection.materialize_transactions
      ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") { yield }
      count
    end
end
