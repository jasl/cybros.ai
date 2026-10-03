require "test_helper"

class OAuth::DeviceAuthorizationsControllerTest < ActionDispatch::IntegrationTest
  # An agent connection always requests its delivery address, so the address fields are part of the
  # minimal valid request rather than an optional extra a test opts into.
  BASE = {
    client_id: OAuth::DEVICE_CLIENT_ID,
    agent_identifier: "install-abc123",
    agent_display_name: "Helper",
    executor_display_name: "Helper app",
  }.freeze

  def request_authorization(overrides = {})
    post oauth_device_authorization_path, params: BASE.merge(overrides).compact
  end

  test "success returns the RFC shape under no-store" do
    host! "192.168.1.20:3300"
    request_authorization

    assert_response :success
    assert_equal "no-store", response.headers["Cache-Control"]
    assert_equal "no-cache", response.headers["Pragma"]

    body = response.parsed_body
    assert body["device_code"].start_with?("dc-cybros-v1-")
    assert_match(/\A[A-Z]{4}-[A-Z]{4}\z/, body["user_code"])
    assert_equal "http://192.168.1.20:3300/oauth/device", body["verification_uri"]
    assert_equal(
      "http://192.168.1.20:3300/oauth/device?user_code=#{body.fetch("user_code")}",
      body["verification_uri_complete"]
    )
    assert_equal 900, body["expires_in"]
    assert_equal 5, body["interval"]

    authorization = DeviceAuthorization.order(:id).last
    assert_nil authorization.requested_executor_kind, "an Agent connection has one kind and names none"
  end

  # Branch B names its machine kind: `runner` by default, `tools_provider` on request; the value is
  # frozen on the request row and consume mints it.
  test "a runner connection records the runner kind by default" do
    post oauth_device_authorization_path, params: {
      client_id: OAuth::DEVICE_CLIENT_ID,
      runner_identifier: "workshop-install",
      runner_display_name: "Workshop laptop",
    }

    assert_response :success
    assert_equal "runner", DeviceAuthorization.order(:id).last.requested_executor_kind
  end

  test "a runner connection requesting the tools_provider kind records it" do
    post oauth_device_authorization_path, params: {
      client_id: OAuth::DEVICE_CLIENT_ID,
      runner_identifier: "provider-install",
      runner_display_name: "Provider box",
      executor_kind: "tools_provider",
    }

    assert_response :success
    authorization = DeviceAuthorization.order(:id).last
    assert_equal "tools_provider", authorization.requested_executor_kind
    assert_predicate authorization, :runner_only_connection?
  end

  test "a kind outside the machine vocabulary on branch B is invalid_request" do
    assert_no_difference -> { DeviceAuthorization.count } do
      post oauth_device_authorization_path, params: {
        client_id: OAuth::DEVICE_CLIENT_ID,
        runner_identifier: "workshop-install",
        runner_display_name: "Workshop laptop",
        executor_kind: "mainframe",
      }
    end
    assert_equal "invalid_request", response.parsed_body["error"]
  end

  test "an agent connection may not name a kind: agent_application is fixed by the branch" do
    %w[tools_provider agent_application mainframe].each do |kind|
      assert_no_difference -> { DeviceAuthorization.count }, kind do
        request_authorization(executor_kind: kind)
      end
      assert_equal "invalid_request", response.parsed_body["error"], kind
    end
  end

  # The Runner program identifies its product and machine display only.
  # Assignment placement is a later browser decision, not a machine claim.
  test "a runner connection is identity-less and leaves assignment for Connect" do
    post oauth_device_authorization_path, params: {
      client_id: OAuth::DEVICE_CLIENT_ID,
      runner_identifier: "workshop-install",
      runner_display_name: "Workshop laptop",
      assignment_scope: "account_wide",
    }

    assert_response :success
    grant = DeviceAuthorization.find_by_device_code(response.parsed_body.fetch("device_code"))
    assert_predicate grant, :runner_only_connection?
    assert_nil grant.agent_identifier
    assert_nil grant.selected_assignment_scope,
      "the machine's unknown assignment_scope field must not choose placement"
  end

  # The combined shape A+B (r-modes M2): the COMPLETE agent triple and the
  # COMPLETE runner pair on one request is an agent that also serves as a
  # runner on its own machine. Its kind is fixed `runner` and its scope fixed
  # `user_private` at issuance; the half cases below stay a mix.
  test "the complete agent triple with the complete runner pair is the combined shape" do
    post oauth_device_authorization_path, params: BASE.merge(
      runner_identifier: "rho",
      runner_display_name: "rho on laptop"
    )

    assert_response :success
    grant = DeviceAuthorization.find_by_device_code(response.parsed_body.fetch("device_code"))
    assert_predicate grant, :combined_connection?
    refute_predicate grant, :runner_only_connection?
    assert_equal "install-abc123", grant.agent_identifier
    assert_equal "rho", grant.runner_identifier
    assert_equal "runner", grant.requested_executor_kind
    assert_equal "user_private", grant.selected_assignment_scope
  end

  test "a kind other than runner on a combined request is invalid_request" do
    %w[tools_provider agent_application mainframe].each do |kind|
      assert_no_difference -> { DeviceAuthorization.count }, kind do
        post oauth_device_authorization_path, params: BASE.merge(
          runner_identifier: "rho",
          runner_display_name: "rho on laptop",
          executor_kind: kind
        )
      end
      assert_equal "invalid_request", response.parsed_body["error"], kind
    end
  end

  test "a combined request may spell the runner kind it is fixed to" do
    post oauth_device_authorization_path, params: BASE.merge(
      runner_identifier: "rho",
      runner_display_name: "rho on laptop",
      executor_kind: "runner"
    )

    assert_response :success
    assert_predicate DeviceAuthorization.order(:id).last, :combined_connection?
  end

  # Combined = both sets complete; a half triple or a half pair is still a
  # mix. Each Branch A field alone must trip the guard — the enumeration once
  # omitted executor_display_name, and a runner request carrying it was accepted with the field
  # silently dropped rather than refused as the contract promises.
  test "every Branch A field alone poisons a runner request" do
    { agent_identifier: "install-x", agent_display_name: "App",
      executor_display_name: "App" }.each do |field, value|
      assert_no_difference -> { DeviceAuthorization.count } do
        post oauth_device_authorization_path, params: {
          client_id: OAuth::DEVICE_CLIENT_ID,
          runner_identifier: "workshop-install",
          runner_display_name: "Workshop laptop",
          field => value,
        }
      end

      assert_response :bad_request, "#{field} must poison the runner branch"
      assert_equal "invalid_request", response.parsed_body["error"]
    end
  end

  # runner_identifier selects Branch B, but its sibling fields still belong
  # exclusively to that branch and must not be silently discarded by Branch A;
  # a runner pair missing its identifier is a half pair, never the combined shape.
  test "every Branch B-only field alone poisons an agent request" do
    {
      runner_display_name: "Workshop laptop",
    }.each do |field, value|
      assert_no_difference -> { DeviceAuthorization.count } do
        request_authorization(field => value)
      end

      assert_response :bad_request, "#{field} must poison the agent branch"
      assert_equal "invalid_request", response.parsed_body["error"]
    end
  end

  test "verification URLs follow the direct request origin without a configured domain" do
    host! "10.0.0.20:8443"
    post oauth_device_authorization_path, params: BASE

    assert_response :success
    body = response.parsed_body
    assert_equal "http://10.0.0.20:8443/oauth/device", body["verification_uri"]
    assert_equal(
      "http://10.0.0.20:8443/oauth/device?user_code=#{body.fetch("user_code")}",
      body["verification_uri_complete"]
    )
  end

  test "a configured domain origin overrides the request origin completely" do
    with_route_url_options(
      { host: "nexus.example", protocol: "https", port: 443 }
    ) do
      host! "untrusted.example:8443"
      post oauth_device_authorization_path,
        params: BASE,
        headers: {
          "Forwarded" => "host=forwarded.example:9443;proto=http",
          "X-Forwarded-Host" => "forwarded.example:9443",
          "X-Forwarded-Proto" => "http",
        }

      assert_response :success
      body = response.parsed_body
      assert_equal "https://nexus.example/oauth/device", body["verification_uri"]
      assert_equal(
        "https://nexus.example/oauth/device?user_code=#{body.fetch("user_code")}",
        body["verification_uri_complete"]
      )
    end
  end

  test "a wrong or missing client is invalid_client" do
    request_authorization(client_id: "impostor")
    assert_response :bad_request
    assert_equal "invalid_client", response.parsed_body["error"]

    request_authorization(client_id: nil)
    assert_equal "invalid_client", response.parsed_body["error"]
  end

  # One request each so the 6/min IP limiter never colours a shape assertion.
  {
    "a blank identifier" => { agent_identifier: nil },
    "a whitespace-padded identifier" => { agent_identifier: " padded " },
    "an over-long name" => { agent_display_name: "x" * 101 },
    "no executor display name" => { executor_display_name: nil },
    "an array where a scalar is required" => { agent_identifier: %w[a b] },
  }.each do |description, overrides|
    test "#{description} is invalid_request and creates no grant" do
      assert_no_difference -> { DeviceAuthorization.count } do
        request_authorization(overrides)
      end
      assert_equal "invalid_request", response.parsed_body["error"]
    end
  end

  test "unknown parameters are behaviorally inert" do
    request_authorization(mystery: "ignored")
    assert_response :success
  end

  test "transport throttling keeps the OAuth envelope and Retry-After" do
    7.times do |index|
      request_authorization(agent_identifier: "install-rate-#{index}")
    end

    assert_response :too_many_requests
    assert_equal({ "error" => "temporarily_unavailable" }, response.parsed_body)
    assert_equal "60", response.headers["Retry-After"]
  end

  test "a duplicated scalar field is invalid_request" do
    post "#{oauth_device_authorization_path}?client_id=#{OAuth::DEVICE_CLIENT_ID}",
      params: BASE
    assert_equal "invalid_request", response.parsed_body["error"]
  end

  test "a JSON body spelling one key twice is invalid_request (re-audit)" do
    body = %({"client_id":"wrong","client_id":#{OAuth::DEVICE_CLIENT_ID.to_json}})
    post oauth_device_authorization_path, params: body,
      headers: { "Content-Type" => "application/json" }
    assert_response :bad_request
    assert_equal "no-store", response.headers["Cache-Control"]
    assert_equal "no-cache", response.headers["Pragma"]
    assert_equal "invalid_request", response.parsed_body["error"],
      "duplicated scalar fields must return invalid_request on both JSON and form transports"
  end

  # The closing review's escape bypass: a raw-text scan sees "client_id" and
  # "client_id" as different strings, but the parser decodes them to one
  # duplicated key. The count must run over decoded names.
  test "a JSON duplicate key spelled with a unicode escape is still invalid_request (re-audit)" do
    escaped = "\\u0063lient_id" # "client_id"
    body = %({"#{escaped}":"wrong","client_id":#{OAuth::DEVICE_CLIENT_ID.to_json}})
    assert_no_difference -> { DeviceAuthorization.count } do
      post oauth_device_authorization_path, params: body,
        headers: { "Content-Type" => "application/json" }
    end
    assert_equal "invalid_request", response.parsed_body["error"],
      "the escaped and plain spellings are one key after decoding; the guard must not fail open"
  end

  # The scan's benign false positive, now also closed: a key-shaped string
  # inside a VALUE is not an object key and must not trip the guard.
  test "a key-shaped substring in a JSON value does not falsely reject (re-audit)" do
    body = %({"client_id":#{OAuth::DEVICE_CLIENT_ID.to_json},) +
      %("agent_identifier":"install-x","agent_display_name":"has \\"client_id\\": inside",) +
      %("executor_display_name":"App"})
    post oauth_device_authorization_path, params: body,
      headers: { "Content-Type" => "application/json" }
    assert_response :success, "only real duplicate KEYS are ambiguous, not value text"
  end

  test "scope follows the machine scalar contract but has no authorization meaning" do
    assert_difference -> { DeviceAuthorization.count }, 1 do
      request_authorization(scope: "member")
    end
    assert_response :success

    assert_no_difference -> { DeviceAuthorization.count } do
      request_authorization(scope: ["member"])
    end
    assert_equal "invalid_request", response.parsed_body["error"]

    assert_no_difference -> { DeviceAuthorization.count } do
      post "#{oauth_device_authorization_path}?scope=member",
        params: BASE.merge(scope: "member")
    end
    assert_equal "invalid_request", response.parsed_body["error"]

    request_authorization(scope: "")
    assert_response :success
  end

  private

    def with_route_url_options(options)
      previous = Rails.application.routes.default_url_options.dup
      Rails.application.routes.default_url_options = options.dup
      yield
    ensure
      Rails.application.routes.default_url_options = previous
    end
end
