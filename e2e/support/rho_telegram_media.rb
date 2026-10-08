require "support/mock_llm/app"
require "support/pdf_document"

module E2E
  # Reuse the Telegram journey's actual Core, member SDK, daemon and Nexus world.
  # The only substitutes are Telegram file IO and the existing dev provider.
  module RhoTelegramMedia
    def test_a_telegram_photo_reaches_the_model_and_generated_image_capture_returns_as_a_photo
      boot_runtime(allowed: [101])
      bytes = E2E::MockLLM::App::PIXEL_PNG.unpack1("m0")
      @telegram.provide_file("photo-large", bytes)
      arguments = CGI.escape(JSON.generate("prompt" => "Draw a small blue square"))
      incoming = media_update(1, "photo", [
        { "file_id" => "photo-small", "width" => 1, "height" => 1 },
        { "file_id" => "photo-large", "width" => 2, "height" => 2, "file_size" => bytes.bytesize },
      ], caption: "!mock tool_call=image_generate:#{arguments} reply=photo-answer -- describe this photo and draw")
      @runtime.consume(incoming)
      conversation = @workspace.conversation(current("101:0"))
      turn = await("the photo's generated-image reply") do
        tick
        conversation.turns.list.items.find { |row| row.kind == "direct_reply" && row.status == "completed" }
      end
      assert_equal "Mock: photo-answer", turn.active_variant.content
      request = @workspace.runs.run(turn.active_variant.run_public_id).tasks_context("r1").request
      image = request.entries.flat_map { |entry| entry.fetch("parts", []) }.find { |part| part["type"] == "upload" }
      refute_nil image, "the incoming image reaches the model's sealed request, not a text placeholder"
      original = StringIO.new
      @client.uploads.bytes(image.fetch("upload_public_id"), original)
      assert_equal bytes, original.string.b
      assert_includes successful_tool_output(turn, "image_generate"), "image generated"
      await("the committed image capture reaches Telegram") { tick; @telegram.uploads.length == 1 }
      sent = @telegram.uploads.fetch(0)
      assert_equal "sendPhoto", sent.fetch(:method)
      assert_equal "photo", sent.fetch(:field)
      assert_equal "image/png", sent.fetch(:content_type)
      assert_equal bytes, sent.fetch(:bytes).b, "InferenceRequest output survives runner capture and authenticated upload download"
      assert_equal "101", sent.fetch(:params).fetch(:chat_id)
      assert_equal ["photo-large"], @telegram.downloads

      @runtime.consume(incoming)
      tick
      assert_equal 1, conversation.events(limit: 100).count { |event| event.type == "input_accepted" }
      assert_equal 1, @telegram.uploads.length
      assert_empty @logs
    end

    def test_a_document_is_imported_by_the_runner_and_an_explicit_pdf_publication_returns_to_telegram
      boot_runtime(allowed: [101])
      marker = "file-content-#{SecureRandom.hex(6)}"
      bytes = "# Input notes\n#{marker}\n".b
      @telegram.provide_file("document-notes", bytes)
      incoming = media_update(1, "document", { "file_id" => "document-notes", "file_name" => "notes.md",
        "mime_type" => "text/markdown", "file_size" => bytes.bytesize },
        caption: "!mock reply=file-received -- retain this document for the next request")
      @runtime.consume(incoming)
      conversation = @workspace.conversation(current("101:0"))
      first = media_reply(conversation, "file-received")
      request = @workspace.runs.run(first.active_variant.run_public_id).tasks_context("r1").request
      parts = request.entries.flat_map { |entry| entry.fetch("parts", []) }
      refute parts.any? { |part| part["type"] == "upload" }, "ordinary files do not become native model media"
      text = parts.filter_map { |part| part["text"] }.join("\n")
      reference = text[%r{nexus://uploads/[0-9a-f-]{36}}]
      refute_nil reference, text
      assert_includes text, "notes.md"
      refute_includes text, marker, "ingress indexes the file rather than silently inlining it"
      assert_equal ["document-notes"], @telegram.downloads

      arguments = CGI.escape(JSON.generate("upload" => reference))
      receive(update(2, "!mock tool_call=file_import:#{arguments} reply=file-imported -- import the previous attachment"))
      imported = media_reply(conversation, "file-imported")
      assert_includes successful_tool_output(imported, "file_import"), "Imported notes.md"
      imported_loop = @workspace.runs.run(imported.active_variant.run_public_id)
      imported_task = imported_loop.fetch.tasks.find { |task| task.tool_name == "file_import" }
      assert_equal "runner", imported_task.addressed_to.role
      path = imported_loop.task(imported_task.key).structured_content.fetch("path")
      assert_empty @telegram.uploads, "an import is not a user-facing publication"

      report = "report-#{SecureRandom.hex(4)}.pdf"
      pdf = E2E::PdfDocument.bytes(marker)
      # The dev provider counts the visible history's answered calls. Keep
      # the previous import in its script so this turn starts at the read.
      script = [
        ["file_import", { "upload" => reference }],
        ["read", { "path" => path }],
        ["write", { "path" => report, "content" => pdf }],
        ["file_publish", { "path" => report }],
      ].map { |name, args| "#{name}:#{CGI.escape(JSON.generate(args))}" }.join(",")
      receive(update(3, "!mock tool_call=#{script} reply=report-ready -- read the imported notes and publish the PDF"))
      finished = media_reply(conversation, "report-ready")
      assert_includes successful_tool_output(finished, "read"), marker
      successful_tool_output(finished, "write")
      successful_tool_output(finished, "file_publish")
      await("the explicit PDF publication reaches Telegram") { tick; @telegram.uploads.length == 1 }
      sent = @telegram.uploads.fetch(0)
      assert_equal "sendDocument", sent.fetch(:method)
      assert_equal "document", sent.fetch(:field)
      assert_equal report, sent.fetch(:filename)
      assert_equal "application/pdf", sent.fetch(:content_type)
      assert_equal pdf.b, sent.fetch(:bytes).b
      assert_equal "101", sent.fetch(:params).fetch(:chat_id)

      @runtime.consume(incoming)
      2.times { tick }
      assert_equal 1, @telegram.uploads.length
      assert_equal ["document-notes"], @telegram.downloads
      assert_equal 3, conversation.events(limit: 100).count { |event| event.type == "input_accepted" }
      assert_empty @logs
    end

    def test_a_telegram_voice_uses_real_transcription_and_speech_inference_requests_without_duplicating_replay
      boot_runtime(allowed: [101], transcription_model: "dev/mock-transcription", speech_model: "dev/mock-speech")
      @runtime.consume(update(1, "/voice voice_only"))
      bytes = E2E::MockLLM::App::SILENCE_WAV.unpack1("m0")
      @telegram.provide_file("voice-note", bytes)
      incoming = media_update(2, "voice", { "file_id" => "voice-note", "file_size" => bytes.bytesize, "mime_type" => "audio/wav" },
        caption: "!mock reply=voice-answer -- answer this voice message")
      @runtime.consume(incoming)
      conversation = @workspace.conversation(current("101:0"))
      turn = await("the voice transcription is admitted and answered") do
        tick
        conversation.turns.list.items.find { |row| row.kind == "direct_reply" && row.status == "completed" }
      end
      transcript = "Mock transcription of #{bytes.bytesize} bytes"
      assert_includes request_text(turn), transcript, "the provider reports the bytes actually carried by multipart transcription"
      assert_equal "Mock: voice-answer", turn.active_variant.content
      await("the spoken reply's real InferenceRequest output reaches Telegram") { tick; @telegram.uploads.length == 1 }
      speech = @workspace.inference_requests.list(workload: "speech_generation").items
      assert_equal 1, speech.length
      spoken = @workspace.inference_requests.fetch(speech.fetch(0).public_id)
      assert_equal "completed", spoken.status
      assert_equal "speech_generation", spoken.workload
      assert_equal "audio/wav", spoken.result.files.fetch(0).content_type
      sent = @telegram.uploads.fetch(0)
      assert_equal "sendDocument", sent.fetch(:method), "WAV is delivered as a file; Telegram voice accepts OGG, MP3 or M4A"
      assert_equal "document", sent.fetch(:field)
      assert_equal bytes, sent.fetch(:bytes).b
      assert @telegram.formal(101).any? { |_method, params| params.fetch(:text) == "Mock: voice-answer" }, "text remains available beside speech"
      assert_empty @state.read.fetch("pending_inputs")
      assert_equal ["voice-note"], @telegram.downloads

      @runtime.consume(incoming)
      tick
      assert_equal 1, conversation.events(limit: 100).count { |event| event.type == "input_accepted" }
      assert_equal 1, @telegram.uploads.length
      assert_equal 1, @workspace.inference_requests.list(workload: "transcription").items.length
      assert_equal 1, @workspace.inference_requests.list(workload: "speech_generation").items.length
      assert_empty @logs
    end

    def test_reply_stop_retires_only_the_unadmitted_voice_and_keeps_the_following_message
      boot_runtime(allowed: [101], transcription_model: "dev/mock-transcription")
      bytes = E2E::MockLLM::App::SILENCE_WAV.unpack1("m0")
      @telegram.provide_file("voice-to-cancel", bytes)
      incoming = media_update(1, "voice", { "file_id" => "voice-to-cancel", "file_size" => bytes.bytesize, "mime_type" => "audio/wav" },
        caption: "!mock reply=canceled-voice -- do not admit this voice after Stop")
      @runtime.consume(incoming)
      conversation = @workspace.conversation(current("101:0"))
      tick
      pending = @state.read.fetch("pending_inputs").fetch(incoming.fetch("update_id").to_s)
      inference_request_id = pending.fetch("inference_request_id")
      transcription = await("the real transcription starts before Telegram admits its input") do
        row = @workspace.inference_requests.fetch(inference_request_id)
        row if %w[running completed failed].include?(row.status)
      end
      assert_equal "transcription", transcription.workload
      assert_includes %w[running completed], transcription.status
      # The provider can finish before the next poll. This journey holds the
      # admission boundary, not an artificial provider-running state.
      puts "  voice Stop before admission: InferenceRequest status=#{transcription.status}"
      assert_empty conversation.turns.list.items
      assert_empty conversation.inputs.list.items

      following = update(2, "!mock reply=following-message -- preserve the message after the voice")
      @runtime.consume(following)
      assert_equal 2, @state.read.fetch("pending_inputs").length
      stop = update(3, "/stop")
      stop.fetch("message")["reply_to_message"] = incoming.fetch("message")
      @runtime.consume(stop)
      assert_equal [following.fetch("update_id").to_s], @state.read.fetch("pending_inputs").keys
      settled = await("the original transcription settles after exact Stop") do
        row = @workspace.inference_requests.fetch(inference_request_id)
        row if %w[completed canceled failed].include?(row.status)
      end
      assert_includes %w[completed canceled], settled.status

      reply = await("the later message still completes after the voice is canceled") do
        tick
        conversation.turns.list.items.find { |turn| turn.kind == "direct_reply" && turn.status == "completed" }
      end
      assert_equal "Mock: following-message", reply.active_variant.content
      refute_includes request_text(reply), "Mock transcription of"
      await("only the later message is delivered") { tick; @telegram.formal(101).length == 1 }
      assert_equal "Mock: following-message", @telegram.formal(101).first.last.fetch(:text)

      @runtime.consume(incoming)
      @runtime.consume(stop)
      3.times { tick }
      assert_equal 1, conversation.events(limit: 100).count { |event| event.type == "input_accepted" }
      assert_equal 1, conversation.turns.list.items.length
      assert_equal 1, @workspace.inference_requests.list(workload: "transcription").items.length
      assert_equal ["voice-to-cancel"], @telegram.downloads
      assert_empty @state.read.fetch("pending_inputs")
      assert_empty @logs
    ensure
      stop_group_work(conversation)
    end

    private

      def media_reply(conversation, answer)
        await("the #{answer} document reply") do
          tick
          rows = conversation.turns.list.items
          failed = rows.find { |turn| turn.status == "failed" }
          flunk "Document reply failed: #{failed.to_h.inspect}" if failed
          rows.find { |turn| turn.kind == "direct_reply" && turn.status == "completed" && turn.active_variant.content == "Mock: #{answer}" }
        end
      end

      def media_update(id, kind, media, caption: nil)
        document = update(id, "")
        message = document.fetch("message")
        message.delete("text")
        message[kind] = media
        message["caption"] = caption if caption
        document
      end
  end
end
