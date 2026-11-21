require "test_helper"
require "base64"

# THE CONTENT BLOCKS: the joins, the attachment
# files created and deleted, the refusals — pinned here, and once through
# the surface so the file lives exactly as long as `say`.
class AcpContentTest < Minitest::Test
  Content = Rho::Acp::Agent::Content
  Refusal = Rho::Acp::Agent::Refusal
  PNG = Base64.strict_encode64("\x89PNG\r\n\x1a\nfake".b)
  PDF = "%PDF-1.7\nEmbedded ACP document\n%%EOF\n".b.freeze

  def setup
    @dir = Dir.mktmpdir("rho-acp-content")
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  def test_text_blocks_join_by_a_blank_line
    rendered = Content.render([{ "type" => "text", "text" => "one" }, { "type" => "text", "text" => "two" }], dir: @dir)

    assert_equal "one\n\ntwo", rendered.text
    assert_empty rendered.attachments
  end

  def test_an_embedded_resource_is_a_fenced_block_headed_by_its_uri
    rendered = Content.render([
      { "type" => "text", "text" => "look" },
      { "type" => "resource", "resource" => { "uri" => "file:///work/a.rb", "mimeType" => "text/x-ruby", "text" => "puts 1" } },
    ], dir: @dir)

    assert_equal "look\n\nfile:///work/a.rb\n```\nputs 1\n```", rendered.text
  end

  def test_a_resource_link_is_its_uri_on_one_line
    rendered = Content.render([
      { "type" => "resource_link", "uri" => "file:///work/b.rb", "name" => "b.rb" }, { "type" => "text", "text" => "read it" },
    ], dir: @dir)

    assert_equal "file:///work/b.rb\n\nread it", rendered.text
  end

  def test_an_image_becomes_a_file_posted_as_an_attachment_and_discarded_after
    rendered = Content.render([{ "type" => "text", "text" => "what is this" }, { "type" => "image", "data" => PNG, "mimeType" => "image/png" }], dir: @dir)

    assert_equal 1, rendered.attachments.length
    path = rendered.attachments.first
    assert path.start_with?(@dir)
    assert path.end_with?(".png")
    assert_equal "\x89PNG\r\n\x1a\nfake".b, File.binread(path)
    assert_equal "what is this", rendered.text
    rendered.discard
    refute File.exist?(path)
  end

  def test_an_image_blob_resource_becomes_a_file_too
    rendered = Content.render([{ "type" => "resource", "resource" => { "uri" => "file:///x.jpg", "mimeType" => "image/jpeg", "blob" => PNG } }], dir: @dir)

    assert rendered.attachments.first.end_with?(".jpg")
    rendered.discard
  end

  def test_a_pdf_only_prompt_keeps_the_decoded_bytes_in_a_private_file
    rendered = Content.render([pdf_resource], dir: @dir)
    assert_empty rendered.text
    assert_predicate rendered, :pdf?
    path = rendered.attachments.fetch(0)
    assert path.end_with?(".pdf")
    assert_equal 0o600, File.stat(path).mode & 0o777
    assert_equal PDF, File.binread(path)
    rendered.discard
    refute File.exist?(path)
  end

  def test_a_pdf_is_bounded_by_its_decoded_byte_size
    limit = 16 * 1024 * 1024
    bytes = PDF.ljust(limit, "\n")
    rendered = Content.render([pdf_resource(Base64.strict_encode64(bytes))], dir: @dir)
    assert_equal limit, File.size(rendered.attachments.fetch(0))
    rendered.discard

    error = assert_raises(Refusal) do
      Content.render([pdf_resource(Base64.strict_encode64(bytes + "\n"))], dir: @dir)
    end
    assert_equal(-32602, error.code)
    assert_match(/exceeds 16 MiB/, error.message)
    assert_empty Dir.children(@dir)
  end

  def test_unsupported_blobs_audio_and_bad_shapes_are_refused
    [
      [[{ "type" => "resource", "resource" => { "uri" => "file:///x.zip", "mimeType" => "application/zip", "blob" => PNG } }], /zip blob is not accepted/],
      [[pdf_resource(" \r\n")], /needs base64 data/],
      [[pdf_resource("AB==")], /not base64/],
      [[{ "type" => "audio", "data" => PNG, "mimeType" => "audio/wav" }], /audio is not accepted/],
      [[{ "type" => "video" }], /unknown content block type/],
      [[{ "type" => "text", "text" => 3 }], /text must be a string/],
      [[{ "type" => "image", "data" => "not base64!", "mimeType" => "image/png" }], /not base64/],
      [["nope"], /not a content block/],
      ["text", /must be a list/],
    ].each do |blocks, shape|
      error = assert_raises(Refusal) { Content.render(blocks, dir: @dir) }
      assert_equal(-32602, error.code)
      assert_match shape, error.message
    end
  end

  def test_a_refused_render_leaves_no_file_behind
    assert_raises(Refusal) do
      Content.render([pdf_resource, { "type" => "audio" }], dir: @dir)
    end

    assert_empty Dir.children(@dir)
  end

  def test_through_the_surface_the_file_lives_for_the_say_and_is_gone_after
    core = RhoAcpTest::CoreDouble.new
    seen = nil
    core.say_answers << lambda do |_id, _text, attachments:, **|
      seen = attachments.map { |path| [path, File.binread(path)] }
      { "turn" => { "public_id" => "trn_1" }, "run" => { "public_id" => "alp_1" } }
    end
    core.events["cnv_1"] = [[["turn_status", { "turn_public_id" => "trn_1", "run_public_id" => "alp_1", "status" => "completed", "run_status" => "completed" }], ["closed", {}]]]
    harness = RhoAcpTest::AgentHarness.new(core: core)
    harness.initialize_agent
    harness.new_session(cwd: "/tmp")

    answer = harness.prompt("cnv_1", [
      { "type" => "text", "text" => "see" }, { "type" => "image", "data" => PNG, "mimeType" => "image/png" }, pdf_resource,
    ])

    assert_equal({ "stopReason" => "end_turn" }, answer)
    assert_equal [Base64.strict_decode64(PNG), PDF], seen.map(&:last)
    seen.each do |path, _bytes|
      assert path.start_with?(File.join(harness.home.tmp_root, "acp", "cnv_1"))
      refute File.exist?(path)
    end
    assert_equal "see", core.calls_of(:say).first.first[1]
  ensure
    harness&.close
  end

  def test_a_builtin_command_with_a_pdf_is_refused_without_running_the_command
    core = RhoAcpTest::CoreDouble.new
    harness = RhoAcpTest::AgentHarness.new(core: core)
    harness.initialize_agent
    harness.new_session(cwd: "/tmp")

    error = assert_raises(Rho::Acp::RemoteError) do
      harness.prompt("cnv_1", [{ "type" => "text", "text" => "/compact" }, pdf_resource])
    end
    assert_equal(-32602, error.code)
    assert_match(/PDF attachments require a new conversation turn/, error.message)
    refute core.called?(:compact)
    assert_empty Dir.children(File.join(harness.home.tmp_root, "acp", "cnv_1"))
  ensure
    harness&.close
  end

  private

  def pdf_resource(blob = Base64.strict_encode64(PDF))
    { "type" => "resource", "resource" => { "uri" => "file:///not-on-the-runner/report.pdf", "mimeType" => "application/pdf", "blob" => blob } }
  end
end
