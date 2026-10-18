require "test_helper"

# THE ACTING USER'S OWN SLOTS: an agent profile writes its `system_prompt` — its own row, never its
# steward's — and a Human writes `persona`; each refuses the other's slot and the room's
# `character`, which has its own door. No fence: the row is the caller's.
class AgentAPI::V1::Profiles::PromptDocumentsTest < ActionDispatch::IntegrationTest
  setup do
    @agent = users(:agent)
    connection = connect_agent_session(steward: users(:owner), agent_identifier: @agent.agent_identifier)
    @agent_secret = connection.access_secret
    @transport_secret = connection.executor_access_secret
    @steward_secret = create_access_token_fixture(user: users(:owner), name: "S").secret
  end

  def bearer(secret) = { "Authorization" => "Bearer #{secret}" }
  def base = "/agent_api/v1/profile/prompt_documents"

  def put!(slot, content, secret:)
    put "#{base}/#{slot}", headers: bearer(secret), as: :json,
      params: { prompt_document: { content: content } }
  end

  test "the agent writes system_prompt as its own row, and reads it back" do
    put!("system_prompt", "You are {{agent}}.", secret: @agent_secret)
    assert_response :success
    assert_equal "system_prompt", response.parsed_body.dig("prompt_document", "slot")
    assert_equal 1, response.parsed_body.dig("prompt_document", "version")
    assert @agent.prompt_documents.exists?(slot: "system_prompt")
    assert_not users(:owner).prompt_documents.exists?, "never the steward's row"

    put!("system_prompt", "You are {{agent}}, precise.", secret: @agent_secret)
    assert_response :success
    assert_equal 2, response.parsed_body.dig("prompt_document", "version")

    get base, headers: bearer(@agent_secret)
    assert_response :success
    assert_equal ["system_prompt"], response.parsed_body.fetch("prompt_documents").map { |d| d.fetch("slot") }
    get "#{base}/system_prompt", headers: bearer(@agent_secret)
    assert_response :success
    assert_equal "You are {{agent}}, precise.", response.parsed_body.dig("prompt_document", "content")

    get base, headers: bearer(@steward_secret)
    assert_response :success
    assert_empty response.parsed_body.fetch("prompt_documents"), "the steward's own door lists the steward's rows"

    delete "#{base}/system_prompt", headers: bearer(@agent_secret)
    assert_response :no_content
    assert_not @agent.prompt_documents.exists?
  end

  test "a whole replacement without a role restores the system default" do
    put "#{base}/system_prompt", headers: bearer(@agent_secret), as: :json,
      params: { prompt_document: { content: "Developer instructions.", role: "developer" } }
    assert_response :success
    assert_equal "developer", response.parsed_body.dig("prompt_document", "role")

    put!("system_prompt", "Replacement instructions.", secret: @agent_secret)
    assert_response :success
    assert_equal "system", response.parsed_body.dig("prompt_document", "role")
    document = @agent.prompt_documents.find_by!(slot: "system_prompt")
    assert_equal ["Replacement instructions.", "system", 2], [document.content, document.role, document.version]
  end

  test "the steward writes persona; each refuses the other's slot and character" do
    put!("persona", "The person is {{user}}.", secret: @steward_secret)
    assert_response :success
    assert_equal "persona", response.parsed_body.dig("prompt_document", "slot")
    assert users(:owner).prompt_documents.exists?(slot: "persona")

    put!("system_prompt", "x", secret: @steward_secret)
    assert_response :unprocessable_entity
    assert_equal "prompt_slot_unavailable", response.parsed_body.dig("error", "code")

    put!("persona", "x", secret: @agent_secret)
    assert_response :unprocessable_entity
    assert_equal "prompt_slot_unavailable", response.parsed_body.dig("error", "code")

    put!("character", "x", secret: @agent_secret)
    assert_response :unprocessable_entity
    assert_equal "prompt_slot_unavailable", response.parsed_body.dig("error", "code")
    get "#{base}/character", headers: bearer(@steward_secret)
    assert_response :unprocessable_entity
    assert_equal "prompt_slot_unavailable", response.parsed_body.dig("error", "code")

    get "#{base}/system_prompt", headers: bearer(@agent_secret)
    assert_response :not_found
    assert_equal "prompt_document_not_found", response.parsed_body.dig("error", "code")
  end

  # THE SUMMARIZER SLOT: the agent's own, content-only — a role the kernel-mode summarizer would
  # ignore is refused rather than stored (`prompt_document_invalid`, the existing code); a Human
  # cannot hold it; a delete on the absent slot is the kernel's 404, which an application treats as
  # landed.
  test "the agent writes summarizer content-only, and a role on it is refused" do
    put!("summarizer", "Summarize by pointers.", secret: @agent_secret)
    assert_response :success
    assert_equal %w[summarizer system 1],
      response.parsed_body.fetch("prompt_document").values_at("slot", "role", "version").map(&:to_s)

    put "#{base}/summarizer", headers: bearer(@agent_secret), as: :json,
      params: { prompt_document: { content: "Summarize by pointers.", role: "developer" } }
    assert_response :unprocessable_entity
    assert_equal "prompt_document_invalid", response.parsed_body.dig("error", "code")
    assert_equal 1, @agent.prompt_documents.find_by!(slot: "summarizer").version, "nothing was stored"

    put "#{base}/summarizer", headers: bearer(@agent_secret), as: :json,
      params: { prompt_document: { content: "Summarize by pointers, tersely.", role: "system" } }
    assert_response :success, "the default role, spelled, is not a lie"
    assert_equal 2, response.parsed_body.dig("prompt_document", "version")

    put!("summarizer", "x", secret: @steward_secret)
    assert_response :unprocessable_entity
    assert_equal "prompt_slot_unavailable", response.parsed_body.dig("error", "code")

    get base, headers: bearer(@agent_secret)
    assert_equal ["summarizer"], response.parsed_body.fetch("prompt_documents").map { |d| d.fetch("slot") }

    delete "#{base}/summarizer", headers: bearer(@agent_secret)
    assert_response :no_content
    delete "#{base}/summarizer", headers: bearer(@agent_secret)
    assert_response :not_found
    assert_equal "prompt_document_not_found", response.parsed_body.dig("error", "code")
  end

  test "a transport credential is fenced with 401 — this is the member plane" do
    put!("system_prompt", "x", secret: @transport_secret)
    assert_response :unauthorized
  end
end
