require "test_helper"

class OAuth::DeviceAuthorizationCancellationsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @account = accounts(:cybros)
    @owner = users(:owner)
  end

  test "a pending or connected authorization returns safe without echoing the secret" do
    pending = mint(identifier: "cancel-wire-pending")
    post_cancel(device_code: pending.device_code)

    assert_response :success
    assert_equal "", response.body
    assert_equal "no-store", response.headers["Cache-Control"]
    assert_predicate pending.authorization.reload, :canceled?

    connected = mint(identifier: "cancel-wire-connected")
    connected.authorization.record_connection(
      user: nil,
      connector: @owner,
      expected_task_executor: nil
    )
    post_cancel(device_code: connected.device_code)

    assert_response :success
    assert_equal "", response.body
    assert_not_includes response.body, connected.device_code
    assert_predicate connected.authorization.reload, :canceled?
  end

  test "a consumed authorization returns typed too_late without changing evidence" do
    mint = mint(identifier: "cancel-wire-consumed")
    mint.authorization.record_connection(
      user: nil,
      connector: @owner,
      expected_task_executor: nil
    )
    assert_equal :minted,
      DeviceAuthorizations::Consume.call(authorization: mint.authorization).outcome

    post_cancel(device_code: mint.device_code)

    assert_response :conflict
    assert_equal({ "error" => "too_late" }, response.parsed_body)
    assert_not_includes response.body, mint.device_code
    assert_predicate mint.authorization.reload, :consumed?
    assert_not_nil mint.authorization.access_token_id
  end

  test "safe terminal states are idempotent" do
    %w[canceled expired invalidated].each do |status|
      mint = mint(identifier: "cancel-wire-#{status}")
      DeviceAuthorization.where(id: mint.authorization.id).update_all(status: status)

      2.times do
        post_cancel(device_code: mint.device_code)
        assert_response :success
        assert_equal "", response.body
      end
      assert_equal status, mint.authorization.reload.status
    end
  end

  test "an unknown or wrong secret fails closed without becoming a safe answer" do
    mint = mint(identifier: "cancel-wire-secret")

    [mint.device_code.sub(/.\z/, "x"), "garbage"].each do |secret|
      post_cancel(device_code: secret)

      assert_response :bad_request
      assert_equal({ "error" => "invalid_grant" }, response.parsed_body)
      assert_not_includes response.body, secret
    end
    assert_predicate mint.authorization.reload, :pending?
  end

  test "client device code and compatibility scope use the machine scalar contract" do
    mint = mint(identifier: "cancel-wire-scalars")

    post_cancel(client_id: "other", device_code: mint.device_code)
    assert_equal "invalid_client", response.parsed_body["error"]

    post_cancel(device_code: nil)
    assert_equal "invalid_request", response.parsed_body["error"]

    post_cancel(device_code: [mint.device_code])
    assert_equal "invalid_request", response.parsed_body["error"]

    post_cancel(device_code: mint.device_code, scope: [""])
    assert_equal "invalid_request", response.parsed_body["error"]

    post "#{oauth_device_authorization_cancellation_path}?scope=member",
      params: {
        client_id: OAuth::DEVICE_CLIENT_ID,
        device_code: mint.device_code,
        scope: "member",
      }
    assert_equal "invalid_request", response.parsed_body["error"]

    post_cancel(device_code: mint.device_code, scope: "member", unknown: "ignored")
    assert_response :success
    assert_predicate mint.authorization.reload, :canceled?
  end

  private

    def mint(identifier:)
      DeviceAuthorizations::Issue.call(
        account: @account,
        agent_identifier: identifier,
        agent_display_name: "Wire cancel",
        requested_executor_display_name: "Wire cancel app"
      )
    end

    def post_cancel(overrides = {})
      post oauth_device_authorization_cancellation_path,
        params: {
          client_id: OAuth::DEVICE_CLIENT_ID,
        }.merge(overrides).compact
    end
end
