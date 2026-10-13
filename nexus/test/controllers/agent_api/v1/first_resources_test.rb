require "test_helper"

# The two first resources open the two directions (Round D plan): /profile is
# the member plane's bootstrap discovery, /executor the executor plane's
# self-description.
class AgentAPI::V1::FirstResourcesTest < ActionDispatch::IntegrationTest
  setup do
    @agent = users(:agent)
    @executor = task_executors(:address)
  end

  test "profile answers the required identity and credential blocks" do
    credential = create_access_token_fixture(user: users(:member), name: "M")

    get agent_api_v1_profile_path, headers: bearer(credential.secret)

    assert_response :success
    body = response.parsed_body
    assert_equal users(:member).public_id, body.dig("member", "public_id")
    assert_equal "human", body.dig("member", "kind")
    assert_equal "member", body.dig("credential", "plane")
    assert body["measured_at"].present?
    # Blocks whose domain has not shipped are absent rather than typed
    # unavailable (Round D plan).
    assert_not body.key?("spend")
  end

  # A profile has at most one delivery address. This accepted connection has one, but the member
  # plane never answers with the caller's own address. So there is no address block at all.
  test "the member plane reports no delivery address, not even the caller's own" do
    grant = connect_and_consume
    member_secret = grant.access_secret

    get agent_api_v1_profile_path, headers: bearer(member_secret)

    assert_response :success
    body = response.parsed_body
    assert_equal "agent", body.dig("member", "kind")
    assert_predicate TaskExecutor.address_for(@agent), :present?
    assert_not body.key?("executor")
    assert_equal %w[configuration credential measured_at member], body.keys.sort
  end

  test "executor answers its own address without any member call" do
    transport = create_bound_credential(executor: @executor, name: "T")

    get agent_api_v1_executor_path, headers: bearer(transport.secret)

    assert_response :success
    body = response.parsed_body
    assert_equal @executor.public_id, body.dig("executor", "public_id")
    assert_equal "agent_application", body.dig("executor", "kind")
    assert_equal "active", body.dig("executor", "status")
    assert_equal @executor.credential_epoch, body.dig("executor", "credential_epoch")
    # The transport plane describes an address, never a member.
    assert_not body.key?("member")
  end

  # PRESENCE on the self-description (r-modes M4): honest and tautological —
  # this read is an executor-plane request, so the contact sample is fresh
  # and `not_yet_seen` is unreachable over HTTP; the word comes from the
  # socket's mark, which an HTTP read never sets.
  test "the executor's self-description carries its presence beside the contact sample" do
    NexusServer.register
    transport = create_bound_credential(executor: @executor, name: "T")

    get agent_api_v1_executor_path, headers: bearer(transport.secret)
    assert_response :success
    described = response.parsed_body.fetch("executor")
    assert_equal "offline", described.fetch("presence"), "an HTTP read is contact, never a socket"
    assert_equal @executor.reload.last_seen_at.iso8601, described.fetch("last_seen_at")
    assert_nil described.fetch("connected_at")

    @executor.mark_connected("socket-1")
    get agent_api_v1_executor_path, headers: bearer(transport.secret)
    described = response.parsed_body.fetch("executor")
    assert_equal "online", described.fetch("presence")
    assert_equal @executor.reload.connected_at.iso8601, described.fetch("connected_at")

    @executor.clear_connected("socket-1")
    get agent_api_v1_executor_path, headers: bearer(transport.secret)
    assert_equal "offline", response.parsed_body.dig("executor", "presence")
  end

  test "an epoch advance fences the transport credential immediately" do
    transport = create_bound_credential(executor: @executor, name: "T")
    advance_credential_epoch(@executor)

    get agent_api_v1_executor_path, headers: bearer(transport.secret)

    assert_response :unauthorized
  end

  private

    def bearer(secret)
      { "Authorization" => "Bearer #{secret}" }
    end

    # A real connection so the member half of the bundle is the credential
    # under test, not a fixture shortcut.
    def connect_and_consume
      grant = DeviceAuthorizations::Issue.call(
        account: accounts(:cybros), agent_identifier: @agent.agent_identifier,
        agent_display_name: "Bundle",         requested_executor_display_name: "Bundle app").authorization
      DeviceAuthorizations::Connect.call(authorization: grant, connector: users(:owner))
      DeviceAuthorizations::Consume.call(authorization: grant.reload)
    end
end
