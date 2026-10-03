require "test_helper"

# THE ROOM'S CHARACTER: the workspace door holds one slot, `character`, written under the dedication
# fence — a fenced second agent reads it and never writes it; PUT is a whole replacement by slot in
# the URL, whether first or later write.
class AgentAPI::V1::Workspaces::PromptDocumentsTest < ActionDispatch::IntegrationTest
  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @workspace = workspaces(:shared)
    @secret = create_access_token_fixture(user: @human, name: "Member").secret
  end

  def bearer(secret) = { "Authorization" => "Bearer #{secret}" }
  def base = "/agent_api/v1/workspaces/#{@workspace.public_id}/prompt_documents"

  def put!(slot, content, role: nil, secret: @secret)
    put "#{base}/#{slot}", headers: bearer(secret), as: :json,
      params: { prompt_document: { content: content, role: role }.compact }
  end

  test "PUT creates, PUT replaces with the version bumped, GET reads, DELETE ends it" do
    put!("character", "You are in {{workspace}}.")
    assert_response :success
    document = response.parsed_body.fetch("prompt_document")
    assert_equal %w[slot role bytesize version written_at content], document.keys
    assert_equal "character", document.fetch("slot")
    assert_equal "system", document.fetch("role"), "the default role"
    assert_equal 1, document.fetch("version")
    assert_equal "You are in {{workspace}}.".bytesize, document.fetch("bytesize")
    assert_equal "You are in {{workspace}}.", document.fetch("content"), "the macro is stored, not rendered"

    put!("character", "The room is quiet.", role: "user")
    assert_response :success
    assert_equal 2, response.parsed_body.dig("prompt_document", "version")
    assert_equal "user", response.parsed_body.dig("prompt_document", "role")
    assert_equal 1, @workspace.prompt_documents.count, "one row per slot"

    get base, headers: bearer(@secret)
    assert_response :success
    listing = response.parsed_body.fetch("prompt_documents")
    assert_equal [%w[slot role bytesize version written_at]], listing.map(&:keys)
    assert_equal "The room is quiet.".bytesize, listing.sole.fetch("bytesize")

    get "#{base}/character", headers: bearer(@secret)
    assert_response :success
    assert_equal "The room is quiet.", response.parsed_body.dig("prompt_document", "content")

    delete "#{base}/character", headers: bearer(@secret)
    assert_response :no_content

    get "#{base}/character", headers: bearer(@secret)
    assert_response :not_found
    assert_equal "prompt_document_not_found", response.parsed_body.dig("error", "code")
    delete "#{base}/character", headers: bearer(@secret)
    assert_response :not_found
  end

  test "a whole replacement without a role restores the system default" do
    put!("character", "The room speaks as a user.", role: "user")
    assert_response :success
    assert_equal "user", response.parsed_body.dig("prompt_document", "role")

    put!("character", "Replacement room instructions.")
    assert_response :success
    assert_equal "system", response.parsed_body.dig("prompt_document", "role")
    document = @workspace.prompt_documents.find_by!(slot: "character")
    assert_equal ["Replacement room instructions.", "system", 2], [document.content, document.role, document.version]
  end

  test "a slot this door's anchor cannot hold is prompt_slot_unavailable, and a stranger slot too" do
    %w[persona system_prompt mood].each do |slot|
      put!(slot, "x")
      assert_response :unprocessable_entity, slot
      assert_equal "prompt_slot_unavailable", response.parsed_body.dig("error", "code"), slot
      assert_includes response.parsed_body.dig("error", "message"), slot
    end
    assert_equal 0, PromptDocument.count
  end

  test "a dedication-fenced agent reads and its PUT is 403" do
    put!("character", "The room.")
    assert_response :success
    agent = users(:agent)
    connection = connect_agent_session(steward: users(:owner), agent_identifier: agent.agent_identifier)
    Workspace.where(id: @workspace.id).update_all(agent_identifier: "some-other-program")

    get "#{base}/character", headers: bearer(connection.access_secret)
    assert_response :success
    assert_equal "The room.", response.parsed_body.dig("prompt_document", "content")

    put!("character", "Mine now.", secret: connection.access_secret)
    assert_response :forbidden
    assert_equal "not_authorized", response.parsed_body.dig("error", "code")
    delete "#{base}/character", headers: bearer(connection.access_secret)
    assert_response :forbidden
    assert_equal "The room.", @workspace.prompt_documents.sole.content
  end

  test "an archived workspace still reads and refuses the write as workspace_not_active" do
    put!("character", "The room.")
    assert_response :success
    Workspace.where(id: @workspace.id).update_all(state: "archived")

    get base, headers: bearer(@secret)
    assert_response :success

    put!("character", "Rewritten.")
    assert_response :conflict
    assert_equal "workspace_not_active", response.parsed_body.dig("error", "code")
  end

  test "the bound, an unknown macro and an unknown role are 422 by name" do
    put!("character", "x" * 65_537)
    assert_response :unprocessable_entity
    assert_equal "prompt_document_too_large", response.parsed_body.dig("error", "code")

    put!("character", "Recall {{history}} first.")
    assert_response :unprocessable_entity
    assert_equal "prompt_document_macro_unknown", response.parsed_body.dig("error", "code")
    assert_includes response.parsed_body.dig("error", "message"), "history"

    put!("character", "fine", role: "tool")
    assert_response :unprocessable_entity
    assert_equal "prompt_document_invalid", response.parsed_body.dig("error", "code")

    put "#{base}/character", headers: bearer(@secret), as: :json, params: { prompt_document: { role: "system" } }
    assert_response :unprocessable_entity, "content is required"
    assert_equal "prompt_document_invalid", response.parsed_body.dig("error", "code")
    assert_equal 0, PromptDocument.count
  end
end
