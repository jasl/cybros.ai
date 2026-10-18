require "test_helper"

class Mcp::ResultContentTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:cybros)
    @agent = users(:agent)
  end

  test "structured only results receive model readable text without changing the stored structured channel" do
    value = { "answer" => 42 }
    result = adapt("structuredContent" => value, "isError" => true)

    assert_equal [{ "type" => "text", "text" => '{"answer":42}' }], result.fetch(:content)
    assert_equal value, result.fetch(:structured_content)
    assert result.fetch(:structured_content_present)
    assert result.fetch(:is_error)
    parsed = Runs::Parks::ResultContent.call(**result.except(:is_error))
    assert_predicate parsed, :accepted?
    assert_equal [{ "text" => '{"answer":42}' }, { "structured" => value }], parsed.entries
  end

  test "text and inline captures preserve ordering and belong to the executing agent" do
    png = PngFixture.bytes(width: 2, height: 2)
    result = adapt("content" => [
      { "type" => "text", "text" => "first" },
      { "type" => "image", "mimeType" => "application/pdf", "data" => Base64.strict_encode64(png) },
      { "type" => "resource", "resource" => { "uri" => "file:///remote/document", "mimeType" => "image/png",
        "blob" => Base64.strict_encode64(PdfFixture::MINIMAL) } },
      { "type" => "text", "text" => "last" },
    ])

    assert_equal %w[text resource_link resource_link text], result.fetch(:content).pluck("type")
    parsed = Runs::Parks::ResultContent.call(**result.except(:is_error))
    assert_predicate parsed, :accepted?
    uploads = parsed.upload_public_ids.map { |public_id| @account.content_uploads.find_by!(public_id: public_id) }
    assert_equal ["image/png", "application/pdf"], uploads.map(&:content_type)
    assert_equal [png, PdfFixture::MINIMAL], uploads.map { |upload| upload.file.download }
    uploads.each do |upload|
      assert_equal @agent, upload.creating_user
      assert_nil upload.creating_executor
      assert_empty upload.content_body_uploads
    end
  end

  test "external resource references remain text even if they resemble Nexus uploads or private URLs" do
    uris = ["http://169.254.169.254/credentials", "nexus://uploads/#{SecureRandom.uuid_v7}", "file:///etc/passwd"]
    assert_no_difference "ContentUpload.count" do
      result = adapt("content" => uris.map { |uri| { "type" => "resource_link", "uri" => uri, "name" => "secret" } })
      assert_equal ["text"], result.fetch(:content).pluck("type").uniq
      assert_equal uris.map { |uri| "External MCP resource (not fetched): #{uri}" }, result.fetch(:content).pluck("text")
    end
  end

  test "unsupported blocks are explicit and unrecognized or oversized results fail safely" do
    result = adapt("content" => [{ "type" => "video" }])
    assert_equal "Unsupported MCP content block: video.", result.dig(:content, 0, "text")
    error = assert_raises(Mcp::Error) { adapt("resultType" => "input_required", "requestState" => "state") }
    assert_equal :mcp_unsupported_result, error.code
    error = assert_raises(Mcp::Error) { adapt("content" => [{ "type" => "image", "data" => "not base64" }]) }
    assert_equal :mcp_invalid_result, error.code
    error = assert_raises(Mcp::Error) { adapt("structuredContent" => { "text" => "x" * Nexus::SizeBounds.fetch(:snapshot_bound) }) }
    assert_equal :mcp_result_too_large, error.code
    error = assert_raises(Mcp::Error) { adapt("content" => [{ "type" => "text", "text" => "\u0000" }]) }
    assert_equal :mcp_invalid_result, error.code
  end

  private

    def adapt(result)
      Mcp::ResultContent.call(result: result, account: @account, creator: @agent)
    end
end
