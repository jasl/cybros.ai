require "test_helper"

class OAuth::TokensControllerTest < ActionDispatch::IntegrationTest
  NAT_ADDRESS = "198.51.100.44".freeze

  setup do
    @account = accounts(:cybros)
    @owner = users(:owner)
  end

  # A connected device_code grant ready to consume, plus its raw code.
  def connected_pair
    member = @account.users.create!(kind: :agent, role: :member, steward: @owner, display_name: "Token agent", agent_identifier: "install-token")
    mint = DeviceAuthorizations::Issue.call(
      account: @account, agent_identifier: "install-token", agent_display_name: "Token agent",
      requested_executor_display_name: "Token app")
    mint.authorization.update!(
      status: :connected, user: member, connected_by: @owner,
      connected_by_authority_generation: @owner.authority_generation,
      user_authority_generation: member.authority_generation
    )
    [mint.authorization, mint.device_code]
  end

  # A connected runner (Branch B) grant ready to consume, plus its raw code.
  # Requested over the wire in the exact shape the contract permits — no
  # `scope`, no agent fields — so the poll below can never pass a request a
  # real runner could not have made. Before that poll only the durable Request
  # exists: Connect freezes its consequence, and Consume materializes the
  # Runner and credential.
  def connected_runner_pair
    post oauth_device_authorization_path, params: {
      client_id: OAuth::DEVICE_CLIENT_ID,
      runner_identifier: "install-runner",
      runner_display_name: "Workshop laptop",
    }
    assert_response :success

    device_code = response.parsed_body.fetch("device_code")
    authorization = DeviceAuthorization.find_by_device_code(device_code)
    DeviceAuthorizations::Connect.call(
      authorization: authorization,
      connector: @owner,
      expected_live_runner:
        DeviceAuthorizations::Connect::ABSENT_LIVE_RUNNER
    )
    [authorization.reload, device_code]
  end

  # A connected combined (A+B) grant ready to consume, requested over the
  # wire in the shape rho in full mode sends: the agent triple and the
  # runner pair on one request.
  def connected_combined_pair
    member = @account.users.create!(kind: :agent, role: :member, steward: @owner, display_name: "rho", agent_identifier: "rho")
    post oauth_device_authorization_path, params: {
      client_id: OAuth::DEVICE_CLIENT_ID,
      agent_identifier: "rho",
      agent_display_name: "rho",
      executor_display_name: "rho on laptop",
      runner_identifier: "rho",
      runner_display_name: "rho on laptop",
    }
    assert_response :success

    device_code = response.parsed_body.fetch("device_code")
    authorization = DeviceAuthorization.find_by_device_code(device_code)
    result = DeviceAuthorizations::Connect.call(authorization: authorization, connector: @owner)
    assert_equal :connected, result.outcome
    assert_equal member, authorization.reload.user
    [authorization, device_code]
  end

  def post_token(params = {}, headers: {}, **fields)
    post oauth_token_path,
      params: { client_id: OAuth::DEVICE_CLIENT_ID }.merge(params).merge(fields),
      headers: headers
  end

  test "a successful device_code consume returns the credential pair under no-store" do
    _grant, device_code = connected_pair

    post_token(grant_type: OAuth::DEVICE_GRANT_TYPE, device_code: device_code)

    assert_response :success
    assert_equal "no-store", response.headers["Cache-Control"]
    body = response.parsed_body
    assert body["access_token"].start_with?("sk-cybros-api-v1-")
    assert body["refresh_token"].start_with?("rt-cybros-api-v1-")
    assert_equal "Bearer", body["token_type"]
    assert_equal 1_209_600, body["expires_in"]
    assert_equal "member", body["plane"]
    # The requested address makes this a two-plane bundle: the member
    # credential leads, the transport credential accompanies it.
    assert body["executor_access_token"].start_with?("sk-cybros-api-v1-")
    assert_predicate AccessToken.authenticate_token(body["access_token"]), :member_plane?
    assert_predicate AccessToken.authenticate_executor_token(body["executor_access_token"]),
      :executor_transport_plane?
  end

  # Branch B's bundle degenerates to its transport half, and `access_token`
  # carries the connection's primary plane whichever branch issued it
  # (docs/oauth/device-flow.md, "Success shape").
  test "a runner consume returns the transport credential as access_token" do
    _grant, device_code = connected_runner_pair

    post_token(grant_type: OAuth::DEVICE_GRANT_TYPE, device_code: device_code)

    assert_response :success
    assert_equal "no-store", response.headers["Cache-Control"]
    body = response.parsed_body
    assert body["access_token"].start_with?("sk-cybros-api-v1-")
    assert body["refresh_token"].start_with?("rt-cybros-api-v1-")
    assert_equal "Bearer", body["token_type"]
    assert_equal 1_209_600, body["expires_in"]
    assert_equal "executor_transport", body["plane"],
      "the wire names the plane it led with; a client never infers it"
    # No member plane exists to accompany, so the second field is absent
    # rather than null — a runner is not a principal.
    assert_not body.key?("executor_access_token")

    assert_nil AccessToken.authenticate_token(body["access_token"]),
      "the runner's credential must be rejected on the member plane"
    transport = AccessToken.authenticate_executor_token(body["access_token"])
    assert_equal @owner.managed_runners.sole, transport.task_executor
  end

  # The combined grant's body (r-modes M2): the member-led agent bundle as
  # branch A returns it, plus a nested `runner` object carrying the second
  # lineage — its own transport credential and its own refresh token.
  test "a combined consume returns the agent bundle with a nested runner lineage" do
    _grant, device_code = connected_combined_pair

    post_token(grant_type: OAuth::DEVICE_GRANT_TYPE, device_code: device_code)

    assert_response :success
    assert_equal "no-store", response.headers["Cache-Control"]
    body = response.parsed_body
    assert_equal "member", body["plane"]
    assert_predicate AccessToken.authenticate_token(body["access_token"]), :member_plane?
    agent_transport = AccessToken.authenticate_executor_token(body["executor_access_token"])
    assert_predicate agent_transport.task_executor, :agent_application?

    runner = body.fetch("runner")
    assert_equal %w[access_token refresh_token], runner.keys.sort
    assert runner["access_token"].start_with?("sk-cybros-api-v1-")
    assert runner["refresh_token"].start_with?("rt-cybros-api-v1-")
    assert_nil AccessToken.authenticate_token(runner["access_token"]),
      "the runner half is rejected on the member plane"
    runner_transport = AccessToken.authenticate_executor_token(runner["access_token"])
    assert_equal @owner.managed_runners.sole, runner_transport.task_executor
    assert_predicate runner_transport.task_executor, :runner?
    assert_equal "rho", runner_transport.task_executor.runner_identifier

    # Its refresh token rotates its OWN family, into the transport-led shape.
    post_token(grant_type: OAuth::REFRESH_GRANT_TYPE, refresh_token: runner["refresh_token"])
    assert_response :success
    rotated = response.parsed_body
    assert_equal "executor_transport", rotated["plane"]
    assert_not rotated.key?("executor_access_token")
    assert_not rotated.key?("runner")
    assert_equal runner_transport.task_executor,
      AccessToken.authenticate_executor_token(rotated["access_token"]).task_executor
  end

  test "polling a pending grant returns authorization_pending" do
    mint = DeviceAuthorizations::Issue.call(
      account: @account, agent_identifier: "install-pend", agent_display_name: "Pending",
      requested_executor_display_name: "App")
    post_token(grant_type: OAuth::DEVICE_GRANT_TYPE, device_code: mint.device_code)

    assert_response :bad_request
    assert_equal "authorization_pending", response.parsed_body["error"]
  end

  test "a consumed code replays as invalid_grant" do
    _grant, device_code = connected_pair
    post_token(grant_type: OAuth::DEVICE_GRANT_TYPE, device_code: device_code)
    post_token(grant_type: OAuth::DEVICE_GRANT_TYPE, device_code: device_code)

    assert_equal "invalid_grant", response.parsed_body["error"]
  end

  test "wrong client, unknown grant, and missing fields map to their errors" do
    post oauth_token_path, params: { client_id: "nope", grant_type: OAuth::DEVICE_GRANT_TYPE, device_code: "x" }
    assert_equal "invalid_client", response.parsed_body["error"]

    post_token(grant_type: "authorization_code")
    assert_equal "unsupported_grant_type", response.parsed_body["error"]

    post_token({})
    assert_equal "invalid_request", response.parsed_body["error"]

    post_token(grant_type: OAuth::DEVICE_GRANT_TYPE)
    assert_equal "invalid_request", response.parsed_body["error"]
  end

  test "a bracketed grant type cannot be hidden by a later scalar" do
    body = URI.encode_www_form(
      [
        ["client_id", OAuth::DEVICE_CLIENT_ID],
        ["grant_type[]", "junk"],
        ["grant_type", OAuth::DEVICE_GRANT_TYPE],
        ["device_code", "presented-secret"],
      ]
    )

    DeviceAuthorization.stub(:find_by_device_code, ->(*) { flunk "malformed input must not resolve its secret" }) do
      post oauth_token_path,
        params: body,
        headers: { "CONTENT_TYPE" => "application/x-www-form-urlencoded" }
    end

    assert_response :bad_request
    assert_equal "invalid_request", response.parsed_body["error"]
  end

  test "a malformed or unknown device code is invalid_grant" do
    post_token(grant_type: OAuth::DEVICE_GRANT_TYPE, device_code: "dc-cybros-v1-abcdefghijklmnopqrstuvwx.wrong")
    assert_equal "invalid_grant", response.parsed_body["error"]

    post_token(grant_type: OAuth::DEVICE_GRANT_TYPE, device_code: "garbage")
    assert_equal "invalid_grant", response.parsed_body["error"]
  end

  test "a wrong client is rejected before device secret resolution" do
    DeviceAuthorization.stub(:find_by_device_code, ->(*) { flunk "secret lookup must not run" }) do
      post oauth_token_path,
        params: {
          client_id: "wrong-client",
          grant_type: OAuth::DEVICE_GRANT_TYPE,
          device_code: "presented-secret",
        },
        headers: { "REMOTE_ADDR" => NAT_ADDRESS }
    end

    assert_response :bad_request
    assert_equal "invalid_client", response.parsed_body["error"]
  end

  test "an unknown refresh_token is invalid_grant without revealing which check failed" do
    post_token(grant_type: OAuth::REFRESH_GRANT_TYPE, refresh_token: "rt-cybros-api-v1-x.y")
    assert_equal "invalid_grant", response.parsed_body["error"]
  end

  test "many valid device pollers behind one NAT do not share the ordinary budget" do
    codes = 6.times.map do |index|
      DeviceAuthorizations::Issue.call(
        account: @account,
        agent_identifier: "nat-poller-#{index}",
        agent_display_name: "NAT poller",
        requested_executor_display_name: "NAT app"
      ).device_code
    end

    keys = capture_rate_limit_keys do
      # Sixty-six valid polls would have exhausted the former shared 60/minute
      # IP bucket, while each recognized grant remains far below its own 120.
      11.times do
        codes.each do |device_code|
          post_token(
            {
              grant_type: OAuth::DEVICE_GRANT_TYPE,
              device_code: device_code,
            },
            headers: { "REMOTE_ADDR" => NAT_ADDRESS }
          )
          assert_response :bad_request
          assert_not_equal "temporarily_unavailable", response.parsed_body["error"]
        end
      end
    end

    ordinary_keys = keys.grep(/:grant-or-family:/).uniq
    assert_equal codes.length, ordinary_keys.length
    assert_equal 1, keys.grep(/:ip-backstop:/).uniq.length
  end

  test "the recognized grant budget returns a full-window Retry-After" do
    mint = DeviceAuthorizations::Issue.call(
      account: @account,
      agent_identifier: "grant-rate-limit",
      agent_display_name: "Grant rate limit",
      requested_executor_display_name: "Rate limited app"
    )

    keys = capture_rate_limit_keys do
      post_token(
        {
          grant_type: OAuth::DEVICE_GRANT_TYPE,
          device_code: mint.device_code,
        },
        headers: { "REMOTE_ADDR" => NAT_ADDRESS }
      )
    end
    caller_key = keys.find { |key| key.include?(":grant-or-family:") }
    assert caller_key
    assert_includes caller_key, mint.authorization.public_id
    assert_not_includes caller_key, mint.device_code

    Rails.cache.write(
      caller_key,
      OAuth::TokensController::RATE_LIMIT,
      expires_in: OAuth::TokensController::RATE_LIMIT_WINDOW
    )
    post_token(
      {
        grant_type: OAuth::DEVICE_GRANT_TYPE,
        device_code: mint.device_code,
      },
      headers: { "REMOTE_ADDR" => NAT_ADDRESS }
    )

    assert_response :too_many_requests
    assert_equal "temporarily_unavailable", response.parsed_body["error"]
    assert_equal OAuth::TokensController::RATE_LIMIT_WINDOW.to_i.to_s,
      response.headers["Retry-After"]
  end

  test "refresh rotation keeps one family budget without storing the secret in its key" do
    _grant, device_code = connected_pair
    post_token(grant_type: OAuth::DEVICE_GRANT_TYPE, device_code: device_code)
    first_refresh = response.parsed_body.fetch("refresh_token")
    family = RefreshToken.find_by_secret(first_refresh).refresh_token_family

    first_keys = capture_rate_limit_keys do
      post_token(
        {
          grant_type: OAuth::REFRESH_GRANT_TYPE,
          refresh_token: first_refresh,
        },
        headers: { "REMOTE_ADDR" => NAT_ADDRESS }
      )
    end
    second_refresh = response.parsed_body.fetch("refresh_token")
    second_keys = capture_rate_limit_keys do
      post_token(
        {
          grant_type: OAuth::REFRESH_GRANT_TYPE,
          refresh_token: second_refresh,
        },
        headers: { "REMOTE_ADDR" => NAT_ADDRESS }
      )
    end

    first_caller_key = first_keys.find { |key| key.include?(":grant-or-family:") }
    second_caller_key = second_keys.find { |key| key.include?(":grant-or-family:") }
    assert_equal first_caller_key, second_caller_key
    assert_includes first_caller_key, family.public_id
    assert_not_includes first_caller_key, first_refresh
    assert_not_includes second_caller_key, second_refresh
  end

  test "recognized refresh writes have a tighter per-family hourly budget" do
    _grant, device_code = connected_pair
    post_token(grant_type: OAuth::DEVICE_GRANT_TYPE, device_code: device_code)
    first_refresh = response.parsed_body.fetch("refresh_token")

    keys = capture_rate_limit_keys do
      post_token(
        {
          grant_type: OAuth::REFRESH_GRANT_TYPE,
          refresh_token: first_refresh,
        },
        headers: { "REMOTE_ADDR" => NAT_ADDRESS }
      )
    end
    second_refresh = response.parsed_body.fetch("refresh_token")
    family_key = keys.find { |key| key.include?(":refresh-family-writes:") }
    assert family_key
    assert_not_includes family_key, first_refresh

    Rails.cache.write(
      family_key,
      OAuth::TokensController::REFRESH_FAMILY_RATE_LIMIT,
      expires_in: OAuth::TokensController::REFRESH_RATE_LIMIT_WINDOW
    )
    post_token(
      {
        grant_type: OAuth::REFRESH_GRANT_TYPE,
        refresh_token: second_refresh,
      },
      headers: { "REMOTE_ADDR" => NAT_ADDRESS }
    )

    assert_response :too_many_requests
    assert_equal "temporarily_unavailable", response.parsed_body["error"]
    assert_equal OAuth::TokensController::REFRESH_RATE_LIMIT_WINDOW.to_i.to_s,
      response.headers["Retry-After"]
  end

  test "recognized refresh writes share one installation-wide hourly budget" do
    _grant, device_code = connected_pair
    post_token(grant_type: OAuth::DEVICE_GRANT_TYPE, device_code: device_code)
    first_refresh = response.parsed_body.fetch("refresh_token")

    keys = capture_rate_limit_keys do
      post_token(
        {
          grant_type: OAuth::REFRESH_GRANT_TYPE,
          refresh_token: first_refresh,
        },
        headers: { "REMOTE_ADDR" => NAT_ADDRESS }
      )
    end
    second_refresh = response.parsed_body.fetch("refresh_token")
    account_key = keys.find { |key| key.include?(":refresh-account-writes:") }
    assert account_key
    assert_not_includes account_key, first_refresh

    Rails.cache.write(
      account_key,
      OAuth::TokensController::REFRESH_ACCOUNT_RATE_LIMIT,
      expires_in: OAuth::TokensController::REFRESH_RATE_LIMIT_WINDOW
    )
    post_token(
      {
        grant_type: OAuth::REFRESH_GRANT_TYPE,
        refresh_token: second_refresh,
      },
      headers: { "REMOTE_ADDR" => NAT_ADDRESS }
    )

    assert_response :too_many_requests
    assert_equal "temporarily_unavailable", response.parsed_body["error"]
    assert_equal OAuth::TokensController::REFRESH_RATE_LIMIT_WINDOW.to_i.to_s,
      response.headers["Retry-After"]
  end

  test "the refresh write envelope stays below mixed-backlog collector capacity" do
    assert_operator OAuth::TokensController::REFRESH_ACCOUNT_RATE_LIMIT * 2,
      :<=, AccessToken::Convergence::BATCH_SIZE,
      "an Agent rotation writes two access tokens"
    assert_operator OAuth::TokensController::REFRESH_ACCOUNT_RATE_LIMIT,
      :<=, RefreshToken::Convergence::BATCH_SIZE,
      "every rotation writes one refresh-token evidence row"
  end

  test "unknown secrets share both IP-keyed counters" do
    keys = capture_rate_limit_keys do
      post_token(
        {
          grant_type: OAuth::DEVICE_GRANT_TYPE,
          device_code: "unknown-device-secret",
        },
        headers: { "REMOTE_ADDR" => NAT_ADDRESS }
      )
      assert_equal "invalid_grant", response.parsed_body["error"]

      post_token(
        {
          grant_type: OAuth::REFRESH_GRANT_TYPE,
          refresh_token: "unknown-refresh-secret",
        },
        headers: { "REMOTE_ADDR" => NAT_ADDRESS }
      )
      assert_equal "invalid_grant", response.parsed_body["error"]
    end

    assert_equal 4, keys.length
    assert_equal 2, keys.uniq.length
    keys.each do |key|
      assert_includes key, "ip/#{NAT_ADDRESS}"
      assert_not_includes key, "unknown-device-secret"
      assert_not_includes key, "unknown-refresh-secret"
    end
  end

  test "the broad IP backstop returns the same full-window Retry-After" do
    mint = DeviceAuthorizations::Issue.call(
      account: @account,
      agent_identifier: "ip-backstop",
      agent_display_name: "IP backstop",
      requested_executor_display_name: "IP app"
    )
    keys = capture_rate_limit_keys do
      post_token(
        {
          grant_type: OAuth::DEVICE_GRANT_TYPE,
          device_code: mint.device_code,
        },
        headers: { "REMOTE_ADDR" => NAT_ADDRESS }
      )
    end
    backstop_key = keys.find { |key| key.include?(":ip-backstop:") }
    assert backstop_key

    Rails.cache.write(
      backstop_key,
      OAuth::TokensController::IP_BACKSTOP_RATE_LIMIT,
      expires_in: OAuth::TokensController::RATE_LIMIT_WINDOW
    )
    post_token(
      {
        grant_type: OAuth::DEVICE_GRANT_TYPE,
        device_code: mint.device_code,
      },
      headers: { "REMOTE_ADDR" => NAT_ADDRESS }
    )

    assert_response :too_many_requests
    assert_equal "temporarily_unavailable", response.parsed_body["error"]
    assert_equal OAuth::TokensController::RATE_LIMIT_WINDOW.to_i.to_s,
      response.headers["Retry-After"]
  end

  test "device-code scope is scalar compatibility input and does not change the grant" do
    _grant, device_code = connected_pair

    post_token(
      grant_type: OAuth::DEVICE_GRANT_TYPE,
      device_code: device_code,
      scope: ["member"]
    )
    assert_equal "invalid_request", response.parsed_body["error"]

    post "#{oauth_token_path}?scope=member",
      params: {
        client_id: OAuth::DEVICE_CLIENT_ID,
        grant_type: OAuth::DEVICE_GRANT_TYPE,
        device_code: device_code,
        scope: "member",
      }
    assert_equal "invalid_request", response.parsed_body["error"]

    post_token(
      grant_type: OAuth::DEVICE_GRANT_TYPE,
      device_code: device_code,
      scope: "member"
    )
    assert_response :success
    assert_not response.parsed_body.key?("scope")
  end

  test "refresh scope is scalar compatibility input and does not change the grant" do
    _grant, device_code = connected_pair
    post_token(grant_type: OAuth::DEVICE_GRANT_TYPE, device_code: device_code)
    refresh_token = response.parsed_body.fetch("refresh_token")

    post_token(
      grant_type: OAuth::REFRESH_GRANT_TYPE,
      refresh_token: refresh_token,
      scope: { value: "member" }
    )
    assert_equal "invalid_request", response.parsed_body["error"]

    post "#{oauth_token_path}?scope=member",
      params: {
        client_id: OAuth::DEVICE_CLIENT_ID,
        grant_type: OAuth::REFRESH_GRANT_TYPE,
        refresh_token: refresh_token,
        scope: "member",
      }
    assert_equal "invalid_request", response.parsed_body["error"]

    post_token(
      grant_type: OAuth::REFRESH_GRANT_TYPE,
      refresh_token: refresh_token,
      scope: "member"
    )
    assert_response :success
    assert_not response.parsed_body.key?("scope")
  end

  private

    def capture_rate_limit_keys
      keys = []
      subscriber = lambda do |_name, _started, _finished, _unique_id, payload|
        key = payload.fetch(:key)
        keys << key if key.start_with?("rate-limit:")
      end

      ActiveSupport::Notifications.subscribed(subscriber, "cache_increment.active_support") do
        yield
      end
      keys
    end
end
