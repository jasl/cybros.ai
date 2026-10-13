require "test_helper"
require "pp"

# The two API planes and the containment that relates them: an
# agent program holds member authority *and* is a delivery address; a runner
# is only a delivery address. One gem serves both by composing planes from
# whatever credentials a connection produced — never by shipping a second SDK.
class ApiPlanesTest < Minitest::Test
  FakeTransport = CybrosAgentTest::FakeTransport

  PROFILE_BODY = {
    "member" => {
      "public_id" => "019f0000-0000-7000-8000-000000000001",
      "handle" => "notes", "kind" => "agent", "role" => "member", "display_name" => "Notes assistant",
    },
    "credential" => { "plane" => "member", "expires_at" => "2026-08-08T00:00:00Z" },
    "measured_at" => "2026-07-25T00:00:00Z",
  }.freeze

  EXECUTOR_BODY = {
    "executor" => {
      "public_id" => "019f0000-0000-7000-8000-000000000002",
      "kind" => "agent_application", "status" => "active",
      "display_name" => "MacBook Pro", "credential_epoch" => 1,
      "presence" => "offline",
    },
    "measured_at" => "2026-07-25T00:00:00Z",
  }.freeze

  def member_client(script)
    @transport = FakeTransport.new(script)
    CybrosAgent::Client.new(base_url: "http://example.test", credential: "sk-member", transport: @transport)
  end

  def executor_client(script)
    @transport = FakeTransport.new(script)
    CybrosAgent::ExecutorClient.new(base_url: "http://example.test", credential: "sk-transport", transport: @transport)
  end

  def test_the_member_plane_reads_its_own_profile
    profile = member_client([[200, {}, PROFILE_BODY]]).profile.fetch

    assert_equal "019f0000-0000-7000-8000-000000000001", profile.member.public_id
    assert_equal "agent", profile.member.kind
    assert_equal "member", profile.member.role
    assert_equal "Notes assistant", profile.member.display_name
    assert_equal "member", profile.credential.plane
    assert_equal "2026-08-08T00:00:00Z", profile.credential.expires_at
    assert_equal "2026-07-25T00:00:00Z", profile.measured_at
    assert_equal %i[member credential configuration measured_at], profile.members,
      "the member plane carries no delivery address"

    request = @transport.requests.fetch(0)
    assert_equal 1, @transport.requests.length
    assert_equal "/agent_api/v1/profile", request.fetch(:path)
    assert_equal "sk-member", request.fetch(:credential)
  end

  # Version skew in the tolerant direction: a Nexus emitting a block this
  # version does not know is read past, not refused. The SDK's contract is
  # the blocks it names, and an unknown one is somebody else's business.
  def test_a_profile_carrying_a_block_this_version_does_not_know_is_read_past
    body = PROFILE_BODY.merge(
      "newer_block" => { "public_id" => "019f0000-0000-7000-8000-000000000002" }
    )

    profile = member_client([[200, {}, body]]).profile.fetch

    assert_equal "member", profile.credential.plane
    assert_equal %i[member credential configuration measured_at], profile.members
  end

  def test_the_executor_plane_describes_its_own_address
    description = executor_client([[200, {}, EXECUTOR_BODY]]).executor

    assert_equal "019f0000-0000-7000-8000-000000000002", description.executor.public_id
    assert_equal "agent_application", description.executor.kind
    assert_equal "active", description.executor.status
    assert_equal "MacBook Pro", description.executor.display_name
    assert_equal 1, description.executor.credential_epoch

    request = @transport.requests.fetch(0)
    assert_equal 1, @transport.requests.length
    assert_equal "/agent_api/v1/executor", request.fetch(:path)
    assert_equal "sk-transport", request.fetch(:credential)
  end

  # PRESENCE beside the address, and a field the server sent in the wrong
  # type is still MalformedResponse.
  def test_the_executor_description_reads_presence_and_its_stamps_when_present
    body = EXECUTOR_BODY.merge("executor" => EXECUTOR_BODY.fetch("executor").merge(
      "presence" => "online", "last_seen_at" => "2026-07-25T00:00:00Z", "connected_at" => "2026-07-25T00:00:01Z"
    ))
    description = executor_client([[200, {}, body]]).executor

    assert_equal "online", description.executor.presence
    assert_equal "2026-07-25T00:00:00Z", description.executor.last_seen_at
    assert_equal "2026-07-25T00:00:01Z", description.executor.connected_at
  end

  def test_a_presence_of_the_wrong_type_is_malformed
    body = EXECUTOR_BODY.merge("executor" => EXECUTOR_BODY.fetch("executor").merge("presence" => 1))

    assert_raises(CybrosAgent::Api::MalformedResponse) { executor_client([[200, {}, body]]).executor }
  end

  # THE ANNOUNCEMENT: what this address serves, replaced
  # whole, answered with the same description the bootstrap read renders.
  # The entries travel as given — the kernel validates the vocabulary and
  # refuses its reserved namespaces and squatted names; the SDK lowers nothing.
  def test_the_executor_plane_announces_what_it_serves_and_reads_its_description_back
    tools = [
      { "name" => "read", "effect_profile" => READ_ONLY },
      { "name" => "bash", "effect_profile" => READ_ONLY.merge("kind" => "write"), "timeout_ms" => 30_000 },
    ]

    description = executor_client([[200, {}, EXECUTOR_BODY]]).announce(tools: tools)

    assert_equal "019f0000-0000-7000-8000-000000000002", description.executor.public_id
    assert_equal "agent_application", description.executor.kind
    assert_equal "2026-07-25T00:00:00Z", description.measured_at

    request = @transport.requests.fetch(0)
    assert_equal 1, @transport.requests.length
    assert_equal "/agent_api/v1/executor/announcement", request.fetch(:path)
    assert_equal :put, request.fetch(:method)
    assert_equal({ "tools" => tools }, request.fetch(:body), "the entries ride as given, under `tools`")
    assert_equal "sk-transport", request.fetch(:credential)
  end

  # The environment document rides beside the list when given —
  # opaque here as everywhere — and is omitted, not sent as null, when not.
  def test_the_executor_plane_announces_an_environment_document_beside_the_list
    tools = [{ "name" => "read", "effect_profile" => READ_ONLY, "description" => "Read a file",
               "input_schema" => { "type" => "object", "properties" => {} } }]
    environment = { "root" => "/w", "fragments" => [{ "extension" => "rho.coding", "text" => "Relative paths" }] }

    executor_client([[200, {}, EXECUTOR_BODY]]).announce(tools: tools, environment: environment)

    request = @transport.requests.fetch(0)
    assert_equal "/agent_api/v1/executor/announcement", request.fetch(:path)
    assert_equal :put, request.fetch(:method)
    assert_equal({ "tools" => tools, "environment" => environment }, request.fetch(:body),
      "the entries and the document ride as given")
  end

  # The documents: the third list, riding as given
  # when given and omitted — never sent as null — when not.
  def test_the_executor_plane_announces_the_documents_it_can_load_beside_the_list
    tools = [{ "name" => "skill", "effect_profile" => READ_ONLY }]
    documents = [{ "name" => "deploy-notes", "description" => "How this project is deployed." }]

    executor_client([[200, {}, EXECUTOR_BODY]]).announce(tools: tools, documents: documents)

    request = @transport.requests.fetch(0)
    assert_equal :put, request.fetch(:method)
    assert_equal({ "tools" => tools, "documents" => documents }, request.fetch(:body),
      "the documents ride as given; no environment key when none was given")

    executor_client([[200, {}, EXECUTOR_BODY]]).announce(tools: tools, environment: { "root" => "/w" }, documents: [])
    assert_equal({ "tools" => tools, "environment" => { "root" => "/w" }, "documents" => [] },
      @transport.requests.fetch(0).fetch(:body), "an empty list is sent: it clears")
  end

  def test_an_announcement_naming_a_reserved_namespace_is_an_invalid_request_carrying_the_kernels_code
    error = assert_raises(CybrosAgent::Api::InvalidRequest) do
      executor_client([[422, {}, { "error" => { "code" => "reserved_namespace",
                                                "message" => "tools[0].name names a reserved kernel namespace (nexus.graph)" } }]])
        .announce(tools: [{ "name" => "nexus.graph.private_tool", "effect_profile" => READ_ONLY }])
    end

    assert_equal "reserved_namespace", error.code
  end

  def test_an_announcement_naming_a_kernel_tool_is_an_invalid_request_carrying_the_kernels_code
    error = assert_raises(CybrosAgent::Api::InvalidRequest) do
      executor_client([[422, {}, { "error" => { "code" => "reserved_tool_name", "message" => "delegate_task is the kernel's" } }]])
        .announce(tools: [{ "name" => "delegate_task", "effect_profile" => READ_ONLY }])
    end

    assert_equal "reserved_tool_name", error.code
    assert_equal "delegate_task is the kernel's", error.message
  end

  READ_ONLY = {
    "kind" => "read_only", "destructive" => false, "effect_scope" => "closed",
    "idempotency" => "intrinsic", "reconciliation" => "none",
  }.freeze

  def test_clients_do_not_expose_raw_path_dispatch
    refute_respond_to member_client([]), :call
    refute_respond_to member_client([]), :get
    refute_respond_to executor_client([]), :call
    refute_respond_to executor_client([]), :get
    assert_respond_to executor_client([]), :announce
    # The executing half is the executor plane's alone: a member
    # bearer holds no inbox door.
    assert_respond_to executor_client([]), :inbox
    assert_respond_to executor_client([]), :inbox_task
    refute_respond_to member_client([]).workspace("019f0000-0000-7000-8000-000000000101"), :run_task_inbox
    assert_raises(NameError) { CybrosAgent::Api::Dispatch }
  end

  # The family answers 401 for a credential of the other plane exactly as it
  # does for a revoked or fenced one: the type says the
  # credential is not accepted here, and deliberately not why.
  def test_a_rejected_credential_is_one_typed_unauthorized
    error = assert_raises(CybrosAgent::Api::Unauthorized) do
      member_client([[401, {}, { "error" => { "code" => "unauthorized" } }]]).profile.fetch
    end
    assert_equal "unauthorized", error.code

    assert_raises(CybrosAgent::Api::Unauthorized) do
      executor_client([[401, {}, { "error" => { "code" => "unauthorized" } }]]).executor
    end
  end

  def test_status_classes_map_to_exactly_one_error_each
    {
      403 => CybrosAgent::Api::Forbidden,
      404 => CybrosAgent::Api::NotFound,
      409 => CybrosAgent::Api::Conflict,
      413 => CybrosAgent::Api::ContentTooLarge,
      422 => CybrosAgent::Api::InvalidRequest,
      500 => CybrosAgent::Api::ServerError,
      503 => CybrosAgent::Api::ServerError,
    }.each do |status, error_class|
      assert_raises(error_class) do
        member_client([[status, {}, { "error" => { "code" => "x", "message" => "y" } }]]).profile.fetch
      end
    end
  end

  def test_throttling_is_retryable_and_carries_its_delay
    error = assert_raises(CybrosAgent::Api::RateLimited) do
      member_client([[429, { "Retry-After" => "12" }, { "error" => { "code" => "rate_limited" } }]]).profile.fetch
    end

    assert_equal 12, error.retry_after
    assert_equal "rate_limited", error.code
  end

  def test_throttling_preserves_an_unknown_business_error_code
    error = assert_raises(CybrosAgent::Api::RateLimited) do
      member_client([
        [429, { "Retry-After" => "12" }, { "error" => { "code" => "zz_unknown_value" } }],
      ]).profile.fetch
    end

    assert_equal 12, error.retry_after
    assert_equal "zz_unknown_value", error.code
  end

  def test_a_malformed_payload_is_typed_rather_than_a_nil_chain
    [nil, "not json", { "member" => {} }].each do |body|
      assert_raises(CybrosAgent::Api::MalformedResponse) do
        member_client([[200, {}, body]]).profile.fetch
      end
    end
  end

  def test_a_transport_failure_surfaces_as_itself
    assert_raises(CybrosAgent::TransportError) { member_client([:connection_error]).profile.fetch }
  end

  # The containment table: each connection outcome yields exactly
  # the planes its credentials support, and the gem composes them for the
  # caller instead of making every host re-derive the rule.
  def test_planes_compose_from_whatever_the_connection_produced
    bundle = CybrosAgent::DeviceFlow::Credentials.new(
      access_token: "sk-member", refresh_token: "rt-1", token_type: "Bearer", expires_in: 1_209_600,
      executor_access_token: "sk-transport"
    )
    planes = CybrosAgent.planes_for(bundle, base_url: "http://example.test")

    assert_instance_of CybrosAgent::Client, planes.client
    assert_instance_of CybrosAgent::ExecutorClient, planes.executor_client

    member_only = CybrosAgent::DeviceFlow::Credentials.new(
      access_token: "sk-member", refresh_token: "rt-1", token_type: "Bearer", expires_in: 1_209_600,
      executor_access_token: nil
    )
    member_planes = CybrosAgent.planes_for(member_only, base_url: "http://example.test")
    assert_instance_of CybrosAgent::Client, member_planes.client
    assert_nil member_planes.executor_client

    runner = CybrosAgent::DeviceFlow::Credentials.new(
      access_token: nil, refresh_token: "rt-1", token_type: "Bearer", expires_in: 1_209_600,
      executor_access_token: "sk-transport"
    )
    runner_planes = CybrosAgent.planes_for(runner, base_url: "http://example.test")
    assert_nil runner_planes.client, "a runner is a delivery address, never a member principal"
    assert_instance_of CybrosAgent::ExecutorClient, runner_planes.executor_client
    assert_nil runner_planes.runner_client
    assert_nil planes.runner_client, "an agent bundle carries no second address"

    # The combined shape: three planes, the third an executor
    # client on the runner's own credential.
    combined = CybrosAgent::DeviceFlow::Credentials.new(
      access_token: "sk-member", refresh_token: "rt-1", token_type: "Bearer", expires_in: 1_209_600,
      executor_access_token: "sk-transport",
      runner_access_token: "sk-runner", runner_refresh_token: "rt-2"
    )
    combined_planes = CybrosAgent.planes_for(combined, base_url: "http://example.test")
    assert_instance_of CybrosAgent::Client, combined_planes.client
    assert_instance_of CybrosAgent::ExecutorClient, combined_planes.executor_client
    assert_instance_of CybrosAgent::ExecutorClient, combined_planes.runner_client
    refute_same combined_planes.executor_client, combined_planes.runner_client
    assert_equal %i[client executor_client runner_client], combined_planes.members
  end

  def test_credentials_report_which_planes_they_carry
    runner = CybrosAgent::DeviceFlow::Credentials.new(
      access_token: nil, refresh_token: "rt-1", token_type: "Bearer", expires_in: 1,
      executor_access_token: "sk-transport"
    )

    assert_predicate runner, :executor_plane?
    refute_predicate runner, :member_plane?
  end

  def test_every_diagnostic_redacts_the_credential
    client = CybrosAgent::Client.new(
      base_url: "http://example.test", credential: "sk-cybros-api-v1-secret.value",
      transport: FakeTransport.new([])
    )

    [client.inspect, client.to_s, PP.pp(client, +"")].each do |diagnostic|
      refute_includes diagnostic, "secret.value"
      assert_includes diagnostic, "[REDACTED]"
    end
  end
end
