require "test_helper"

class PersonaTest < Minitest::Test
  DOCUMENT = {
    "slot" => "persona", "role" => "system", "bytesize" => 5, "version" => 1,
    "written_at" => "2026-10-07T00:00:00Z", "content" => "Short",
  }.freeze

  def context(script)
    @transport = CybrosAgentTest::FakeTransport.new(script)
    CybrosAgent::PlatformClient.new(base_url: "https://nexus.example", credential: "human",
      transport: @transport).persona
  end

  def test_reads_the_existing_prompt_document_shape_through_personal_settings
    result = context([[200, {}, { "prompt_document" => DOCUMENT }]]).read
    assert_instance_of CybrosAgent::Api::PromptDocument, result
    assert_equal "Short", result.content
    assert_equal "/api/v1/persona", @transport.requests.first.fetch(:path)
  end

  def test_writes_content_and_optional_role_without_losing_empty_text
    context([[200, {}, { "prompt_document" => DOCUMENT }]]).write("")
    request = @transport.requests.first
    assert_equal :put, request.fetch(:method)
    assert_equal({ "prompt_document" => { "content" => "" } }, request.fetch(:body))
    context([[200, {}, { "prompt_document" => DOCUMENT }]]).write("Short", role: "user")
    assert_equal "user", @transport.requests.first.dig(:body, "prompt_document", "role")
  end

  def test_delete_and_absence_preserve_the_existing_document_contract
    assert_nil context([[204, {}, nil]]).delete
    assert_equal :delete, @transport.requests.first.fetch(:method)
    error = assert_raises(CybrosAgent::Api::NotFound) do
      context([[404, {}, { "error" => { "code" => "prompt_document_not_found" } }]]).read
    end
    assert_equal "prompt_document_not_found", error.code
  end
end
