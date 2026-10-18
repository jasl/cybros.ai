require "test_helper"
require_relative "../support/device_flow_client"

# Polling uses a fake clock and sleeper to cover pacing, transient failures
# and the authorization deadline without real time.
class DeviceFlowClientPollingTest < Minitest::Test
  include CybrosAgentTest::DeviceFlowClientSupport

  def test_authorization_deadline_includes_time_spent_requesting_authorization
    client = build_client(
      [[200, {}, AUTH_BODY]],
      on_call: -> { @clock += 17 }
    )

    authorization = client.request_authorization(agent_identifier: "i", agent_display_name: "n",
      executor_display_name: "App")

    assert_equal 17, @clock
    assert_equal 900, authorization.deadline_monotonic
  end

  def test_await_credentials_paces_then_returns_the_pair
    client = build_client([
      [200, {}, AUTH_BODY],
      [400, {}, { "error" => "authorization_pending" }],
      [400, {}, { "error" => "slow_down" }],
      [200, {}, TOKEN_BODY],
    ])
    auth = client.request_authorization(agent_identifier: "i", agent_display_name: "n",
      executor_display_name: "App")

    credentials = client.await_credentials(auth)

    assert_equal "sk-cybros-api-v1-x.y", credentials.access_token
    # First wait at the interval (5), second after slow_down bumped it (+5).
    assert_equal [5, 10], @slept
  end

  def test_a_429_honors_retry_after_before_resuming
    client = build_client([
      [200, {}, AUTH_BODY],
      [429, { "Retry-After" => "20" }, { "error" => "temporarily_unavailable" }],
      [400, {}, { "error" => "authorization_pending" }],
      [200, {}, TOKEN_BODY],
    ])
    auth = client.request_authorization(agent_identifier: "i", agent_display_name: "n",
      executor_display_name: "App")

    client.await_credentials(auth)
    assert_equal [20, 5], @slept
  end

  def test_a_connection_failure_backs_off_and_retries_within_the_deadline
    client = build_client([
      [200, {}, AUTH_BODY],
      :connection_error,
      [200, {}, TOKEN_BODY],
    ])
    auth = client.request_authorization(agent_identifier: "i", agent_display_name: "n",
      executor_display_name: "App")

    credentials = client.await_credentials(auth)
    assert_equal "rt-cybros-api-v1-a.b", credentials.refresh_token
    assert_includes @slept, CybrosAgent::DeviceFlow::Client::TRANSIENT_RETRY_DELAY
  end

  def test_persistent_connection_failures_exhaust_a_bounded_retry_budget
    client = build_client([
      [200, {}, AUTH_BODY],
      *Array.new(100, :connection_error),
    ])
    auth = client.request_authorization(agent_identifier: "i", agent_display_name: "n",
      executor_display_name: "App")

    assert_raises(CybrosAgent::TransportError) { client.await_credentials(auth) }
    assert_operator @clock, :<, auth.deadline_monotonic
  end

  def test_a_server_response_resets_the_connection_failure_budget
    failures = Array.new(CybrosAgent::DeviceFlow::Client::TRANSIENT_RETRY_LIMIT, :connection_error)
    client = build_client([
      [200, {}, AUTH_BODY],
      *failures,
      [400, {}, { "error" => "authorization_pending" }],
      *failures,
      [200, {}, TOKEN_BODY],
    ])
    auth = client.request_authorization(agent_identifier: "i", agent_display_name: "n",
      executor_display_name: "App")

    credentials = client.await_credentials(auth)

    assert_equal "sk-cybros-api-v1-x.y", credentials.access_token
  end

  def test_polling_absorbs_unhandled_server_failures_within_the_transient_budget
    # A proxy 502 with no JSON and a 5xx that happens to carry a JSON error
    # field are both server failures by status alone — the OAuth vocabulary
    # never applies to an unhandled 5xx (guides/reference/oauth/device-flow.md).
    client = build_client([
      [200, {}, AUTH_BODY],
      [502, {}, nil],
      [500, {}, { "error" => "access_denied" }],
      [200, {}, TOKEN_BODY],
    ])
    auth = client.request_authorization(agent_identifier: "i", agent_display_name: "n",
      executor_display_name: "App")

    credentials = client.await_credentials(auth)

    assert_equal "sk-cybros-api-v1-x.y", credentials.access_token
    assert_includes @slept, CybrosAgent::DeviceFlow::Client::TRANSIENT_RETRY_DELAY
  end

  def test_persistent_server_failures_exhaust_the_same_transient_budget
    client = build_client([
      [200, {}, AUTH_BODY],
      *Array.new(CybrosAgent::DeviceFlow::Client::TRANSIENT_RETRY_LIMIT + 1, [502, {}, nil]),
    ])
    auth = client.request_authorization(agent_identifier: "i", agent_display_name: "n",
      executor_display_name: "App")

    assert_raises(CybrosAgent::DeviceFlow::ServerError) { client.await_credentials(auth) }
    assert_operator @clock, :<, auth.deadline_monotonic
  end

  def test_connection_backoff_does_not_outlive_the_deadline
    client = build_client([
      [200, {}, { **AUTH_BODY, "expires_in" => 3 }],
      :connection_error,
    ])
    auth = client.request_authorization(agent_identifier: "i", agent_display_name: "n",
      executor_display_name: "App")

    assert_raises(CybrosAgent::DeviceFlow::DeadlineExceeded) { client.await_credentials(auth) }
    assert_equal auth.deadline_monotonic, @clock
  end

  def test_access_denied_raises_authorization_lost
    client = build_client([
      [200, {}, AUTH_BODY],
      [400, {}, { "error" => "access_denied" }],
    ])
    auth = client.request_authorization(agent_identifier: "i", agent_display_name: "n",
      executor_display_name: "App")

    error = assert_raises(CybrosAgent::DeviceFlow::AuthorizationLostError) { client.await_credentials(auth) }
    assert_equal "access_denied", error.oauth_error
  end

  def test_the_deadline_caps_polling
    client = build_client([[200, {}, { **AUTH_BODY, "expires_in" => 8 }]] + Array.new(5) { [400, {}, { "error" => "authorization_pending" }] })
    auth = client.request_authorization(agent_identifier: "i", agent_display_name: "n",
      executor_display_name: "App")

    assert_raises(CybrosAgent::DeviceFlow::DeadlineExceeded) { client.await_credentials(auth) }
    assert @clock <= 8 + 5, "polling never runs far past the deadline"
  end

  def test_poll_caps_the_transport_budget_to_the_authorization_deadline
    client = build_client([[400, {}, { "error" => "authorization_pending" }]], request_timeout: 120)
    authorization = authorization_with(deadline_monotonic: 3)

    assert_instance_of CybrosAgent::DeviceFlow::Pending, client.poll(authorization)
    assert_equal 3, @transport.requests.first.last
  end

  def test_poll_rejects_a_success_that_arrives_after_the_authorization_deadline
    client = build_client(
      [[200, {}, TOKEN_BODY]],
      on_call: -> { @clock = 2 }
    )
    authorization = authorization_with(deadline_monotonic: 1)

    assert_raises(CybrosAgent::DeviceFlow::DeadlineExceeded) do
      client.poll(authorization)
    end
  end

  def test_poll_reports_the_deadline_when_an_in_flight_transport_failure_arrives_late
    client = build_client(
      [:connection_error],
      on_call: -> { @clock = 2 }
    )
    authorization = authorization_with(deadline_monotonic: 1)

    assert_raises(CybrosAgent::DeviceFlow::DeadlineExceeded) do
      client.poll(authorization)
    end
  end

  def test_poll_does_not_dispatch_after_the_authorization_deadline
    client = build_client([])
    authorization = authorization_with(deadline_monotonic: 0)

    assert_raises(CybrosAgent::DeviceFlow::DeadlineExceeded) do
      client.poll(authorization)
    end
    assert_empty @transport.requests
  end
end
