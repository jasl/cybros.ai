require "test_helper"

# PROMPTS AND RESOURCES AS DOCUMENTS: the curation
# with its skip reasons, and the two bodies — a prompt's messages, a
# resource's contents, an image a capture named in `Result#files`.
class DocumentsTest < Minitest::Test
  include McpTest::Helpers

  def row(key: "fx")
    Rho::Mcp::Settings.parse({ key => { "transport" => "stdio", "command" => "ruby", "tools" => "*" } }, env: {}).fetch(0)
  end

  def listings(documents)
    client = MCP::Client.new(transport: McpTest::FakeTransport.new(McpTest::FixtureServer.build(tools: [], documents: documents)))
    client.connect(mode: :legacy)
    [client.prompts, client.resources]
  end

  def test_the_curation_announces_the_described_and_skips_with_reasons
    curated = Rho::Mcp::Documents.curate(row, *listings(McpTest::FixtureServer::DOCUMENTS))
    assert_equal ["fx-summarize", "fx-chatty-prompt-#{Rho::Mcp::Naming.digest("fx", "Chatty Prompt")}", "fx-asker", "fx-readme",
                  "fx-notes", "fx-logo"], curated.names, "prompts then resources, in listing order"
    assert_equal [%w[fx-greet prompt], %w[fx-blob resource], %w[fx-nodesc resource]],
      curated.skipped.map { |skip| [skip.name, skip.kind] }
    assert_equal ['prompt: required argument "who"', "resource: application/octet-stream", "resource: no description"],
      curated.skipped.map(&:reason)
    summarize = curated.find("fx-summarize")
    assert_equal ["prompt", "summarize", nil, McpTest::FixtureServer::SUMMARIZE_DESCRIPTION, nil],
      [summarize.kind, summarize.raw_name, summarize.uri, summarize.description, summarize.mime_type]
    assert_predicate summarize, :prompt?
    assert_equal({ "name" => "fx-summarize", "description" => McpTest::FixtureServer::SUMMARIZE_DESCRIPTION }, summarize.entry)
    readme = curated.find("fx-readme")
    assert_equal ["resource", "readme", "fx://readme", "text/markdown"], [readme.kind, readme.raw_name, readme.uri, readme.mime_type]
    assert_nil curated.find("fx-notes").mime_type, "a listing with no mimeType is announced; the read decides"
    assert_equal "image/png", curated.find("fx-logo").mime_type, "an image listing is announced: a capture at the read"
    assert_equal curated.announced.map(&:entry), curated.entries
    curated.entries.each do |entry|
      assert_match(/\A[a-z0-9](?:-?[a-z0-9])*\z/, entry.fetch("name"))
      assert_operator entry.fetch("description").bytesize, :<=, 1024
    end
  end

  def test_the_curation_skips_a_long_description_a_nameless_listing_and_a_sibling_collision
    prompts = [{ "name" => "readme", "description" => "A prompt named like the resource." },
               { "name" => "long", "description" => "d" * 1025 }]
    resources = [{ "uri" => "fx://readme", "name" => "readme", "description" => "The resource." },
                 { "uri" => "fx://x", "description" => "no name" },
                 { "uri" => "fx://json", "name" => "data", "description" => "JSON is text.", "mimeType" => "application/json" },
                 { "uri" => "fx://ld", "name" => "ld", "description" => "LD is text.", "mimeType" => "application/ld+json" },
                 { "uri" => "fx://pdf", "name" => "pdf", "description" => "A PDF.", "mimeType" => "application/pdf" }]
    curated = Rho::Mcp::Documents.curate(row, prompts, resources)
    assert_equal %w[fx-readme fx-data fx-ld], curated.names
    assert_equal "prompt", curated.find("fx-readme").kind, "the first of a folded pair wins"
    assert_equal [["fx-long", "prompt: description exceeds 1024 bytes"],
                  ["fx-readme", 'resource: name fx-readme is already announced by the prompt "readme"'],
                  ["fx-fx-x-#{Rho::Mcp::Naming.digest("fx", "fx://x")}", "resource: no name"],
                  ["fx-pdf", "resource: application/pdf"]],
      curated.skipped.map { |skip| [skip.name, skip.reason] }
  end

  def test_a_prompts_messages_become_a_body_and_an_image_block_a_capture
    raw = { "messages" => [
      { "role" => "user", "content" => { "type" => "text", "text" => "First line.\nSecond." } },
      { "role" => "assistant", "content" => { "type" => "text", "text" => "An answer." } },
      { "role" => "user", "content" => [{ "type" => "text", "text" => "a" }, { "type" => "text", "text" => "b" }] },
      { "role" => "user", "content" => { "type" => "audio", "data" => "AAAA", "mimeType" => "audio/wav" } },
    ] }
    result = Rho::Mcp::Documents.prompt_result(raw, server: "fx", name: "fx-summarize")
    refute_predicate result, :is_error
    assert_equal "First line.\nSecond.\n\nassistant:\nAn answer.\n\na\nb\n\n[audio: audio/wav, content discarded]", result.content
    assert_empty result.files

    with_tool_env do |env, _root|
      picture = { "messages" => [{ "role" => "user", "content" => { "type" => "image", "data" => Base64.strict_encode64(McpTest::PNG), "mimeType" => "image/png" } }] }
      result = Rho::Mcp::Documents.prompt_result(picture, server: "fx", name: "fx-chatty", env: env)
      path = File.join(env.artifacts_dir, "mcp", "fx", "fx-chatty-0-0.png")
      assert_equal [path], result.files
      assert_equal McpTest::PNG, File.binread(path)
      assert_equal "[image: image/png, #{McpTest::PNG.bytesize} bytes — saved at #{path} and attached]", result.content
    end
    assert_equal "", Rho::Mcp::Documents.prompt_result({}, server: "fx", name: "fx-empty").content
  end

  def test_a_resources_contents_become_a_body_and_an_image_blob_a_capture_named_by_the_document
    text = [{ "uri" => "fx://readme", "mimeType" => "text/markdown", "text" => "# Readme" },
            { "uri" => "fx://readme", "mimeType" => "text/markdown", "text" => "more" }]
    result = Rho::Mcp::Documents.resource_result(text, server: "fx", name: "fx-readme")
    assert_equal ["# Readme\nmore", false, []], [result.content, result.is_error, result.files]

    with_tool_env do |env, _root|
      blob = [{ "uri" => "fx://logo", "mimeType" => "image/png", "blob" => Base64.strict_encode64(McpTest::PNG) }]
      result = Rho::Mcp::Documents.resource_result(blob, server: "fx", name: "fx-logo", env: env)
      path = File.join(env.artifacts_dir, "mcp", "fx", "fx-logo.png")
      assert_equal [path], result.files
      assert_equal McpTest::PNG, File.binread(path)
      assert_equal "fx-logo: image/png, #{McpTest::PNG.bytesize} bytes — saved at #{path} and attached", result.content
      opaque = [{ "uri" => "fx://blob", "mimeType" => "application/octet-stream", "blob" => "AAAA" }]
      assert_equal "[resource: fx://blob (application/octet-stream), content discarded]",
        Rho::Mcp::Documents.resource_result(opaque, server: "fx", name: "fx-blob", env: env).content
      assert_empty Dir.glob(File.join(env.artifacts_dir, "mcp", "fx", "fx-blob*")), "a non-image blob is never a file"
    end
    assert_equal "[resource: fx://logo (image/png), content discarded]",
      Rho::Mcp::Documents.resource_result([{ "uri" => "fx://logo", "mimeType" => "image/png", "blob" => "AAAA" }], server: "fx", name: "fx-logo").content,
      "without an env (the probe) an image is the placeholder line"
  end
end
