require "test_helper"

class Settings::PersonasControllerTest < ActionDispatch::IntegrationTest
  setup do
    @human = users(:member)
    sign_in_as @human
  end

  test "Persona has a direct settings address with an empty state and labeled form" do
    get settings_persona_path
    assert_response :success
    assert_select "turbo-frame#settings" do
      assert_select "a[href=?][aria-current='page']", settings_persona_path, text: "Persona"
      assert_select "form[action=?][data-turbo-frame='_top']", settings_persona_path
      assert_select "label[for=prompt_document_content]", text: "Persona content"
      assert_select "textarea[name='prompt_document[content]']", text: ""
      assert_select "select[name='prompt_document[role]'] option[selected]", text: "System"
      assert_select "button", text: "Delete Persona", count: 0
    end
    assert_includes response.body, I18n.t("personas.empty")
    assert_includes response.body, "conversation_kind"
  end

  test "save empty and delete use the same current Human document as the Platform API" do
    put settings_persona_path, params: { prompt_document: { content: "Prefer concise answers.", role: "developer" } }
    assert_response :see_other
    assert_redirected_to settings_persona_path
    get api_v1_persona_path
    assert_response :success
    assert_equal "Prefer concise answers.", response.parsed_body.dig("prompt_document", "content")
    assert_equal "developer", response.parsed_body.dig("prompt_document", "role")
    assert_equal 1, response.parsed_body.dig("prompt_document", "version")
    assert_empty users(:owner).prompt_documents.where(slot: "persona")

    put settings_persona_path, params: { prompt_document: { content: "", role: "system" } }
    assert_redirected_to settings_persona_path
    get api_v1_persona_path
    assert_response :success
    assert_equal "", response.parsed_body.dig("prompt_document", "content")
    assert_equal 2, response.parsed_body.dig("prompt_document", "version")
    delete settings_persona_path
    assert_response :see_other
    assert_redirected_to settings_persona_path
    get api_v1_persona_path
    assert_response :not_found
    delete settings_persona_path
    assert_redirected_to settings_persona_path
    assert_equal I18n.t("personas.errors.prompt_document_not_found"), flash[:alert]
  end

  test "a failed save keeps the submitted text and role at the same address and preserves the saved document" do
    put settings_persona_path, params: { prompt_document: { content: "Saved", role: "system" } }
    invalid = "<script>draft</script> {{unknown_macro}}"
    put settings_persona_path, params: { prompt_document: { content: invalid, role: "developer" } }
    assert_response :unprocessable_entity
    assert_equal settings_persona_path, request.path
    assert_select "textarea[name='prompt_document[content]'][aria-invalid=true]", text: invalid
    assert_select "select[name='prompt_document[role]'] option[selected]", text: "Developer"
    assert_select "[role=alert]", text: /Unknown macro: unknown_macro/
    assert_select "script", text: "draft", count: 0
    assert_equal "Saved", @human.prompt_documents.find_by!(slot: "persona").content

    oversized = "x" * (Nexus::SizeBounds.fetch(:prompt_document_bound) + 1)
    put settings_persona_path, params: { prompt_document: { content: oversized, role: "user" } }
    assert_response :unprocessable_entity
    assert_select "textarea[name='prompt_document[content]']", text: oversized
    assert_equal "Saved", @human.prompt_documents.find_by!(slot: "persona").content
  end

  test "another Human sees only their own Persona and anonymous writes do not change it" do
    put settings_persona_path, params: { prompt_document: { content: "Member preference" } }
    sign_out
    sign_in_as users(:owner)
    get settings_persona_path
    assert_response :success
    assert_not_includes response.body, "Member preference"
    put settings_persona_path, params: { prompt_document: { content: "Owner preference" } }
    assert_equal "Member preference", @human.prompt_documents.find_by!(slot: "persona").content
    sign_out
    put settings_persona_path, params: { prompt_document: { content: "Anonymous preference" } }
    assert_redirected_to new_session_path
    assert_equal "Member preference", @human.prompt_documents.find_by!(slot: "persona").content
  end
end
