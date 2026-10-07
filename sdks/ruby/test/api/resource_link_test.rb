require "test_helper"

# THE `resource_link` BLOCK: one Data, one constructor, `to_h`
# the wire block — MCP's own `ResourceLink` in a commit's `content`, naming
# a capture by the one scheme the kernel resolves; `name` required, the
# optional fields absent from the block when not given.
class ApiResourceLinkTest < Minitest::Test
  def test_to_h_is_the_wire_block_with_only_the_fields_given
    link = CybrosAgent::Api::ResourceLink.new(uri: "nexus://uploads/01a0-upload", name: "shot.png")
    assert_equal({ "type" => "resource_link", "uri" => "nexus://uploads/01a0-upload", "name" => "shot.png" }, link.to_h)

    full = CybrosAgent::Api::ResourceLink.to_upload("01a0-upload", name: "shot.png", mime_type: "image/png",
      size: 184_211, title: "the sign-in page", description: "after submit")
    assert_equal({
      "type" => "resource_link", "uri" => "nexus://uploads/01a0-upload", "name" => "shot.png",
      "mimeType" => "image/png", "size" => 184_211, "title" => "the sign-in page", "description" => "after submit",
    }, full.to_h)
  end

  def test_uri_and_name_are_required
    assert_raises(ArgumentError) { CybrosAgent::Api::ResourceLink.new(name: "shot.png") }
    assert_raises(ArgumentError) { CybrosAgent::Api::ResourceLink.new(uri: "nexus://uploads/x") }
  end

  # The block rides `commit(content:)` exactly as built: the kernel reads
  # the list verbatim, so nothing here lowers or renames.
  def test_the_block_rides_a_commit_verbatim
    transport = CybrosAgentTest::FakeTransport.new([[200, {}, { "task" => { "key" => "r1t0", "kind" => "tool_task", "lifetime" => "conversation", "wake" => "auto",
      "status" => "completed", "on_failure" => "absorb", "visibility" => "visible" } }]])
    executor = CybrosAgent::ExecutorClient.new(
      base_url: "https://nexus.test", credential: "sk-cybros-executor-v1-x", transport: transport
    )
    link = CybrosAgent::Api::ResourceLink.to_upload("01a0-upload", name: "shot.png", mime_type: "image/png")

    executor.inbox_task(run_public_id: "al-1", task_key: "r1t0")
      .commit(claim_token: "tok", content: [{ "type" => "text", "text" => "saved" }, link.to_h])

    body = transport.requests.fetch(0).fetch(:body)
    assert_equal [{ "type" => "text", "text" => "saved" }, link.to_h], body.fetch("content")
  end
end
