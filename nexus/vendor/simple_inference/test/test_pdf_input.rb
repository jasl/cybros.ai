require "json"
require "test_helper"

# One application part, four provider encodings. Compilation exercises the
# same profile and lowering boundary as create/stream without provider IO.
class TestPdfInput < Minitest::Test
  FORMATS = %w[openai_responses openai_compatible_chat anthropic_messages gemini_generate_content].freeze
  PDF_BYTES = "%PDF-1.7\n1 0 obj << /Type /Catalog >> endobj\n%%EOF\n".b.freeze
  PNG_BYTES = ("\x89PNG\r\n\x1a\n".b + "synthetic pixels").freeze
  FILENAME = "工程图.pdf".freeze

  class NoIOAdapter < SimpleInference::HTTPAdapter
    def call(_env) = raise("PDF compilation must not perform IO")
    def call_stream(_env) = raise("PDF compilation must not perform IO")
  end

  def test_pdf_bytes_lower_in_place_on_every_wire_for_buffered_and_streaming_requests
    FORMATS.each do |format|
      [false, true].each do |stream|
        input = [{ role: "user", content: [
          { type: "input_text", text: "Read this document." },
          pdf_part,
          { type: "input_text", text: "Give the conclusion." },
        ] }]
        compiled = compile(format, input, stream: stream)
        parts = wire_parts(format, JSON.parse(compiled.payload))

        assert_equal [wire_text(format, "Read this document."), wire_pdf(format),
          wire_text(format, "Give the conclusion.")], parts, "#{format}, stream=#{stream}"
        assert_equal stream, compiled.stream?, format
      end
    end
  end

  def test_pdf_and_image_parts_keep_their_own_wire_type_and_occurrence_order
    FORMATS.each do |format|
      input = [{ "role" => "user", "content" => [
        pdf_part.transform_keys(&:to_s),
        { "type" => "input_image", "image_url" => SimpleInference::MediaInput.from_bytes(PNG_BYTES) },
        pdf_part.transform_keys(&:to_s),
      ] }]
      parts = wire_parts(format, JSON.parse(compile(format, input).payload))

      assert_equal [wire_pdf(format), wire_image(format), wire_pdf(format)], parts, format
    end
  end

  def test_anthropic_document_keeps_its_cache_breakpoint
    part = pdf_part.merge(cache_control: { type: "ephemeral", ttl: "1h" })
    payload = JSON.parse(compile("anthropic_messages", [{ role: "user", content: [part] }]).payload)

    assert_equal wire_pdf("anthropic_messages").merge("cache_control" => { "type" => "ephemeral", "ttl" => "1h" }),
      wire_parts("anthropic_messages", payload).fetch(0)
  end

  def test_file_input_requires_the_models_explicit_capability
    FORMATS.each do |format|
      defaults = SimpleInference::ApiFormat.defaults(format)
      profile = profile_for(format, input_modalities: ["image"], input_media: defaults[:input_media].slice("image"))

      error = assert_raises(SimpleInference::CapabilityError) do
        compile(format, [{ role: "user", content: [pdf_part] }], profile: profile)
      end
      assert_includes error.message, "file inputs are not enabled"
    end
  end

  def test_file_input_can_be_disabled_for_one_request
    FORMATS.each do |format|
      error = assert_raises(SimpleInference::CapabilityError) do
        compile(format, [{ role: "user", content: [pdf_part] }], allow_file_input: false)
      end
      assert_includes error.message, "file inputs are disabled"
    end
  end

  def test_non_byte_file_carriers_are_rejected_before_io
    carriers = [nil, "data:application/pdf;base64,AAAA", "https://example.com/report.pdf",
      "/tmp/report.pdf", "file-provider-id", { "url" => "https://example.com/report.pdf" }]
    FORMATS.each do |format|
      carriers.each do |carrier|
        error = assert_raises(SimpleInference::ValidationError) do
          compile(format, [{ role: "user", content: [pdf_part.merge(file_data: carrier)] }])
        end
        assert_includes error.message, "MediaInput", format
      end
    end
  end

  def test_provider_file_references_are_rejected_even_beside_valid_bytes
    FORMATS.each do |format|
      { file_id: "file-provider-id", file_url: "https://example.com/report.pdf" }.each do |key, value|
        error = assert_raises(SimpleInference::ValidationError) do
          compile(format, [{ role: "user", content: [pdf_part.merge(key => value)] }])
        end
        assert_includes error.message, "bytes-only", format
      end
    end
  end

  def test_the_file_modality_does_not_claim_other_media_types
    FORMATS.each do |format|
      error = assert_raises(SimpleInference::ValidationError) do
        compile(format, [{ role: "user", content: [pdf_part.merge(file_data: SimpleInference::MediaInput.from_bytes(PNG_BYTES))] }])
      end
      assert_includes error.message, "application/pdf", format
    end
  end

  def test_streamed_pdf_is_not_silently_materialized_for_an_inline_wire
    media = SimpleInference::MediaInput.new(media_type: "application/pdf", byte_size: PDF_BYTES.bytesize,
      source: -> { raise "an inline wire must not read a stream" })
    FORMATS.each do |format|
      error = assert_raises(SimpleInference::ValidationError) do
        compile(format, [{ role: "user", content: [pdf_part.merge(file_data: media)] }])
      end
      assert_includes error.message, "streamed", format
    end
  end

  def test_openai_file_parts_require_a_filename
    %w[openai_responses openai_compatible_chat].each do |format|
      error = assert_raises(SimpleInference::ValidationError) do
        compile(format, [{ role: "user", content: [pdf_part.except(:filename)] }])
      end
      assert_includes error.message, "filename", format
    end
  end

  private

  def pdf_part
    { type: "input_file", filename: FILENAME, file_data: SimpleInference::MediaInput.from_bytes(PDF_BYTES) }
  end

  def compile(format, input, stream: false, profile: profile_for(format), **options)
    client = SimpleInference::Client.new(execution_profile: profile, base_url: "https://provider.example",
      adapter: NoIOAdapter.new)
    client.responses.compile(model: profile.model_pin, input: input, stream: stream, max_output_tokens: 64, **options)
  end

  def wire_parts(format, payload)
    case format
    when "openai_responses" then payload.fetch("input").fetch(0).fetch("content")
    when "openai_compatible_chat", "anthropic_messages" then payload.fetch("messages").fetch(0).fetch("content")
    when "gemini_generate_content" then payload.fetch("contents").fetch(0).fetch("parts")
    else raise "unhandled PDF wire #{format}"
    end
  end

  def wire_text(format, text)
    case format
    when "openai_responses" then { "type" => "input_text", "text" => text }
    when "openai_compatible_chat", "anthropic_messages" then { "type" => "text", "text" => text }
    when "gemini_generate_content" then { "text" => text }
    else raise "unhandled PDF wire #{format}"
    end
  end

  def wire_pdf(format)
    data = [PDF_BYTES].pack("m0")
    case format
    when "openai_responses"
      { "type" => "input_file", "filename" => FILENAME, "file_data" => "data:application/pdf;base64,#{data}" }
    when "openai_compatible_chat"
      { "type" => "file", "file" => { "filename" => FILENAME, "file_data" => "data:application/pdf;base64,#{data}" } }
    when "anthropic_messages"
      { "type" => "document", "source" => { "type" => "base64", "media_type" => "application/pdf", "data" => data } }
    when "gemini_generate_content"
      { "inline_data" => { "mime_type" => "application/pdf", "data" => data } }
    else raise "unhandled PDF wire #{format}"
    end
  end

  def wire_image(format)
    data = [PNG_BYTES].pack("m0")
    case format
    when "openai_responses"
      { "type" => "input_image", "image_url" => "data:image/png;base64,#{data}" }
    when "openai_compatible_chat"
      { "type" => "image_url", "image_url" => { "url" => "data:image/png;base64,#{data}" } }
    when "anthropic_messages"
      { "type" => "image", "source" => { "type" => "base64", "media_type" => "image/png", "data" => data } }
    when "gemini_generate_content"
      { "inline_data" => { "mime_type" => "image/png", "data" => data } }
    else raise "unhandled image wire #{format}"
    end
  end
end
