require "test_helper"

class ModelRequests::PdfInputsTest < ActiveSupport::TestCase
  FORMATS = %w[openai_responses openai_compatible_chat anthropic_messages gemini_generate_content].freeze
  PDF = "%PDF-1.7\n1 0 obj << /Type /Catalog >> endobj\n%%EOF\n".b.freeze
  PNG = Base64.decode64(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
  ).freeze

  setup do
    @account = accounts(:cybros)
    @creator = users(:member)
    DevModelLane.ensure_enabled!(@account)
    @pdf = upload(PDF, "工程图.pdf", "application/pdf")
    @image = upload(PNG, "diagram.png", "image/png")
  end

  test "accepted PDFs and images retain their types and occurrence order after a cold rebuild on every wire" do
    FORMATS.each do |format|
      invocation, profile = create_request(format, [@pdf, @image, @pdf])
      assert_equal [@pdf.public_id, @image.public_id, @pdf.public_id],
        invocation.content_bodies.find_by!(role: "request").upload_parts.map(&:public_id)
      assert_equal 2, invocation.content_bodies.find_by!(role: "request").content_body_uploads.count

      first = build(invocation, profile)
      assert_predicate first, :built?, "#{format}: #{first.refusal}"
      second = build(ModelInvocation.find(invocation.id), profile)
      assert_predicate second, :built?, "#{format}: #{second.refusal}"
      assert_equal JSON.parse(first.request.payload), JSON.parse(second.request.payload), format

      parts = wire_parts(format, JSON.parse(first.request.payload))
      assert_equal 4, parts.length
      assert_equal "Read in order", parts.first.fetch("text")
      assert_equal parts[1].except("cache_control"), parts[3].except("cache_control"),
        "a repeated occurrence stays repeated: #{format}"
      assert_equal({ "type" => "ephemeral" }, parts[3].fetch("cache_control")) if format == "anthropic_messages"
      assert_equal PDF, pdf_bytes(format, parts[1]), format
      assert_includes parts[2].to_json, "image/png", format
      refute_includes parts[2].to_json, "application/pdf", format
      if %w[openai_responses openai_compatible_chat].include?(format)
        assert_includes parts[1].to_json, "工程图.pdf"
      end
    end
  end

  test "a native PDF requires both the selected model and the adapted wire to support file input" do
    selection = DevModelLane.selection(workload: "text_generation", account: @account)
    assert_equal :unsupported_input_media, normalize(selection, [@pdf]).refusal

    catalog, = catalog_for("openai_responses")
    ModelCatalog.stub(:current, catalog) do
      selection = DevModelLane.selection(workload: "text_generation", account: @account)
      assert_predicate normalize(selection, [@pdf]), :accepted?
      assert_nil selection.execution_profile.input_media.fetch("file").token_cost,
        "unknown PDF token cost does not prevent admission"
      image_only_wire = selection.execution_profile.with(input_media: selection.execution_profile.input_media.except("file"))
      assert_equal :unsupported_input_media,
        normalize(selection.with(execution_profile: image_only_wire), [@pdf]).refusal

      ordinary = upload("source text", "paper.pdf", "text/plain")
      assert_equal :unsupported_input_media, normalize(selection, [ordinary]).refusal,
        "a PDF filename does not turn an ordinary file into native media"
    end
  end

  test "PDF bytes obey the inline bound during acceptance and after preparation" do
    invocation, profile = create_request("openai_responses", [@pdf])
    catalog, = catalog_for("openai_responses")
    predicate = Nexus::SizeBounds.method(:bytes_within?)
    Nexus::SizeBounds.stub(:bytes_within?, ->(name, bytes) { name == :inline_binary_bound ? bytes <= PDF.bytesize : predicate.call(name, bytes) }) do
      ModelCatalog.stub(:current, catalog) do
        selection = DevModelLane.selection(workload: "text_generation", account: @account)
        assert_predicate normalize(selection, [@pdf]), :accepted?
        too_large = upload(PDF + "x", "larger.pdf", "application/pdf")
        assert_equal :input_media_too_large, normalize(selection, [too_large]).refusal
      end
      assert_predicate build(invocation, profile), :built?
      prepared = { @pdf.public_id => SimpleInference::MediaInput.new(bytes: PDF + "x", media_type: "application/pdf") }
      ModelRequests::UploadMedia.stub(:by_public_id, prepared) do
        result = build(invocation, profile)
        assert_equal :input_media_too_large, result.refusal
        assert_nil result.request
      end
    end
  end

  test "a PDF is passed through without image rendering or a second MIME sniff" do
    invocation, profile = create_request("openai_responses", [@pdf])
    ContentUploads::Representations.stub(:prepared, ->(*) { raise "PDF passed to image preparation" }) do
      SimpleInference::MediaType.stub(:detect, ->(*) { raise "normalized upload sniffed again" }) do
        built = build(invocation, profile)
        assert_predicate built, :built?, built.refusal.inspect
        assert_equal PDF, pdf_bytes("openai_responses", wire_parts("openai_responses", JSON.parse(built.request.payload)).last)
      end
    end
  end

  test "a lost PDF blob produces the existing typed preparation refusal" do
    invocation, profile = create_request("openai_responses", [@pdf])
    @pdf.file.blob.delete

    result = build(invocation, profile)
    assert_equal :input_media_unusable, result.refusal
    assert_nil result.request
  end

  private

    def upload(bytes, filename, content_type)
      @account.content_uploads.create!(creating_user: @creator,
        file: ActiveStorage::Blob.create_and_upload!(io: StringIO.new(bytes), filename: filename,
          content_type: content_type, identify: false))
    end

    def catalog_for(format)
      snapshot = ModelCatalog.current
      base = snapshot.models.fetch("dev/mock-text")
      model = base.merge("api_format" => format, "capabilities" => {
        "input_modalities" => %w[image file], "output_modalities" => ["text"],
        "limits" => { "input_tokens" => 8192, "output_tokens" => 2048 },
        "generation_parameters" => { "max_output_tokens" => {
          "kind" => "integer", "default" => 64, "minimum" => 1, "maximum" => 2048, "allowed_values" => nil,
        } },
      })
      catalog = snapshot.with(models: snapshot.models.merge("dev/mock-text" => model))
      profile = ModelCatalog::ProfileBuilder.call(model_ref: "dev/mock-text", model: model,
        provider: snapshot.providers.fetch("dev"))
      [catalog, profile]
    end

    def input_message(uploads)
      Nexus::TextInputMessage.new(role: "user", parts: [Nexus::TextInputPart.new(type: "text", text: "Read in order")] +
        uploads.map { |upload| Nexus::UploadInputPart.new(type: "upload", upload_public_id: upload.public_id) })
    end

    def normalize(selection, uploads)
      ModelSelection::Workloads.normalize_workload_input(selection: selection, input: [input_message(uploads)], uploads: uploads)
    end

    def create_request(format, uploads)
      catalog, profile = catalog_for(format)
      command = InferenceRequests::Create::Command.new(
        workspace: workspaces(:shared), creating_user: @creator, workload: "text_generation",
        submitted: DevModelLane.submission_for("text_generation"), configuration: {},
        input: [input_message(uploads)], upload_public_ids: uploads.map(&:public_id).uniq,
        billing_subject: nil, idempotency_key: SecureRandom.uuid_v7
      )
      result = ModelCatalog.stub(:current, catalog) { InferenceRequests::Create.call(command: command, port: DevModelLane.port) }
      assert_predicate result, :created?, result.refusal.inspect
      [InferenceRequest.find_by!(public_id: result.accepted.fetch("inference_request_public_id")).model_invocation, profile]
    end

    def build(invocation, profile)
      ModelRequests::Build.call(invocation: invocation, profile: profile, base_url: "http://example.test", host: "solid_queue")
    end

    def wire_parts(format, payload)
      case format
      when "openai_responses" then payload.fetch("input").first.fetch("content")
      when "openai_compatible_chat", "anthropic_messages" then payload.fetch("messages").first.fetch("content")
      when "gemini_generate_content" then payload.fetch("contents").first.fetch("parts")
      else raise "unhandled PDF wire #{format}"
      end
    end

    def pdf_bytes(format, part)
      encoded = case format
      when "openai_responses"
        assert_equal "input_file", part.fetch("type")
        part.fetch("file_data").delete_prefix("data:application/pdf;base64,")
      when "openai_compatible_chat"
        assert_equal "file", part.fetch("type")
        part.fetch("file").fetch("file_data").delete_prefix("data:application/pdf;base64,")
      when "anthropic_messages"
        assert_equal "document", part.fetch("type")
        assert_equal "application/pdf", part.fetch("source").fetch("media_type")
        part.fetch("source").fetch("data")
      when "gemini_generate_content"
        assert_equal "application/pdf", part.fetch("inline_data").fetch("mime_type")
        part.fetch("inline_data").fetch("data")
      else raise "unhandled PDF wire #{format}"
      end
      Base64.strict_decode64(encoded)
    end
end
