require "test_helper"

# PUT /agent_api/v1/executor/announcement — what this executor SERVES, for delivery only: a whole
# replacement on the executor plane, answered with the same description GET /executor renders,
# refusing a reserved kernel namespace and every entry without an effect profile — and admitting
# an overridable kernel wire name.
class AgentAPI::V1::Executors::AnnouncementsTest < ActionDispatch::IntegrationTest
  READ = Nexus::ToolRegistry::READ_ONLY_CLOSED

  setup do
    @executor = task_executors(:address)
    @transport = create_bound_credential(executor: @executor, name: "Transport")
    @member = create_access_token_fixture(user: users(:member), name: "Member")
  end

  READ_SCHEMA = { "type" => "object", "properties" => { "path" => { "type" => "string" } } }.freeze

  def announce(tools, secret: @transport.secret, **rest)
    put agent_api_v1_executor_announcement_path, headers: bearer(secret), as: :json,
      params: { tools: tools, **rest }
  end

  def bearer(secret) = { "Authorization" => "Bearer #{secret}" }

  test "a transport bearer announces and reads back the byte-identical description" do
    announce(
      [{ name: "bash", effect_profile: READ, timeout_ms: 30_000, description: "Run a command",
         input_schema: READ_SCHEMA },
       { name: "read_file", effect_profile: READ }],
      environment: { root: "/w", fragments: [{ extension: "rho.coding", text: "Relative paths resolve against /w." }] }
    )
    assert_response :success
    announced = response.parsed_body

    get agent_api_v1_executor_path, headers: bearer(@transport.secret)
    assert_response :success
    assert_equal response.parsed_body.except("measured_at"), announced.except("measured_at")
    assert_equal %w[executor measured_at], announced.keys.sort
    assert_not announced.fetch("executor").key?("served_tools"), "the announcement is not the executor's to read back"
    assert_not announced.key?("environment"), "nor is the environment"

    assert_equal %w[bash read_file], @executor.reload.served_tools.map { |entry| entry["name"] }
    assert_equal 30_000, @executor.serving("bash").fetch("timeout_ms")
    assert_equal "Run a command", @executor.serving("bash").fetch("description")
    assert_equal READ_SCHEMA, @executor.serving("bash").fetch("input_schema")
    assert_equal "/w", @executor.environment.fetch("root")
    assert_equal ["rho.coding"], @executor.environment.fetch("fragments").map { |fragment| fragment["extension"] }
  end

  test "an empty list clears what was served" do
    announce([{ name: "bash", effect_profile: READ }])
    assert_response :success
    announce([])
    assert_response :success
    assert_equal [], @executor.reload.served_tools
  end

  test "a member bearer is fenced from the executor plane" do
    announce([], secret: @member.secret)
    assert_response :unauthorized
    assert_equal "unauthorized", response.parsed_body.dig("error", "code")
  end

  test "a kernel name under a reserved namespace, in either spelling, is reserved_namespace" do
    { "wait" => "nexus.graph", "nexus.graph.wait" => "nexus.graph", "ask" => "nexus.human",
      "spawn" => "nexus.conversation" }.each do |name, namespace|
      announce([{ name: name, effect_profile: READ }])
      assert_response :unprocessable_content, name
      assert_equal "reserved_namespace", response.parsed_body.dig("error", "code"), name
      assert_equal "tools[0].name names a reserved kernel namespace (#{namespace})",
        response.parsed_body.dig("error", "message"), name
    end
    assert_equal [], @executor.reload.served_tools, "a refusal writes nothing"
  end

  # Admitted by the door and never addressed until a workspace opts in: honest and inert. The dotted
  # spelling is the format rule's.
  test "an overridable kernel wire name is admitted and stored as announced" do
    announce([{ name: "memory_read", effect_profile: READ }])
    assert_response :success
    assert @executor.reload.served?("memory_read")

    announce([{ name: "nexus.memory.read", effect_profile: READ }])
    assert_response :unprocessable_content
    assert_equal "invalid_announcement", response.parsed_body.dig("error", "code")
    assert_includes response.parsed_body.dig("error", "message"), "tools[0].name must match"
  end

  test "a profile-less entry, a bad key, a bad name, or a duplicate is invalid_announcement" do
    [
      [{ name: "bash" }, "tools[0].effect_profile is required"],
      [{ name: "bash", effect_profile: READ.merge("extra" => 1) }, "tools[0].effect_profile must carry exactly"],
      [{ name: "no spaces", effect_profile: READ }, "tools[0].name must match"],
      [{ name: "bash", effect_profile: READ.merge("kind" => "loud") }, "tools[0].effect_profile.kind must be one of"],
      [{ name: "bash", effect_profile: READ, description: " " }, "tools[0].description must be a non-empty string"],
      [{ name: "bash", effect_profile: READ, input_schema: { type: "array" } }, "tools[0].input_schema must be a JSON Schema object"],
    ].each do |entry, message|
      announce([entry])
      assert_response :unprocessable_content, entry.inspect
      assert_equal "invalid_announcement", response.parsed_body.dig("error", "code"), entry.inspect
      assert_includes response.parsed_body.dig("error", "message"), message
    end

    announce([{ name: "bash", effect_profile: READ }, { name: "bash", effect_profile: READ }])
    assert_response :unprocessable_content
    assert_equal "invalid_announcement", response.parsed_body.dig("error", "code")
    assert_includes response.parsed_body.dig("error", "message"), "tools[1].name repeats bash"

    announce([{ name: "bash", effect_profile: READ }], environment: "x")
    assert_response :unprocessable_content
    assert_equal "invalid_announcement", response.parsed_body.dig("error", "code")
    assert_equal "environment must be an object", response.parsed_body.dig("error", "message")
  end

  # The documents: the third list the verb replaces whole, read as sent and judged by the model's
  # rules — a refusal names `documents[i].<field>`; absent clears.
  test "the documents ride the same verb, are refused by index and field, and clear when absent" do
    announce([{ name: "skill", effect_profile: READ }],
      documents: [{ name: "deploy-notes", description: "How this project is deployed.", kind: "skill" }])
    assert_response :success
    assert_equal [{ "name" => "deploy-notes", "description" => "How this project is deployed." }],
      @executor.reload.served_documents
    assert_not response.parsed_body.fetch("executor").key?("served_documents"), "not the executor's to read back"

    [
      [[{ name: "deploy-notes" }], "documents[0].description must be a non-empty string"],
      [[{ name: "Deploy", description: "x" }], "documents[0].name must match"],
      [[{ name: "a", description: "x" }, { name: "a", description: "y" }], "documents[1].name repeats a"],
      [["a"], "documents[0] must be an object"],
      [{ name: "a" }, "documents must be a list of entries"],
    ].each do |documents, message|
      announce([{ name: "skill", effect_profile: READ }], documents: documents)
      assert_response :unprocessable_content, documents.inspect
      assert_equal "invalid_announcement", response.parsed_body.dig("error", "code"), documents.inspect
      assert_includes response.parsed_body.dig("error", "message"), message
    end
    assert_equal ["deploy-notes"], @executor.reload.served_documents.map { |entry| entry["name"] }, "a refusal writes nothing"

    announce([{ name: "skill", effect_profile: READ }])
    assert_response :success
    assert_equal [], @executor.reload.served_documents, "whole replacement: absent clears"
  end

  test "a missing environment is an empty document, not a bad request" do
    announce([{ name: "bash", effect_profile: READ }], environment: { root: "/w" })
    assert_response :success
    assert_equal({ "root" => "/w" }, @executor.reload.environment)

    announce([{ name: "bash", effect_profile: READ }])
    assert_response :success
    assert_equal({}, @executor.reload.environment, "whole replacement: absent clears")
  end

  test "an environment over its bound is validation_failed" do
    announce([], environment: { text: "a" * Nexus::SizeBounds.fetch(:executor_environment_bound) })
    assert_response :unprocessable_content
    assert_equal "validation_failed", response.parsed_body.dig("error", "code")
    assert_includes response.parsed_body.dig("error", "message"), "Environment"
  end

  test "the body is read opaque: a non-list is refused and a missing list is a bad request" do
    announce({ name: "bash" })
    assert_response :unprocessable_content
    assert_equal "invalid_announcement", response.parsed_body.dig("error", "code")

    put agent_api_v1_executor_announcement_path, headers: bearer(@transport.secret), as: :json, params: {}
    assert_response :bad_request
    assert_equal "parameter_missing", response.parsed_body.dig("error", "code")
  end
end
