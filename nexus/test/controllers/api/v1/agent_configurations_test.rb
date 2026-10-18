require "test_helper"

class API::V1::AgentConfigurationsTest < ActionDispatch::IntegrationTest
  setup do
    @owner = users(:member)
    DevModelLane.ensure_enabled!(@owner.account)
    @connection = connect_agent_session(steward: @owner, agent_identifier: "configuration.application")
    @agent = @connection.access_token.user
    post api_v1_session_path, params: { email: @owner.identity.email, password: "password" }, as: :json
    @headers = { "Authorization" => "Bearer #{response.parsed_body.fetch("token")}" }
  end

  test "Platform reads the application declaration without authoring metadata" do
    application_write("Application")
    assert_response :success
    body = read_configuration
    assert_equal "Application", body.fetch("prompt_documents").first.fetch("content")
    assert_equal %w[agent agent_updated_at configuration measured_at prompt_documents], body.keys.sort
    application_write("Application again")
    assert_response :success
    assert_equal "Application again", read_configuration.fetch("prompt_documents").first.fetch("content")
    @agent.remove
    assert_equal "removed", read_configuration.dig("agent", "status")
  end

  test "Builder Preset and management routes no longer exist" do
    [[:put, path], [:post, "#{path}_management"],
      [:post, "/api/v1/agents/#{@agent.public_id}/tool_assembly"],
      [:get, "/api/v1/agent_presets"], [:post, "/api/v1/agent_presets"],
      [:get, "/agent_presets"], [:get, "/agents/#{@agent.public_id}/configuration/edit"]].each do |method, route|
      assert_raises(ActionController::RoutingError) do
        Rails.application.routes.recognize_path(route, method: method)
      end
    end
  end

  test "application replacement preserves empty documents and clears omitted slots and nullable filters" do
    application_write("")
    assert_response :success
    assert_equal "", read_configuration.fetch("prompt_documents").first.fetch("content")
    put application_path, params: { configuration: { prompt_mechanism: "default", runner_tool_names: nil } },
      headers: bearer(@connection.access_secret), as: :json
    assert_response :success
    body = read_configuration
    assert_empty body.fetch("prompt_documents")
    assert_nil body.dig("configuration", "runner_tool_names")
  end

  test "invalid document shapes and model references leave both documents and the declaration untouched" do
    application_write("Original")
    assert_response :success
    current = read_configuration
    [[], "invalid"].each do |documents|
      put application_path, params: {
        configuration: { prompt_mechanism: "default" }, prompt_documents: documents }, headers: bearer(@connection.access_secret), as: :json
      assert_response :bad_request
    end
    [{ system_prompt: {} }, { summarizer: { content: "Summary", role: "developer" } }].each do |documents|
      put application_path, params: {
        configuration: { prompt_mechanism: "default" }, prompt_documents: documents }, headers: bearer(@connection.access_secret), as: :json
      assert_response :unprocessable_content
    end
    put application_path, params: {
      configuration: { prompt_mechanism: "default", default_model: "dev/no-such-model" },
      prompt_documents: { system_prompt: { content: "Replacement" } } }, headers: bearer(@connection.access_secret), as: :json
    assert_response :unprocessable_content
    assert_equal current.except("measured_at"), read_configuration.except("measured_at")
  end

  test "nontext prompt content cannot be cast into a saved document or partially replace the declaration" do
    put application_path, params: {
      configuration: { prompt_mechanism: "default", runner_tool_names: [] },
      prompt_documents: { system_prompt: { content: "Original instructions" }, summarizer: { content: "Original summary" } } },
      headers: bearer(@connection.access_secret), as: :json
    assert_response :success
    current = read_configuration

    %w[system_prompt summarizer].each do |slot|
      [123, true, false, {}, [], nil].each do |content|
        documents = { "system_prompt" => { "content" => "Uncommitted instructions" }, "summarizer" => { "content" => "Uncommitted summary" } }
        documents[slot] = { "content" => content }
        put application_path, params: {
          configuration: { prompt_mechanism: "default", runner_tool_names: nil }, prompt_documents: documents },
          headers: bearer(@connection.access_secret), as: :json
        assert_response :unprocessable_content
        assert_equal "prompt_document_invalid", response.parsed_body.dig("error", "code")
        assert_equal current.except("measured_at"), read_configuration.except("measured_at")
      end
    end
  end

  private

    def bearer(secret) = { "Authorization" => "Bearer #{secret}" }
    def path = "/api/v1/agents/#{@agent.public_id}/configuration"
    def application_path = "/agent_api/v1/profile/configuration"

    def read_configuration
      get path, headers: @headers
      assert_response :success
      response.parsed_body
    end

    def application_write(prompt)
      put application_path, params: { configuration: { prompt_mechanism: "default" },
        prompt_documents: { system_prompt: { content: prompt } } }, headers: bearer(@connection.access_secret), as: :json
    end
end
