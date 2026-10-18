require "test_helper"

class API::V1::PersonasTest < ActionDispatch::IntegrationTest
  include AgentMembershipTestHelper
  setup do
    @human = users(:member)
    @credential = create_access_token_fixture(user: @human, name: "Personal settings", plane: :platform)
    @headers = { "Authorization" => "Bearer #{@credential.secret}" }
  end

  test "an ordinary Human writes reads and deletes the same persona as the member door" do
    get api_v1_persona_path, headers: @headers
    assert_response :not_found
    assert_equal "prompt_document_not_found", response.parsed_body.dig("error", "code")

    put api_v1_persona_path, headers: @headers,
      params: { prompt_document: { content: "I prefer concise answers.", role: "developer" } }, as: :json
    assert_response :success
    assert_equal "persona", response.parsed_body.dig("prompt_document", "slot")
    assert_equal 1, response.parsed_body.dig("prompt_document", "version")
    document = @human.prompt_documents.find_by!(slot: "persona")
    assert_equal "developer", document.role
    assert_empty users(:agent).prompt_documents.where(slot: "persona")

    member = create_access_token_fixture(user: @human, name: "Member")
    get "/agent_api/v1/profile/prompt_documents/persona", headers: { "Authorization" => "Bearer #{member.secret}" }
    assert_response :success
    assert_equal document.content, response.parsed_body.dig("prompt_document", "content")

    put api_v1_persona_path, headers: @headers,
      params: { prompt_document: { content: "" } }, as: :json
    assert_response :success
    assert_equal 2, response.parsed_body.dig("prompt_document", "version")
    assert_equal "", response.parsed_body.dig("prompt_document", "content")
    get api_v1_persona_path, headers: @headers
    assert_equal "", response.parsed_body.dig("prompt_document", "content")

    delete api_v1_persona_path, headers: @headers
    assert_response :no_content
    delete api_v1_persona_path, headers: @headers
    assert_response :not_found
  end

  test "member and executor credentials never gain Human persona authority" do
    member = create_access_token_fixture(user: @human, name: "Member")
    connection = connect_agent_session(steward: users(:owner), agent_identifier: users(:agent).agent_identifier)
    [member.secret, connection.access_secret, connection.executor_access_secret].each do |secret|
      put api_v1_persona_path, headers: { "Authorization" => "Bearer #{secret}" },
        params: { prompt_document: { content: "changed" } }, as: :json
      assert_response :unauthorized
    end
    assert_empty @human.prompt_documents.where(slot: "persona")
  end

  test "a different Human reads only their own persona and the cookie cannot mutate it" do
    put api_v1_persona_path, headers: @headers,
      params: { prompt_document: { content: "Private preference" } }, as: :json
    other = create_access_token_fixture(user: users(:owner), name: "Other", plane: :platform)
    get api_v1_persona_path, headers: { "Authorization" => "Bearer #{other.secret}" }
    assert_response :not_found

    sign_in_as @human
    get api_v1_persona_path
    assert_response :success
    delete api_v1_persona_path
    assert_response :unauthorized
  end

  test "invalid content preserves the current persona with the prompt document refusal" do
    put api_v1_persona_path, headers: @headers,
      params: { prompt_document: { content: "Current" } }, as: :json
    ["{{unknown_macro}}", "x" * (Nexus::SizeBounds.fetch(:prompt_document_bound) + 1)].each do |content|
      put api_v1_persona_path, headers: @headers, params: { prompt_document: { content: content } }, as: :json
      assert_response :unprocessable_entity
      assert_equal "Current", @human.prompt_documents.find_by!(slot: "persona").content
    end
  end
end
