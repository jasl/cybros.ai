require "test_helper"
require_relative "../support/device_flow_client"
require "pp"

# The typed DeviceFlow client validates authorization, credential planes,
# rotation, cancellation and secret-safe diagnostics against a fake transport.
class DeviceFlowClientTest < Minitest::Test
  include CybrosAgentTest::DeviceFlowClientSupport

  def combined_authorization(client)
    client.request_authorization(
      agent_identifier: "rho", agent_display_name: "rho", executor_display_name: "rho on laptop",
      runner: { identifier: "rho", display_name: "rho on laptop" }
    )
  end

  # The combined shape A+B: one request carrying the agent
  # triple and the runner pair, typed :combined. The kind is the AGENT
  # address's — the runner's is implied and fixed `runner` by the door, so
  # the request never spells one.
  def test_a_combined_authorization_sends_both_identifier_sets_on_one_request
    client = build_client([[200, {}, AUTH_BODY]])

    authorization = combined_authorization(client)

    assert_equal :combined, authorization.branch
    assert_equal "agent_application", authorization.executor_kind
    assert_equal 1, @transport.requests.size
    _path, params, _timeout = @transport.requests.first
    assert_equal(
      {
        client_id: "cybros-first-party-connector",
        agent_identifier: "rho",
        agent_display_name: "rho",
        executor_display_name: "rho on laptop",
        registration_identifier: "rho",
        runner_display_name: "rho on laptop",
      },
      params
    )
  end

  def test_a_supplementary_runner_request_selects_an_existing_application_agent
    client = build_client([[200, {}, AUTH_BODY]])
    authorization = client.request_runner_authorization(registration_identifier: "workshop-runner",
      runner_display_name: "Workshop laptop", assignment_agent_public_id: "019b1000-0000-7000-8000-000000000001")
    assert_equal :runner, authorization.branch
    assert_equal "019b1000-0000-7000-8000-000000000001", @transport.requests.first[1].fetch(:assignment_agent_public_id)
    refute @transport.requests.first[1].key?(:agent_identifier)
  end

  def test_a_combined_bundle_names_three_planes_and_its_runner_half_is_transport_led
    client = build_client([[200, {}, AUTH_BODY], [200, {}, COMBINED_TOKEN_BODY]])
    authorization = combined_authorization(client)

    credentials = client.poll(authorization)

    assert_predicate credentials, :member_plane?
    assert_predicate credentials, :executor_plane?
    assert_predicate credentials, :runner_plane?
    assert_equal "sk-cybros-api-v1-runner.z", credentials.runner_access_token
    assert_equal "rt-cybros-api-v1-r.s", credentials.runner_refresh_token

    half = credentials.runner_half
    assert_instance_of CybrosAgent::DeviceFlow::Credentials, half
    assert_nil half.access_token, "the runner half leads with transport, like branch B"
    assert_equal "sk-cybros-api-v1-runner.z", half.executor_access_token
    assert_equal "rt-cybros-api-v1-r.s", half.refresh_token
    assert_equal "Bearer", half.token_type
    assert_equal 1_209_600, half.expires_in
    refute_predicate half, :member_plane?
    assert_predicate half, :executor_plane?
    refute_predicate half, :runner_plane?
  end

  def test_a_combined_initial_poll_refuses_a_two_plane_bundle
    client = build_client([[200, {}, AUTH_BODY], [200, {}, TOKEN_BODY]])
    authorization = combined_authorization(client)

    assert_raises(CybrosAgent::DeviceFlow::AuthorizationLostError) { client.poll(authorization) }
  end

  def test_an_agent_initial_poll_refuses_a_bundle_carrying_a_runner_half
    client = build_client([[200, {}, AUTH_BODY], [200, {}, COMBINED_TOKEN_BODY]])
    authorization = client.request_authorization(
      agent_identifier: "i", agent_display_name: "n", executor_display_name: "App"
    )

    assert_raises(CybrosAgent::DeviceFlow::AuthorizationLostError) { client.poll(authorization) }
  end

  # A transport-led response never carries a second transport credential —
  # the nested runner object included.
  def test_a_transport_led_response_carrying_a_runner_half_is_lost
    client = build_client([[200, {}, AUTH_BODY], [200, {}, RUNNER_TOKEN_BODY.merge("runner" => RUNNER_HALF)]])
    authorization = client.request_runner_authorization(
      registration_identifier: "workshop-runner", runner_display_name: "Workshop laptop"
    )

    assert_raises(CybrosAgent::DeviceFlow::AuthorizationLostError) { client.poll(authorization) }
  end

  def test_a_malformed_runner_half_loses_the_authorization
    [
      { "access_token" => "sk-cybros-api-v1-runner.z" },
      { "access_token" => "", "refresh_token" => "rt-cybros-api-v1-r.s" },
      "not-an-object",
      RUNNER_HALF.to_a,
    ].each do |runner|
      client = build_client([[200, {}, AUTH_BODY], [200, {}, TOKEN_BODY.merge("runner" => runner)]])
      authorization = combined_authorization(client)

      assert_raises(CybrosAgent::DeviceFlow::AuthorizationLostError, runner.inspect) do
        client.poll(authorization)
      end
    end
  end

  def test_a_rotation_body_without_a_runner_half_parses_to_no_runner_plane
    client = build_client([[200, {}, TOKEN_BODY]])

    credentials = client.rotate(refresh_token: "rt-cybros-api-v1-a.b")

    refute_predicate credentials, :runner_plane?
    assert_nil credentials.runner_access_token
    assert_nil credentials.runner_refresh_token
  end

  def test_request_authorization_returns_typed_facts_and_a_monotonic_deadline
    client = build_client([[200, {}, AUTH_BODY]])
    auth = client.request_authorization(
      agent_identifier: "install-1",
      agent_display_name: "Helper",
      executor_display_name: "App"
    )

    assert_equal "ABCD-EFGH", auth.user_code
    assert_equal 5, auth.interval
    assert_equal 900, auth.deadline_monotonic
    path, params, timeout = @transport.requests.first
    assert_equal "/oauth/device_authorization", path
    assert_equal(
      {
        client_id: "cybros-first-party-connector",
        agent_identifier: "install-1",
        agent_display_name: "Helper",
        executor_display_name: "App",
      },
      params
    )
    assert_equal CybrosAgent::DeviceFlow::Client::DEFAULT_REQUEST_TIMEOUT, timeout
  end

  def test_an_agent_client_cannot_choose_executor_kind
    # RBS RUNTIME INSTRUMENTATION GETS IN FRONT OF THIS ONE. The claim is
    # that Ruby itself refuses the keyword; under the type hook the call is
    # rejected as a TypeError first, so the assertion cannot see what it is
    # about. The behavior suite runs it for real — this skip costs three
    # assertions on the conformance pass and buys the whole namespace back.
    skip("the RBS hook answers before Ruby's own ArgumentError") if ENV["RBS_TEST_TARGET"]

    client = build_client([[200, {}, AUTH_BODY]])

    assert_raises(ArgumentError) do
      client.request_authorization(
        agent_identifier: "install-1",
        agent_display_name: "Helper",
        executor_kind: "agent_application",
        executor_display_name: "App"
      )
    end
    assert_empty @transport.requests
  end

  # Branch B: identity-less, and its winning poll returns the
  # transport credential in the RFC-standard access_token field. The typed
  # result names planes, so a runner host never has to know that rule.
  def test_a_runner_authorization_carries_no_agent_claims_and_yields_only_transport
    client = build_client([
      [200, {}, AUTH_BODY],
      [200, {}, RUNNER_TOKEN_BODY],
    ])

    authorization = client.request_runner_authorization(
      registration_identifier: "workshop-runner", runner_display_name: "Workshop laptop"
    )
    assert_equal :runner, authorization.branch
    assert_equal "runner", authorization.executor_kind, "the machine kind the request named"
    _path, params, _timeout = @transport.requests.first
    assert_equal "workshop-runner", params[:registration_identifier]
    assert_nil params[:agent_identifier]
    assert_equal "runner", params[:executor_kind], "one wire shape: the kind is always sent, runner by default"
    assert_nil params[:scope]
    refute params.key?(:assignment_scope)
    refute params.key?(:assignment_agent_public_id)

    credentials = client.poll(authorization)
    assert_equal "sk-cybros-api-v1-x.y", credentials.executor_access_token
    assert_nil credentials.access_token, "a runner is a delivery address, never a member principal"
    assert_predicate credentials, :executor_plane?
    refute_predicate credentials, :member_plane?
  end

  # A TOOLS PROVIDER IS A MACHINE CONNECTION OF ANOTHER KIND: the same branch B request naming `executor_kind:
  # tool_provider`. The branch stays :runner — it is the credential SHAPE
  # the poll validates (transport only, no member principal) — and the
  # Authorization carries the kind so a host can say what it connected.
  def test_a_tool_provider_authorization_names_its_kind_on_the_runner_branch
    client = build_client([
      [200, {}, AUTH_BODY],
      [200, {}, RUNNER_TOKEN_BODY],
    ])

    authorization = client.request_runner_authorization(
      registration_identifier: "workshop-provider", runner_display_name: "Workshop search",
      executor_kind: "tool_provider"
    )
    assert_equal :runner, authorization.branch, "the branch is the credential shape, not the kind"
    assert_equal "tool_provider", authorization.executor_kind
    _path, params, _timeout = @transport.requests.first
    assert_equal "tool_provider", params[:executor_kind]
    assert_equal "workshop-provider", params[:registration_identifier]
    assert_nil params[:agent_identifier]

    credentials = client.poll(authorization)
    assert_predicate credentials, :executor_plane?
    refute_predicate credentials, :member_plane?, "a provider is an address, never a member principal"
  end

  # Branch A fixes the kind: the Authorization says so, and the request
  # carries no selector (a kind on branch A is `invalid_request` at the door).
  def test_an_agent_authorization_fixes_the_agent_application_kind
    client = build_client([[200, {}, AUTH_BODY]])

    authorization = client.request_authorization(
      agent_identifier: "install-1", agent_display_name: "Helper", executor_display_name: "App"
    )

    assert_equal :agent, authorization.branch
    assert_equal "agent_application", authorization.executor_kind
    _path, params, _timeout = @transport.requests.first
    refute params.key?(:executor_kind)
  end

  def test_a_runner_client_cannot_choose_assignment_scope
    # RBS RUNTIME INSTRUMENTATION GETS IN FRONT OF THIS ONE. The claim is
    # that Ruby itself refuses the keyword; under the type hook the call is
    # rejected as a TypeError first, so the assertion cannot see what it is
    # about. The behavior suite runs it for real — this skip costs three
    # assertions on the conformance pass and buys the whole namespace back.
    skip("the RBS hook answers before Ruby's own ArgumentError") if ENV["RBS_TEST_TARGET"]

    client = build_client([[200, {}, AUTH_BODY]])

    assert_raises(ArgumentError) do
      client.request_runner_authorization(
        registration_identifier: "workshop-runner",
        runner_display_name: "Workshop laptop",
        assignment_scope: "account_wide"
      )
    end
    assert_empty @transport.requests
  end

  def test_an_agent_bundle_names_both_planes
    client = build_client([
      [200, {}, AUTH_BODY],
      [200, {}, TOKEN_BODY.merge("executor_access_token" => "sk-cybros-api-v1-transport.z")],
    ])
    authorization = client.request_authorization(
      agent_identifier: "install-1", agent_display_name: "Helper",
      executor_display_name: "App"
    )

    credentials = client.poll(authorization)

    assert_equal "sk-cybros-api-v1-x.y", credentials.access_token
    assert_equal "sk-cybros-api-v1-transport.z", credentials.executor_access_token
    assert_predicate credentials, :member_plane?
    assert_predicate credentials, :executor_plane?
  end

  def test_an_agent_initial_poll_refuses_a_member_only_bundle
    client = build_client([[200, {}, AUTH_BODY], [200, {}, MEMBER_ONLY_TOKEN_BODY]])
    authorization = client.request_authorization(agent_identifier: "i", agent_display_name: "n",
      executor_display_name: "App")

    assert_raises(CybrosAgent::DeviceFlow::AuthorizationLostError) do
      client.poll(authorization)
    end
  end

  def test_a_runner_initial_poll_refuses_a_member_led_bundle
    client = build_client([
      [200, {}, AUTH_BODY],
      [200, {}, TOKEN_BODY],
    ])
    authorization = client.request_runner_authorization(
      registration_identifier: "workshop-runner", runner_display_name: "Workshop laptop"
    )

    assert_raises(CybrosAgent::DeviceFlow::AuthorizationLostError) do
      client.poll(authorization)
    end
  end

  def test_an_agent_initial_poll_refuses_a_transport_only_bundle
    client = build_client([[200, {}, AUTH_BODY], [200, {}, RUNNER_TOKEN_BODY]])
    authorization = client.request_authorization(agent_identifier: "i", agent_display_name: "n",
      executor_display_name: "App")

    assert_raises(CybrosAgent::DeviceFlow::AuthorizationLostError) do
      client.poll(authorization)
    end
  end

  # A runner response that also carried an accompanying credential would mean
  # the server issued a member plane to a machine; the client refuses it
  # rather than silently mislabeling a plane.
  def test_a_response_naming_an_unknown_plane_is_refused
    client = build_client([[200, {}, TOKEN_BODY.merge("plane" => "sovereign")]])

    assert_raises(CybrosAgent::DeviceFlow::AuthorizationLostError) do
      client.rotate(refresh_token: "rt-cybros-api-v1-a.b")
    end
  end

  # The wire says which plane it returned, so a bundle that degenerates to
  # transport-only — a runner, or an agent whose member authority died between
  # connection and rotation — is labeled correctly without the client
  # inferring anything from the request it made.
  def test_a_transport_led_response_is_labeled_from_the_wire_not_the_branch
    client = build_client([[200, {}, RUNNER_TOKEN_BODY]])

    credentials = client.rotate(refresh_token: "rt-cybros-api-v1-a.b")

    assert_nil credentials.access_token
    assert_equal "sk-cybros-api-v1-x.y", credentials.executor_access_token
    refute_predicate credentials, :member_plane?
  end

  def test_rotation_still_accepts_a_member_only_degenerated_bundle
    client = build_client([[200, {}, MEMBER_ONLY_TOKEN_BODY]])

    credentials = client.rotate(refresh_token: "rt-cybros-api-v1-a.b")

    assert_predicate credentials, :member_plane?
    refute_predicate credentials, :executor_plane?
  end

  def test_cancel_authorization_returns_the_typed_lock_winner
    client = build_client([
      [200, {}, nil],
      [409, {}, { "error" => "too_late" }],
    ])
    authorization = authorization_with(deadline_monotonic: 900)

    assert_equal :canceled, client.cancel_authorization(authorization)
    assert_equal :consumed, client.cancel_authorization(authorization)
    assert_equal [
      "/oauth/device_authorization/cancellation",
      "/oauth/device_authorization/cancellation",
    ], @transport.requests.map(&:first)
    @transport.requests.each do |_path, params, _timeout|
      assert_equal CybrosAgent::DeviceFlow::Client::CLIENT_ID, params[:client_id]
      assert_equal authorization.device_code, params[:device_code]
      refute params.key?(:scope)
    end
  end

  def test_cancel_authorization_never_treats_unknown_outcomes_as_safe
    authorization = authorization_with(deadline_monotonic: 900)

    {
      [[400, {}, { "error" => "invalid_grant" }]] =>
        CybrosAgent::DeviceFlow::AuthorizationLostError,
      [[500, {}, nil]] => CybrosAgent::DeviceFlow::ServerError,
      [:connection_error] => CybrosAgent::TransportError,
    }.each do |script, error_class|
      client = build_client(script)

      assert_raises(error_class) { client.cancel_authorization(authorization) }
    end
  end

  def test_a_transport_led_response_carrying_an_accompanying_credential_is_lost
    client = build_client([
      [200, {}, AUTH_BODY],
      [200, {}, RUNNER_TOKEN_BODY.merge("executor_access_token" => "sk-cybros-api-v1-extra.z")],
    ])
    authorization = client.request_runner_authorization(
      registration_identifier: "workshop-runner", runner_display_name: "Workshop laptop"
    )

    assert_raises(CybrosAgent::DeviceFlow::AuthorizationLostError) { client.poll(authorization) }
  end

  def test_ordinary_operations_use_the_configured_total_request_timeout
    client = build_client([
      [200, {}, TOKEN_BODY],
      [200, {}, nil],
    ], request_timeout: 75)

    client.rotate(refresh_token: "rt-cybros-api-v1-a.b")
    client.revoke(token: "sk-cybros-api-v1-x.y")

    assert_equal [75, 75], @transport.requests.map(&:last)
  end

  def test_client_rejects_a_non_positive_request_timeout
    [0, -1, Float::INFINITY, -Float::INFINITY, Float::NAN].each do |request_timeout|
      assert_raises(ArgumentError) do
        CybrosAgent::DeviceFlow::Client.new(
          base_url: "http://example.test",
          transport: FakeTransport.new([]),
          request_timeout: request_timeout
        )
      end
    end
  end

  def test_client_rejects_non_numeric_request_timeouts_with_argument_error
    skip("the RBS Numeric contract rejects these before Ruby's conversion") if ENV["RBS_TEST_TARGET"]

    [nil, false, true, "1", {}, []].each do |request_timeout|
      assert_raises(ArgumentError) do
        CybrosAgent::DeviceFlow::Client.new(base_url: "http://example.test",
          transport: FakeTransport.new([]), request_timeout: request_timeout)
      end
    end
  end

  def test_rotate_returns_a_fresh_pair
    client = build_client([[200, {}, TOKEN_BODY]])
    credentials = client.rotate(refresh_token: "rt-cybros-api-v1-a.b")
    assert_equal "Bearer", credentials.token_type
  end

  def test_rotate_reuse_raises_authorization_lost
    client = build_client([[400, {}, { "error" => "invalid_grant" }]])
    assert_raises(CybrosAgent::DeviceFlow::AuthorizationLostError) { client.rotate(refresh_token: "rt-x") }
  end

  def test_rotate_transport_failure_requires_reconnection
    client = build_client([:connection_error])

    assert_raises(CybrosAgent::DeviceFlow::AuthorizationLostError) do
      client.rotate(refresh_token: "rt-cybros-api-v1-a.b")
    end
    assert_equal 1, @transport.requests.size
  end

  def test_rotate_can_retry_when_the_transport_proves_the_request_was_not_sent
    client = build_client([
      :request_not_sent,
      [200, {}, TOKEN_BODY],
    ])

    assert_raises(CybrosAgent::RequestNotSentError) do
      client.rotate(refresh_token: "rt-cybros-api-v1-a.b")
    end
    credentials = client.rotate(refresh_token: "rt-cybros-api-v1-a.b")

    assert_equal "sk-cybros-api-v1-x.y", credentials.access_token
    assert_equal 2, @transport.requests.size
  end

  def test_revoke_acceptance_returns_nil
    client = build_client([[200, {}, nil]])

    assert_nil client.revoke(token: "sk-cybros-api-v1-x.y")
    path, params = @transport.requests.first
    assert_equal "/oauth/revoke", path
    assert_equal "cybros-first-party-connector", params[:client_id]
  end

  def test_revoke_429_raises_rate_limited_with_retry_after
    client = build_client([[429, { "Retry-After" => "7" }, { "error" => "temporarily_unavailable" }]])

    error = assert_raises(CybrosAgent::DeviceFlow::RateLimited) { client.revoke(token: "sk-x") }
    assert_equal 7, error.retry_after
  end

  def test_revoke_500_raises_a_retryable_server_error
    client = build_client([[500, {}, { "error" => "server_error" }]])

    error = assert_raises(CybrosAgent::DeviceFlow::ServerError) { client.revoke(token: "sk-x") }
    # An unhandled 5xx is classified by status alone; the body's error field
    # is never read into the OAuth vocabulary.
    assert_nil error.oauth_error
    refute_kind_of CybrosAgent::DeviceFlow::AuthorizationLostError, error
  end

  def test_a_bodyless_server_failure_during_rotation_requires_reconnection
    client = build_client([[500, {}, nil]])

    assert_raises(CybrosAgent::DeviceFlow::AuthorizationLostError) do
      client.rotate(refresh_token: "rt-x")
    end
    assert_equal 1, @transport.requests.size
  end

  def test_a_malformed_successful_authorization_response_is_a_typed_server_failure
    client = build_client([[200, {}, "dc-cybros-v1-reflected"]])

    error = assert_raises(CybrosAgent::DeviceFlow::ServerError) do
      client.request_authorization(agent_identifier: "i", agent_display_name: "n",
      executor_display_name: "App")
    end

    refute_includes error.full_message, "dc-cybros-v1-reflected"
  end

  def test_authorization_responses_require_an_object_and_nonempty_string_fields
    bodies = [nil, false, 1, 1.5, AUTH_BODY.to_a]
    %w[device_code user_code verification_uri verification_uri_complete].each do |field|
      [nil, false, true, 1, 1.5, {}, [], ""].each { |value| bodies << AUTH_BODY.merge(field => value) }
    end
    bodies.each do |body|
      client = build_client([[200, {}, body]])
      assert_raises(CybrosAgent::DeviceFlow::ServerError) do
        client.request_authorization(agent_identifier: "i", agent_display_name: "n", executor_display_name: "App")
      end
    end
  end

  def test_authorization_durations_require_positive_json_integers_without_coercion_or_rounding
    %w[interval expires_in].each do |field|
      [nil, false, true, 1.0, 1.5, "1", {}, [], 0, -1].each do |value|
        client = build_client([[200, {}, AUTH_BODY.merge(field => value)]])
        assert_raises(CybrosAgent::DeviceFlow::ServerError, "#{field}: #{value.inspect}") do
          client.request_authorization(agent_identifier: "i", agent_display_name: "n", executor_display_name: "App")
        end
      end
    end
  end

  def test_authorization_links_require_an_absolute_http_or_https_uri
    ["relative/path", "https:/path", "ftp://example.test/path", "file:///tmp/authorization"].each do |uri|
      client = build_client([[200, {}, AUTH_BODY.merge("verification_uri" => uri)]])
      assert_raises(CybrosAgent::DeviceFlow::ServerError) do
        client.request_authorization(agent_identifier: "i", agent_display_name: "n", executor_display_name: "App")
      end
    end
  end

  def test_credentials_require_an_object_and_nonempty_string_tokens
    bodies = [nil, false, 1, 1.5, TOKEN_BODY.to_a]
    %w[access_token refresh_token executor_access_token].each do |field|
      [false, true, 1, 1.5, {}, [], ""].each { |value| bodies << TOKEN_BODY.merge(field => value) }
    end
    bodies.each do |body|
      client = build_client([[200, {}, body]])
      assert_raises(CybrosAgent::DeviceFlow::AuthorizationLostError) { client.rotate(refresh_token: "rt-x") }
    end
  end

  def test_non_object_oauth_errors_remain_unknown_server_failures
    [nil, 1, "access_denied", [["error", "access_denied"]]].each do |body|
      client = build_client([[400, {}, body]])
      error = assert_raises(CybrosAgent::DeviceFlow::ServerError) { client.revoke(token: "sk-x") }
      assert_nil error.oauth_error
    end
  end

  def test_an_authorization_response_cannot_create_a_non_finite_deadline
    body = AUTH_BODY.merge("expires_in" => 10**10_000)
    client = build_client([[200, {}, body]])

    assert_raises(CybrosAgent::DeviceFlow::ServerError) do
      client.request_authorization(agent_identifier: "i", agent_display_name: "n",
      executor_display_name: "App")
    end
  end

  def test_a_malformed_successful_device_consume_loses_the_authorization
    client = build_client([[200, {}, { "access_token" => "sk-cybros-api-v1-unusable" }]])

    error = assert_raises(CybrosAgent::DeviceFlow::AuthorizationLostError) do
      client.poll(authorization_with(deadline_monotonic: 100))
    end

    refute_includes error.full_message, "sk-cybros-api-v1-unusable"
  end

  def test_a_malformed_successful_rotation_loses_the_authorization
    client = build_client([[200, {}, { "refresh_token" => "rt-cybros-api-v1-unusable" }]])

    error = assert_raises(CybrosAgent::DeviceFlow::AuthorizationLostError) do
      client.rotate(refresh_token: "rt-cybros-api-v1-old")
    end

    refute_includes error.full_message, "rt-cybros-api-v1-unusable"
  end

  def test_a_server_returned_invalid_scope_is_invalid_request
    client = build_client([[400, {}, { "error" => "invalid_scope" }]])
    assert_raises(CybrosAgent::DeviceFlow::InvalidRequest) do
      client.request_authorization(agent_identifier: "i", agent_display_name: "n",
      executor_display_name: "App")
    end
  end

  def test_a_rate_limited_start_is_retryable_not_a_dead_connection
    client = build_client([[429, { "Retry-After" => "12" }, { "error" => "temporarily_unavailable" }]])
    error = assert_raises(CybrosAgent::DeviceFlow::RateLimited) do
      client.request_authorization(agent_identifier: "i", agent_display_name: "n",
      executor_display_name: "App")
    end
    assert_equal 12, error.retry_after
    refute_kind_of CybrosAgent::DeviceFlow::AuthorizationLostError, error
  end

  def test_secrets_are_redacted_in_inspection
    auth = CybrosAgent::DeviceFlow::Authorization.new(
      device_code: "dc-secret", user_code: "ABCD-EFGH", verification_uri: "u",
      verification_uri_complete: "u", interval: 5, expires_in: 900, deadline_monotonic: 900,
      branch: :agent, executor_kind: "agent_application"
    )
    refute auth.inspect.include?("dc-secret")
    assert_includes auth.inspect, "[REDACTED]"
    auth_pretty = PP.pp(auth, +"")
    refute auth_pretty.include?("dc-secret")
    assert_includes auth_pretty, "[REDACTED]"

    credentials = CybrosAgent::DeviceFlow::Credentials.new(
      access_token: "sk-secret", refresh_token: "rt-secret", token_type: "Bearer",
      expires_in: 1_209_600, executor_access_token: nil
    )
    refute credentials.inspect.include?("sk-secret")
    refute credentials.inspect.include?("rt-secret")
    credentials_pretty = PP.pp(credentials, +"")
    refute credentials_pretty.include?("sk-secret")
    refute credentials_pretty.include?("rt-secret")
    assert_includes credentials_pretty, "[REDACTED]"
  end

  def test_all_device_flow_diagnostic_objects_redact_every_secret_family
    secrets = %w[
      sk-cybros-api-v1-access.secret
      rt-cybros-api-v1-refresh.secret
      dc-cybros-v1-device.secret
      rc-cybros-v1-recovery.secret
    ]
    response = CybrosAgent::Response.new(
      status: 200,
      headers: { "X-Debug" => secrets.fetch(2) },
      body: {
        "access_token" => secrets.fetch(0),
        "refresh_token" => secrets.fetch(1),
        "recovery_code" => secrets.fetch(3),
      }
    )
    authorization = CybrosAgent::DeviceFlow::Authorization.new(
      device_code: secrets.fetch(2),
      user_code: secrets.fetch(0),
      verification_uri: secrets.fetch(1),
      verification_uri_complete: secrets.fetch(2),
      interval: 5,
      expires_in: 900,
      deadline_monotonic: 900,
      branch: :agent, executor_kind: "agent_application"
    )
    credentials = CybrosAgent::DeviceFlow::Credentials.new(
      access_token: secrets.fetch(0),
      refresh_token: secrets.fetch(1),
      token_type: secrets.fetch(2),
      expires_in: 1_209_600,
      executor_access_token: secrets.fetch(0)
    )

    [response, authorization, credentials].each do |value|
      assert_redacted(value.inspect, secrets)
      assert_redacted(value.to_s, secrets)
      assert_redacted(PP.pp(value, +""), secrets)
      assert_redacted(value.pretty_inspect, secrets)
    end
  end

  def test_error_diagnostics_and_reflected_oauth_errors_are_redacted
    secrets = %w[
      sk-cybros-api-v1-access.secret
      rt-cybros-api-v1-refresh.secret
      dc-cybros-v1-device.secret
      rc-cybros-v1-recovery.secret
    ]
    message = secrets.map { |secret| "prefix_#{secret}" }.join(" ")
    error = CybrosAgent::DeviceFlow::ServerError.new(message, oauth_error: secrets.fetch(0))

    assert_redacted(error.message, secrets)
    assert_redacted(error.inspect, secrets)
    assert_redacted(error.full_message, secrets)
    assert_redacted(error.oauth_error, secrets)

    client = build_client([[400, {}, { "error" => secrets.fetch(1) }]])
    reflected = assert_raises(CybrosAgent::DeviceFlow::ServerError) do
      client.request_authorization(agent_identifier: "i", agent_display_name: "n",
      executor_display_name: "App")
    end
    assert_redacted(reflected.message, secrets)
    assert_redacted(reflected.inspect, secrets)
    assert_redacted(reflected.oauth_error, secrets)
  end

  private

    def assert_redacted(output, secrets)
      secrets.each { |secret| refute_includes output, secret }
      assert_includes output, "[REDACTED]"
    end
end
