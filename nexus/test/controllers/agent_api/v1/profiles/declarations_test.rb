require "test_helper"
require_relative "../../../../test_helpers/lock_order_test_helper"

class AgentAPI::V1::Profiles::DeclarationsTest < ActionDispatch::IntegrationTest
  include LockOrderTestHelper

  setup do
    @agent = users(:agent)
    connection = connect_agent_session(steward: users(:owner), agent_identifier: @agent.agent_identifier)
    @secret = connection.access_secret
  end

  test "one declaration replaces configuration and both owned slots without resetting document versions" do
    declare(variable: "scene", text: "Scene: {{scene}}.", summary: "Keep result pointers.")
    assert_response :success
    original = @agent.prompt_documents.find_by!(slot: "system_prompt")
    assert_equal "developer", original.role

    sequences = assert_ladder_order("complete Profile declaration") do
      declare(variable: "mood", text: "Mood: {{mood}}.", summary: "Keep decisions too.")
      assert_response :success
    end

    assert_includes sequences.flatten, "users"
    assert_not_includes sequences.flatten, "prompt_documents"
    assert_equal({ "mood" => "quiet" }, @agent.reload.prompt_template.fetch("variables"))
    assert_equal "Mood: {{mood}}.", original.reload.content
    assert_equal 2, original.version
    summarizer = @agent.prompt_documents.find_by!(slot: "summarizer")
    assert_equal "Keep decisions too.", summarizer.content
    assert_equal 2, summarizer.version
  end

  test "tool import intent reads back without expanding or confusing empty Runner filters with nil" do
    ids = [SecureRandom.uuid_v7, SecureRandom.uuid_v7]
    put agent_api_v1_profile_configuration_path, params: { configuration: {
      approval_mode: "bypass", kernel_tools: ["nexus.runners.list"],
      runner_executor_public_ids: ids, runner_tool_names: [],
    } }, headers: bearer(@secret), as: :json
    assert_response :success
    configuration = response.parsed_body.fetch("configuration")
    assert_equal ["nexus.runners.list"], configuration.fetch("kernel_tools")
    assert_equal ids, configuration.fetch("runner_executor_public_ids")
    assert_equal [], configuration.fetch("runner_tool_names")
    assert_equal [], configuration.fetch("tool_definitions")

    put agent_api_v1_profile_configuration_path, params: { configuration: { prompt_mechanism: "default" } },
      headers: bearer(@secret), as: :json
    assert_response :success
    configuration = response.parsed_body.fetch("configuration")
    assert_equal [], configuration.fetch("kernel_tools")
    assert_equal [], configuration.fetch("runner_executor_public_ids")
    assert_nil configuration.fetch("runner_tool_names")
  end

  test "an invalid replacement prompt rolls back every field and earlier slot write" do
    declare(variable: "scene", text: "Scene: {{scene}}.", summary: "Keep result pointers.")
    assert_response :success
    before = saved_declaration

    declare(variable: "mood", text: "Mood: {{mood}}.", summary: "No sources here: {{agent}}.")

    assert_response :unprocessable_content
    assert_equal "prompt_document_macro_unknown", response.parsed_body.dig("error", "code")
    assert_equal before, saved_declaration
  end

  test "an invalid configuration leaves both prompt documents unchanged" do
    declare(variable: "scene", text: "Scene: {{scene}}.", summary: "Keep result pointers.")
    assert_response :success
    before = saved_declaration

    put agent_api_v1_profile_configuration_path,
      params: { configuration: { prompt_mechanism: "assembly", prompt_template: { blocks: [] } },
                prompt_documents: { system_prompt: { content: "Replacement." }, summarizer: nil } },
      headers: bearer(@secret), as: :json

    assert_response :unprocessable_content
    assert_equal "validation_failed", response.parsed_body.dig("error", "code")
    assert_equal before, saved_declaration
  end

  test "omitted and null slots clear while empty content remains a document" do
    declare(variable: "scene", text: "Scene: {{scene}}.", summary: "Keep result pointers.")
    assert_response :success

    put agent_api_v1_profile_configuration_path,
      params: { configuration: { prompt_mechanism: "default" },
                prompt_documents: { system_prompt: { content: "" }, summarizer: nil } },
      headers: bearer(@secret), as: :json
    assert_response :success
    assert_equal "", @agent.prompt_documents.find_by!(slot: "system_prompt").content
    assert_not @agent.prompt_documents.exists?(slot: "summarizer")

    put agent_api_v1_profile_configuration_path,
      params: { configuration: { prompt_mechanism: "default" } }, headers: bearer(@secret), as: :json
    assert_response :success
    assert_empty @agent.prompt_documents
  end

  test "null and empty document sets clear both owned slots" do
    [nil, {}].each do |documents|
      declare(variable: "scene", text: "Scene: {{scene}}.", summary: "Keep result pointers.")
      assert_response :success

      put agent_api_v1_profile_configuration_path,
        params: { configuration: { prompt_mechanism: "default" }, prompt_documents: documents },
        headers: bearer(@secret), as: :json

      assert_response :success
      assert_empty @agent.prompt_documents
    end
  end

  test "non-object configuration and document sets leave the whole declaration unchanged" do
    declare(variable: "scene", text: "Scene: {{scene}}.", summary: "Keep result pointers.")
    assert_response :success
    before = saved_declaration

    [:configuration, :prompt_documents].each do |root|
      ["not an object", [], [{ content: "Replacement." }], false, 1].each do |value|
        declaration = { configuration: { prompt_mechanism: "default" } }.merge(root => value)
        put agent_api_v1_profile_configuration_path,
          params: declaration, headers: bearer(@secret), as: :json

        assert_response :bad_request
        assert_equal "parameter_missing", response.parsed_body.dig("error", "code")
        assert_equal before, saved_declaration
      end
    end
  end

  test "non-object slots leave the configuration and both documents unchanged" do
    declare(variable: "scene", text: "Scene: {{scene}}.", summary: "Keep result pointers.")
    assert_response :success
    before = saved_declaration

    [:system_prompt, :summarizer].each do |slot|
      ["not an object", [], [{ content: "Replacement." }], false, 1].each do |value|
        put agent_api_v1_profile_configuration_path,
          params: { configuration: { prompt_mechanism: "default" }, prompt_documents: { slot => value } },
          headers: bearer(@secret), as: :json

        assert_response :bad_request
        assert_equal "parameter_missing", response.parsed_body.dig("error", "code")
        assert_equal before, saved_declaration
      end
    end
  end

  test "an empty slot object retains the prompt writer refusal without changing the declaration" do
    declare(variable: "scene", text: "Scene: {{scene}}.", summary: "Keep result pointers.")
    assert_response :success
    before = saved_declaration

    put agent_api_v1_profile_configuration_path,
      params: { configuration: { prompt_mechanism: "default" }, prompt_documents: { system_prompt: {} } },
      headers: bearer(@secret), as: :json

    assert_response :unprocessable_content
    assert_equal "prompt_document_invalid", response.parsed_body.dig("error", "code")
    assert_equal before, saved_declaration
  end

  test "a replacement still refuses undeclared macros and cannot select the validation context" do
    declare(variable: "scene", text: "Scene: {{scene}}.", summary: "Keep result pointers.")
    assert_response :success
    before = saved_declaration

    put agent_api_v1_profile_configuration_path,
      params: { configuration: { prompt_mechanism: "default", validation_context: "profile_declaration" },
                prompt_documents: { system_prompt: { content: "Scene: {{scene}}." } } },
      headers: bearer(@secret), as: :json

    assert_response :unprocessable_content
    assert_equal "prompt_document_macro_unknown", response.parsed_body.dig("error", "code")
    assert_equal before, saved_declaration
  end

  private

    def bearer(secret) = { "Authorization" => "Bearer #{secret}" }

    def declare(variable:, text:, summary:)
      put agent_api_v1_profile_configuration_path,
        params: {
          configuration: { prompt_mechanism: "assembly", prompt_template: {
            blocks: [{ type: "slot", slot: "system_prompt" }, { type: "history" }, { type: "input" }],
            variables: { variable => "quiet" },
          } },
          prompt_documents: { system_prompt: { content: text, role: "developer" }, summarizer: { content: summary } },
        }, headers: bearer(@secret), as: :json
    end

    def saved_declaration
      [@agent.reload.prompt_mechanism, @agent.prompt_template,
       @agent.prompt_documents.order(:slot).pluck(:id, :slot, :content, :role, :version, :updated_at)]
    end
end
