require "test_helper"

# AUTHORIZED DISCOVERY: what the kernel will let this credential
# address, with the declaration facts each machine announced. The useful
# fact per row is not that a machine exists but that THIS principal may
# bind it — the listing is filtered by eligibility server-side — and what
# it serves; presence is display, never a reason to choose.
class ApiExecutorsTest < Minitest::Test
  RUNNER_ID = "019f0000-0000-7000-8000-000000000701".freeze
  READ = {
    "name" => "read",
    "effect_profile" => { "kind" => "read", "destructive" => false, "world" => "host",
                          "idempotency" => "idempotent", "reconciliation" => "none" },
    "timeout_ms" => 90_000,
    "description" => "Read a file under the root.",
    "input_schema" => { "type" => "object", "properties" => { "path" => { "type" => "string" } } },
  }.freeze
  ROW = {
    "public_id" => RUNNER_ID,
    "kind" => "runner",
    "display_name" => "lab-mac",
    "status" => "active",
    "assignment_scope" => "user_private",
    "served_tools" => [READ],
    "environment" => { "root" => "/srv/lab", "fragments" => [{ "extension" => "rho.coding", "text" => "Paths resolve against /srv/lab." }] },
    "served_documents" => [{ "name" => "deploy-notes", "description" => "How this project is deployed." }],
    "presence" => "online",
    "last_seen_at" => "2026-09-08T10:00:00Z",
    "connected_at" => "2026-09-08T09:00:00Z",
  }.freeze

  def executors(script)
    @transport = CybrosAgentTest::FakeTransport.new(script)
    CybrosAgent::Client.new(base_url: "http://example.test", credential: "sk-member",
      transport: @transport).executors
  end

  def request = @transport.requests.fetch(0)

  def test_a_listed_executor_carries_its_kind_what_it_serves_and_where_it_runs
    executor = executors([[200, {}, { "executors" => [ROW] }]]).list.fetch(0)

    assert_equal :get, request.fetch(:method)
    assert_equal "/agent_api/v1/executors", request.fetch(:path)
    assert_nil request.fetch(:params), "absent kind asks for both machine kinds"
    assert_instance_of CybrosAgent::Api::DiscoveredExecutor, executor
    assert_equal [RUNNER_ID, "runner", "lab-mac", "active", "user_private"],
      [executor.public_id, executor.kind, executor.display_name, executor.status, executor.assignment_scope]
    assert_predicate executor, :runner?

    served = executor.served_tools.fetch(0)
    assert_instance_of CybrosAgent::Api::ServedTool, served
    assert_equal "read", served.name
    assert_equal "read", served.effect_profile.fetch("kind")
    assert_equal 90_000, served.timeout_ms
    assert_equal "Read a file under the root.", served.description
    assert_equal "object", served.input_schema.fetch("type")
    assert_equal %w[read], executor.tool_names

    assert_equal "/srv/lab", executor.environment.fetch("root")
    assert_predicate executor.environment, :frozen?, "the snapshot is opaque and frozen"
    document = executor.served_documents.fetch(0)
    assert_instance_of CybrosAgent::Api::ServedDocument, document
    assert_equal ["deploy-notes", "How this project is deployed."], [document.name, document.description]
    assert_equal %w[deploy-notes], executor.document_names
    assert_equal %w[online 2026-09-08T10:00:00Z 2026-09-08T09:00:00Z],
      [executor.presence, executor.last_seen_at, executor.connected_at]
  end

  def test_narrowing_by_kind_is_asked_of_the_server_rather_than_done_here
    executors([[200, {}, { "executors" => [] }]]).list(kind: "runner")

    assert_equal({ "kind" => "runner" }, request.fetch(:params))
  end

  # The two declaration keys are what a machine SAYS about itself, kept
  # verbatim when announced; a row that announced neither still lists.
  def test_a_served_tool_without_the_declaration_keys_reads_as_none
    bare = READ.slice("name", "effect_profile")
    executor = executors([[200, {}, { "executors" => [ROW.merge("served_tools" => [bare])] }]]).list.fetch(0)

    served = executor.served_tools.fetch(0)
    assert_nil served.timeout_ms
    assert_nil served.description
    assert_nil served.input_schema
  end

  # `name` and `effect_profile` are what the kernel guarantees per entry;
  # a row missing either is a broken contract, not an optional field.
  def test_a_served_tool_without_a_name_is_malformed
    nameless = READ.except("name")

    assert_raises(CybrosAgent::Api::MalformedResponse) do
      executors([[200, {}, { "executors" => [ROW.merge("served_tools" => [nameless])] }]]).list
    end
  end

  def test_an_executor_announcing_nothing_serves_nothing
    row = ROW.merge("served_tools" => [], "environment" => {}, "served_documents" => [])
    executor = executors([[200, {}, { "executors" => [row] }]]).list.fetch(0)

    assert_empty executor.served_tools
    assert_empty executor.tool_names
    assert_equal({}, executor.environment)
    assert_empty executor.served_documents
    assert_empty executor.document_names
  end

  # Both document keys are the kernel's guarantee — it refused the
  # announcement otherwise — so a row missing one is a broken contract,
  # as is a row without the list.
  def test_a_served_document_without_its_description_and_a_row_without_the_list_are_malformed
    assert_raises(CybrosAgent::Api::MalformedResponse) do
      executors([[200, {}, { "executors" => [ROW.merge("served_documents" => [{ "name" => "deploy-notes" }])] }]]).list
    end
    assert_raises(CybrosAgent::Api::MalformedResponse) do
      executors([[200, {}, { "executors" => [ROW.except("served_documents")] }]]).list
    end
  end

  def test_show_reads_one_by_its_id_and_an_ineligible_id_is_absence
    executor = executors([[200, {}, { "executor" => ROW }]]).show(RUNNER_ID)

    assert_equal "/agent_api/v1/executors/#{RUNNER_ID}", request.fetch(:path)
    assert_equal RUNNER_ID, executor.public_id

    error = assert_raises(CybrosAgent::Api::NotFound) do
      executors([[404, {}, { "error" => { "code" => "not_found", "message" => "no" } }]]).show(RUNNER_ID)
    end
    assert_equal "not_found", error.code
  end

  def test_show_refuses_an_empty_id_before_it_reaches_the_wire
    assert_raises(ArgumentError) { executors([]).show("") }
  end
end
