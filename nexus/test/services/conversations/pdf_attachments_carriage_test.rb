require "test_helper"

class Conversations::PdfAttachmentsCarriageTest < ActiveJob::TestCase
  include InvocationHarness
  include RunLaneTestHelper

  PDF = "%PDF-1.7\nprivate document contents\n%%EOF\n".freeze
  PNG = Base64.decode64(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
  ).freeze
  Assembly = Conversations::ContextAssembly

  setup do
    @account = accounts(:cybros)
    @workspace = workspaces(:shared)
    @human = users(:member)
    DevModelLane.ensure_enabled!(@account)
    @conversation = Conversation.create!(workspace: @workspace, creating_user: @human)
  end

  test "a mixed attachment input seals native PDF and image parts in order beside the ordinary file index" do
    with_pdf_model do
      document = upload("report.pdf")
      image = upload("diagram.png", bytes: PNG, content_type: "image/png")
      ordinary = upload("notes.txt", bytes: "working notes", content_type: "text/plain")
      reply!(attachments: [document.public_id, image.public_id, ordinary.public_id])
      assert_equal 1, drain!

      variant = last_variant
      request = sealed_request(variant)
      parts = request.entry_payloads.last.fetch("parts")
      assert_equal %w[text upload upload text], parts.map { |part| part.fetch("type") }
      assert_equal [document.public_id, image.public_id], parts.filter_map { |part| part["upload_public_id"] }
      assert_includes parts.last.fetch("text"), "nexus://uploads/#{ordinary.public_id}"
      assert_includes parts.last.fetch("text"), "file content is available through attachment tools"
      assert_equal [document.id, image.id].sort, request.content_uploads.map(&:id).sort
      assert_equal [document.id, image.id, ordinary.id].sort,
        variant.content_bodies.find_by!(role: "prompt").content_uploads.map(&:id).sort

      built = build(admitted_attempt)
      assert_predicate built, :built?, built.refusal.inspect
      content = JSON.parse(built.request.payload).fetch("input").last.fetch("content")
      assert_equal %w[input_text input_file input_image input_text], content.map { |part| part.fetch("type") }
      assert_equal "report.pdf", content[1].fetch("filename")
      assert_equal "data:application/pdf;base64,#{Base64.strict_encode64(PDF)}", content[1].fetch("file_data")
      assert content[2].fetch("image_url").start_with?("data:image/png;base64,")
    end
  end

  test "a PDF-only message remains available for native history and an unsupported later model gets its pointer" do
    with_pdf_model do
      document = upload("only.pdf")
      accept!(kind: "message", text: nil, attachments: [document.public_id])
      assert_equal 1, drain!
      source = last_variant.content_bodies.find_by!(role: "content")
      assert_equal "", source.readable_text

      reply!(text: "read the document")
      assert_equal 1, drain!
      request = sealed_request(last_variant)
      assert_equal %w[upload text], request.entry_payloads.sole.fetch("parts").map { |part| part.fetch("type") }
      assert_equal [document.id], request.content_uploads.map(&:id)
      settle_reply!

      reply!(text: "what did it say?", model_ref: "mock-text-only")
      assert_equal 1, drain!
      request = sealed_request(last_variant)
      assert_empty request.content_uploads
      assert_empty upload_ids(request)
      assert_includes request.entry_payloads.to_json, "nexus://uploads/#{document.public_id}"
      assert_includes request.entry_payloads.to_json, "only.pdf"
      assert_equal [document.id], source.reload.content_uploads.map(&:id),
        "placement never removes the original attachment binding"
    end
  end

  test "regeneration re-places its own PDF-only seed under a capable replacement model" do
    with_pdf_model do
      document = upload("question.pdf")
      reply!(text: nil, attachments: [document.public_id], model_ref: "mock-text-only")
      assert_equal 1, drain!
      turn = @conversation.conversation_turns.sole
      assert_empty sealed_request(turn.active_variant).content_uploads
      settle_reply!

      result = Conversations::Turns::Regenerate.call(Conversations::Turns::Regenerate::Command.new(
        conversation: @conversation, turn_public_id: turn.public_id, acting_user: @human,
        provider_id: "dev", model_ref: "mock-text", reasoning_effort: nil, request_options: nil
      ))
      assert_predicate result, :accepted?, result.outcome.to_s
      request = sealed_request(result.value)
      assert_equal [document.public_id], upload_ids(request)
      assert_equal [document.id], request.content_uploads.map(&:id)
      assert_equal %w[upload], request.entry_payloads.sole.fetch("parts").map { |part| part.fetch("type") }
      assert_equal [document.id], result.value.content_bodies.find_by!(role: "prompt").content_uploads.map(&:id)
    end
  end

  test "a summary carries the PDF reference and omission reason without native bytes and cuts the old attachment" do
    with_pdf_model do
      document = upload("summarized.pdf")
      reply!(attachments: [document.public_id])
      assert_equal 1, drain!
      settle_reply!
      compacted = Conversations::Compaction::Request.call(Conversations::Compaction::Request::Command.new(
        conversation: @conversation, acting_user: @human
      ))
      assert_predicate compacted, :accepted?, compacted.outcome.to_s
      summary_loop = compacted.value.turn.active_variant.agent_run
      summary_input = summary_loop.agent_run_tasks.sole.input_body
      handed = summary_input.effective_text
      assert_includes handed, "nexus://uploads/#{document.public_id}"
      assert_includes handed, Assembly::AttachmentLine::NOT_CARRIED
      refute_includes handed, "private document contents"
      refute_includes handed, "data:application/pdf"
      assert_empty summary_input.content_uploads

      schedule_loop!(summary_loop)
      run_loop_round!(summary_loop, sse_success("DOCUMENT POINTER SAVED"))
      Conversations::Turns::Converge.call
      clear_enqueued_jobs
      assert_equal "completed", compacted.value.turn.reload.status
      reply!(text: "continue after the summary")
      assert_equal 1, drain!
      request = sealed_request(last_variant)
      assert_empty request.content_uploads
      assert_empty upload_ids(request)
      assert_includes request.entry_payloads.to_json, "DOCUMENT POINTER SAVED"
    end
  end

  test "fill costs follow each attachment MIME and unknown PDF cost does not inherit the image estimate" do
    with_pdf_model do
      document = upload("budget.pdf")
      image = upload("budget.png", bytes: PNG, content_type: "image/png")
      profile = DevModelLane.profile_for("dev/mock-text")
      assert_nil profile.input_media.fetch("file").token_cost
      assert_equal 0, Assembly::FillCost.attachment(profile, "application/pdf")
      text = Assembly::Segment.text_parts("inspect both")
      words = Assembly::Segment.plain("user", nil, parts: text)
      attached = words.with(parts: text + Assembly::AttachmentLine.parts([document, image]))
      assert_equal Assembly::FillCost.segment(words, profile) + profile.input_media.fetch("image").token_cost,
        Assembly::FillCost.segment(attached, profile)
    end
  end

  private

    def with_pdf_model(&block)
      current = ModelCatalog.current
      row = current.models.fetch("dev/mock-text")
      pdf = row.merge("capabilities" => row.fetch("capabilities").merge("input_modalities" => %w[image file]))
      catalog = current.with(models: current.models.merge("dev/mock-text" => pdf))
      ModelCatalog::CatalogValidation.validate_change(catalog.models, catalog.selectors, "dev/mock-text", catalog.providers)
      ModelCatalog.stub(:current, catalog, &block)
    end

    def upload(filename, bytes: PDF, content_type: "application/pdf")
      @account.content_uploads.create!(creating_user: @human,
        file: ActiveStorage::Blob.create_and_upload!(io: StringIO.new(bytes), filename: filename,
          content_type: content_type, identify: false))
    end

    def reply!(model_ref: "mock-text", **options)
      accept!(kind: "direct_reply", provider_id: "dev", model_ref: model_ref, **options)
    end

    def accept!(text: "inspect the attachments", attachments: nil, **options)
      result = Conversations::Inputs::Create.call(Conversations::Inputs::Create::Command.new(**{
        host: @conversation, acting_user: @human, kind: "message", role: "user",
        entries: text ? [{ "text" => text }] : [], attachments: attachments, visible_in_context: true,
        delivery_mode: "queue", context_mode: nil, context_options: nil, expected_context_revision: nil,
        expected_tail_turn_public_id: nil, provider_id: nil, model_ref: nil,
        reasoning_effort: nil, request_options: nil,
      }.merge(options)))
      assert_predicate result, :accepted?, result.outcome.to_s
      result.value
    end

    def drain! = Conversations::Inputs::ApplyNext.drain(conversation_id: @conversation.id)
    def last_variant = @conversation.conversation_turns.order(:position).last.active_variant
    def sealed_request(variant) = variant.model_invocation.content_bodies.find_by!(role: "request")

    def upload_ids(body)
      body.entry_payloads.flat_map { |entry| entry.fetch("parts", []).filter_map { |part| part["upload_public_id"] } }
    end

    def settle_reply!
      apply_via(admitted_attempt, sse_success("document inspected"))
      Conversations::Turns::Converge.call
      clear_enqueued_jobs
    end

    def admitted_attempt
      admitted = ModelInvocations::AdmitQueuedWork.call.admitted.find do |candidate|
        candidate.attempt.model_invocation.conversation_id == @conversation.id
      end
      raise "reply not admitted" if admitted.nil?

      clear_enqueued_jobs
      admitted.attempt
    end
end
