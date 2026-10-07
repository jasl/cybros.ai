require "support/daemon_run_helpers"

class DaemonMediaInputsTest < Minitest::Test
  include RhoTest::DaemonRunHelpers

  def test_prepared_uploads_reach_captionless_open_and_replayed_say_without_uploading_again
    api = NexusDoubles::FakeAgentApi.new(trace: NexusDoubles::RUNNING_TRACE)
    daemon = member_ready(boot(realtime_factory: ->(*) { nil }), api)
    ids = %w[019a-upload-one 019a-upload-two]

    code, answer = open(daemon, { "model" => "dev/mock-text", "upload_public_ids" => ids,
                                 "idempotency_key" => "picture-open" })
    assert_equal "201", code, answer.inspect
    assert_equal "", api.conversation_inputs.last.dig("input", "text")
    assert_equal ids, api.conversation_inputs.last.dig("input", "attachments")
    refute answer.key?("attachments"), "prepared uploads do not invent local staging descriptors"

    2.times do
      response = request(daemon, :post, "/say", token: bearer(daemon), body: {
        public_id: answer.dig("conversation", "public_id"), text: "", delivery_mode: "queue", wait: false,
        upload_public_ids: ids, idempotency_key: "picture-follow-up",
      })
      assert_equal "200", response.code, response.body
    end
    assert_equal [ids, ids], api.conversation_inputs.last(2).map { |entry| entry.dig("input", "attachments") }
    assert_equal(*api.conversation_inputs.last(2), "retries preserve the input envelope")
    assert_empty api.uploads
  end

  def test_prepared_uploads_are_observed_without_model_execution_and_cannot_be_steered_or_mixed
    api = NexusDoubles::FakeAgentApi.new(trace: NexusDoubles::RUNNING_TRACE)
    daemon = member_ready(boot(realtime_factory: ->(*) { nil }), api)
    _code, answer = open(daemon, { "prompt" => "first", "model" => "dev/mock-text" })
    base = { public_id: answer.dig("conversation", "public_id"), text: "", upload_public_ids: ["019a-upload"] }

    observed = request(daemon, :post, "/say", token: bearer(daemon),
      body: base.merge(kind: "message", delivery_mode: "queue"))
    assert_equal "200", observed.code, observed.body
    assert_equal ["message", ["019a-upload"]],
      api.conversation_inputs.last.fetch("input").values_at("kind", "attachments")

    refused = request(daemon, :post, "/say", token: bearer(daemon), body: base)
    assert_equal "422", refused.code
    assert_equal "attachments_not_steerable", JSON.parse(refused.body).dig("error", "code")
    refused = request(daemon, :post, "/say", token: bearer(daemon),
      body: base.merge(delivery_mode: "queue", attachments: [picture_file("local.png")]))
    assert_equal "400", refused.code
    assert_equal 2, api.conversation_inputs.length
    assert_empty api.uploads
  end

  def test_local_pdf_staging_keeps_the_bytes_and_prepared_retries_reuse_its_upload
    api = NexusDoubles::FakeAgentApi.new(trace: NexusDoubles::RUNNING_TRACE, upload_content_type: "application/pdf")
    daemon = member_ready(boot(realtime_factory: ->(*) { nil }), api)
    path = File.join(@root, "report.pdf")
    bytes = "%PDF-1.7\n\x00\xFF\n%%EOF\n".b
    File.binwrite(path, bytes)

    code, answer = open(daemon, { "model" => "dev/mock-text", "attachments" => [path] })
    assert_equal "201", code, answer.inspect
    assert_equal [{ filename: "report.pdf", byte_size: bytes.bytesize, bytes: bytes }], api.uploads
    assert_equal [{ "filename" => "report.pdf", "content_type" => "application/pdf", "byte_size" => bytes.bytesize }],
      answer.fetch("attachments")
    input = api.conversation_inputs.last.fetch("input")
    assert_equal "", input.fetch("text")
    ids = input.fetch("attachments")

    2.times do
      response = request(daemon, :post, "/say", token: bearer(daemon), body: {
        public_id: answer.dig("conversation", "public_id"), text: "Summarize the PDF.",
        delivery_mode: "queue", wait: false, upload_public_ids: ids, idempotency_key: "pdf-follow-up",
      })
      assert_equal "200", response.code, response.body
    end
    assert_equal [ids, ids], api.conversation_inputs.last(2).map { |entry| entry.dig("input", "attachments") }
    assert_equal(*api.conversation_inputs.last(2), "the PDF retries retain the same input envelope")
    assert_equal 1, api.uploads.length, "a prepared retry must not stage a replacement PDF"
  end

  def test_captionless_local_images_keep_the_existing_upload_path_and_empty_text_without_media_is_refused
    api = NexusDoubles::FakeAgentApi.new(trace: NexusDoubles::RUNNING_TRACE)
    daemon = member_ready(boot(realtime_factory: ->(*) { nil }), api)
    code, answer = open(daemon, { "model" => "dev/mock-text", "attachments" => [picture_file("local.png")] })
    assert_equal "201", code, answer.inspect
    assert_equal ["", ["up-1"]], api.conversation_inputs.last.fetch("input").values_at("text", "attachments")
    assert_equal 1, api.uploads.length
    response = request(daemon, :post, "/say", token: bearer(daemon), body: {
      public_id: answer.dig("conversation", "public_id"), text: "", delivery_mode: "queue", upload_public_ids: [],
    })
    assert_equal "400", response.code
    assert_equal 1, api.conversation_inputs.length
  end
end
