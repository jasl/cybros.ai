require "test_helper"

# THE RESULT MAPPING: every block kind, the audio
# line, `isError`, the SHOULD serialization, the image file in `Result#files`.
class MappingTest < Minitest::Test
  include McpTest::Helpers

  def setup
    @redact = Rho::Runner::Redact.new
  end

  def test_text_blocks_join_and_structure_rides_verbatim
    result = Rho::Mcp::Mapping.result(
      { "content" => [{ "type" => "text", "text" => "a" }, { "type" => "text", "text" => "b" }],
        "structuredContent" => { "k" => 1 } }, server: "fx", redact: @redact
    )
    assert_equal ["a\nb", { "k" => 1 }, false, []], [result.content, result.structured_content, result.is_error, result.files]
  end

  def test_is_error_is_data_the_model_reads
    result = Rho::Mcp::Mapping.result({ "content" => [{ "type" => "text", "text" => "no such record" }], "isError" => true },
      server: "fx", redact: @redact)
    assert_predicate result, :is_error
    assert_equal "no such record", result.content
  end

  def test_structure_without_text_is_serialized_into_the_text
    result = Rho::Mcp::Mapping.result({ "content" => [], "structuredContent" => { "only" => "structure" } },
      server: "fx", redact: @redact)
    assert_equal '{"only":"structure"}', result.content
    assert_equal({ "only" => "structure" }, result.structured_content)
    assert_equal "", Rho::Mcp::Mapping.result({ "content" => [] }, server: "fx", redact: @redact).content
  end

  def test_every_block_kind_maps_and_images_and_pdfs_become_captures
    @redact = Rho::Runner::Redact.new(["fixture-secret", Base64.strict_encode64(McpTest::PNG)])
    with_tool_env do |env, _root|
      raw = { "content" => [
        { "type" => "text", "text" => "fixture-secret" },
        { "type" => "image", "data" => Base64.strict_encode64(McpTest::PNG), "mimeType" => "image/png" },
        { "type" => "audio", "data" => "AAAA", "mimeType" => "audio/wav" },
        { "type" => "resource_link", "uri" => "file:///etc/hosts", "mimeType" => "text/plain" },
        { "type" => "resource", "resource" => { "uri" => "fx://note", "mimeType" => "text/plain", "text" => "embedded text" } },
        { "type" => "resource", "resource" => { "uri" => "fx://blob", "mimeType" => "application/octet-stream", "blob" => "AAAA" } },
        { "type" => "resource", "resource" => { "uri" => "fx://pic", "mimeType" => "image/png", "blob" => Base64.strict_encode64(McpTest::PNG) } },
        { "type" => "resource", "resource" => { "uri" => "fx://report", "mimeType" => "application/pdf", "blob" => Base64.strict_encode64(McpTest::PDF) } },
        { "type" => "shape", "data" => "?" },
      ] }
      result = Rho::Mcp::Mapping.result(raw, server: "fx", redact: @redact, env: env)
      digest = Digest::SHA256.hexdigest(McpTest::PNG)[0, 16]
      image = File.join(env.artifacts_dir, "mcp", "fx", "image-#{digest}.png")
      blob = File.join(env.artifacts_dir, "mcp", "fx", "resource-#{digest}.png")
      pdf = File.join(env.artifacts_dir, "mcp", "fx", "resource-#{Digest::SHA256.hexdigest(McpTest::PDF)[0, 16]}.pdf")
      assert_equal [image, blob, pdf], result.files
      assert_equal McpTest::PNG, File.binread(image)
      assert_equal McpTest::PDF, File.binread(pdf)
      assert_equal <<~TEXT.chomp, result.content
        •••
        [image: image/png, #{McpTest::PNG.bytesize} bytes — saved at #{image} and attached]
        [audio: audio/wav, content discarded]
        resource: file:///etc/hosts (text/plain)
        embedded text
        [resource: fx://blob (application/octet-stream), content discarded]
        [resource: image/png, #{McpTest::PNG.bytesize} bytes — saved at #{blob} and attached]
        [resource: application/pdf, #{McpTest::PDF.bytesize} bytes — saved at #{pdf} and attached]
        [unsupported content type: shape]
      TEXT
    end
  end

  def test_without_an_env_an_image_is_a_line_not_a_file
    result = Rho::Mcp::Mapping.result({ "content" => [{ "type" => "image", "data" => "AAAA", "mimeType" => "image/png" }] },
      server: "fx", redact: @redact)
    assert_equal "[image: image/png, content discarded]", result.content
    assert_empty result.files
  end

  def test_without_an_env_an_embedded_pdf_is_a_placeholder
    resource = { "uri" => "fx://report", "mimeType" => "application/pdf", "blob" => Base64.strict_encode64(McpTest::PDF) }
    result = Rho::Mcp::Mapping.result({ "content" => [{ "type" => "resource", "resource" => resource }] },
      server: "fx", redact: @redact)

    assert_equal "[resource: application/pdf, content discarded]", result.content
    assert_empty result.files
  end

  def test_the_notice_opens_the_text
    result = Rho::Mcp::Mapping.with_notice(Rho::Runner::Result.ok("echo"), "note: restarted")
    assert_equal "note: restarted\necho", result.content
    assert_equal "echo", Rho::Mcp::Mapping.with_notice(Rho::Runner::Result.ok("echo"), nil).content
  end

  def test_the_model_facing_tail_is_capped_at_three_lines_and_512_bytes
    tail = (1..10).map { |i| "line #{i}" }.join("\n")
    assert_equal "line 8\nline 9\nline 10", Rho::Mcp::Mapping.capped_tail(tail)
    long = "x" * 600
    assert_equal 512, Rho::Mcp::Mapping.capped_tail(long).bytesize
    assert_equal "", Rho::Mcp::Mapping.capped_tail("  \n ")
    assert_equal "; its stderr ended: boom", Rho::Mcp::Mapping.tail_clause("boom\n")
    assert_equal "", Rho::Mcp::Mapping.tail_clause("")
  end
end
