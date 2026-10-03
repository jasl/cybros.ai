require "test_helper"
require "test_helpers/conversation_api_test_helper"

class AgentAPI::V1::ConversationRawRegenerationTest < ActionDispatch::IntegrationTest
  include ConversationAPITestHelper
  include InvocationHarness
  include LoopLaneTestHelper

  HISTORY = "Earlier history must stay outside this raw request.".freeze
  INSTRUCTIONS = "Use only the supplied messages.".freeze

  %w[direct loop].each do |engine|
    test "#{engine} raw regeneration preserves roles and repeated messages without importing history" do
      entries = ordered_entries
      conversation, turn, origin, first_wire = settled_raw_reply(engine, entries: entries)
      original_request = read_request(conversation, turn, origin)
      expected = entries.map { |entry| [entry.fetch("role"), entry.fetch("parts").map { |part| part.fetch("text") }] }
      assert_equal expected, message_texts(first_wire)

      sibling = regenerate(conversation, turn)
      wire = complete_reply(conversation, turn, sibling)

      assert_equal expected, message_texts(wire)
      assert_equal entries, read_request(conversation, turn, sibling).fetch("entries")
      assert_equal original_request, read_request(conversation, turn, origin)
    end

    test "#{engine} raw text without instructions stays raw when regenerated on another model" do
      conversation, turn, origin, = settled_raw_reply(engine, text: "Only this question.")
      original_request = read_request(conversation, turn, origin)

      sibling = regenerate(conversation, turn)
      wire = complete_reply(conversation, turn, sibling)

      assert_equal [["user", ["Only this question."]]], message_texts(wire)
      assert_nil wire["instructions"]
      assert_equal original_request, read_request(conversation, turn, origin)
    end

    test "#{engine} raw regeneration sends model bound reasoning to its own model only, and nothing in its place" do
      native = {
        "type" => "reasoning_item",
        "native_origin" => { "provider_id" => "dev", "model_id" => "mock-text", "api_format" => "openai_responses" },
        "payload" => { "type" => "reasoning", "encrypted_content" => "original-model-only",
                       "summary" => [{ "type" => "summary_text", "text" => "A portable plan." }] },
      }
      entries = [raw_message("user", "The supplied question."), native,
        raw_message("assistant", "The supplied answer."), raw_message("user", "Check that answer.")]
      conversation, turn, origin, first_wire = settled_raw_reply(engine, entries: entries)
      original_request = read_request(conversation, turn, origin)
      assert_equal [native.fetch("payload")], first_wire.fetch("input").select { |item| item["type"] == "reasoning" }

      sibling = regenerate(conversation, turn)
      wire = complete_reply(conversation, turn, sibling)

      assert_equal [
        ["user", ["The supplied question."]],
        ["assistant", ["The supplied answer."]],
        ["user", ["Check that answer."]],
      ], message_texts(wire)
      assert_not_includes wire.to_json, "original-model-only"
      assert_not_includes wire.to_json, "A portable plan.", "no summary rides as words either"
      assert_equal entries, read_request(conversation, turn, sibling).fetch("entries")
      assert_equal original_request, read_request(conversation, turn, origin)
    end

    test "#{engine} raw image regeneration refuses an incapable target and preserves every placement on a capable target" do
      upload_id = upload_picture
      entries = [{ "role" => "user", "parts" => [
        { "type" => "text", "text" => "Before." },
        { "type" => "upload", "upload_public_id" => upload_id },
        { "type" => "text", "text" => "Between." },
        { "type" => "upload", "upload_public_id" => upload_id },
        { "type" => "text", "text" => "After." },
      ] }]
      conversation, turn, origin, first_wire = settled_raw_reply(engine, entries: entries)
      original_request = read_request(conversation, turn, origin)

      assert_no_difference ["ConversationTurnVariant.count", "ModelInvocation.count", "AgentLoop.count", "ContentBody.count"] do
        post regeneration_path(conversation, turn), headers: auth, as: :json,
          params: { regeneration: { model: { model: "dev/mock-text-only" }, configuration: {} } }
        assert_response :unprocessable_entity
        assert_equal "unsupported_input_media", response.parsed_body.dig("error", "code")
      end
      assert_completed(conversation, turn, origin)

      sibling = regenerate(conversation, turn, model: "dev/mock-windowless")
      wire = complete_reply(conversation, turn, sibling)
      parts = wire.fetch("input").sole.fetch("content")
      assert_equal %w[input_text input_image input_text input_image input_text], parts.map { |part| part.fetch("type") }
      assert_equal ["Before.", "Between.", "After."], parts.filter_map { |part| part["text"] }
      pictures = parts.filter_map { |part| part["image_url"] }
      assert_equal 2, pictures.length
      assert pictures.all? { |data| data.start_with?("data:image/png;base64,") }
      assert_equal pictures.first, pictures.last
      assert_equal first_wire.fetch("input"), wire.fetch("input")
      assert_equal entries, read_request(conversation, turn, sibling).fetch("entries")
      assert_equal original_request, read_request(conversation, turn, origin)
    end
  end

  %w[edit fork].each do |source|
    test "#{source} retains the raw question without inheriting the old execution when regenerated" do
      conversation, turn, origin, = settled_raw_reply("loop", entries: ordered_entries,
        instructions: INSTRUCTIONS, configuration: { temperature: 0.2, max_output_tokens: 37 })
      original_request = read_request(conversation, turn, origin)
      if source == "edit"
        post "#{conversation_turns_path(conversation)}/#{turn.public_id}/edit",
          headers: auth, as: :json, params: { edit: { text: "A human replacement answer." } }
        assert_response :success
      else
        post conversation_forks_path(conversation), headers: auth(SecureRandom.uuid), as: :json,
          params: { fork: { turn_public_id: turn.public_id } }
        assert_response :created
        conversation = Conversation.find_by!(public_id: response.parsed_body.dig("conversation", "public_id"))
        turn = conversation.conversation_turns.sole
      end

      sibling = regenerate(conversation, turn, configuration: nil)
      wire = complete_reply(conversation, turn, sibling)

      assert_equal "inference", sibling.source
      assert_equal ordered_entries, read_request(conversation, turn, sibling).fetch("entries")
      assert_equal ordered_entries.map { |entry| [entry.fetch("role"), entry.fetch("parts").map { |part| part.fetch("text") }] },
        message_texts(wire)
      assert_nil wire["instructions"]
      assert_empty wire.fetch("tools", [])
      assert_equal 1.0, wire.fetch("temperature")
      assert_equal 256, wire.fetch("max_output_tokens")
      original_turn = origin.conversation_turn
      assert_equal original_request, read_request(original_turn.conversation, original_turn, origin)
    end
  end

  private

    def ordered_entries
      [raw_message("system", "The supplied system message."), raw_message("developer", "The supplied developer message."),
        raw_message("user", "Repeated words."), raw_message("user", "Repeated words."),
        raw_message("assistant", "The supplied answer."), raw_message("user", "The final question.")]
    end

    def raw_message(role, text)
      { "role" => role, "parts" => [{ "type" => "text", "text" => text }] }
    end

    def message_texts(wire)
      wire.fetch("input").map { |item| [item.fetch("role"), item.fetch("content").map { |part| part.fetch("text") }] }
    end

    def settled_raw_reply(engine, **input)
      fields = { title: "Raw regeneration" }
      if engine == "loop"
        agent = users(:agent)
        declare_tools!(agent)
        fields[:answering_user_public_id] = agent.public_id
      end
      post conversations_path, headers: auth(SecureRandom.uuid), as: :json,
        params: { conversation: fields }
      assert_response :created
      conversation = Conversation.find_by!(public_id: response.parsed_body.dig("conversation", "public_id"))

      post conversation_inputs_path(conversation), headers: auth(SecureRandom.uuid), as: :json,
        params: { input: { text: HISTORY } }
      assert_response :accepted
      Current.reset
      perform_enqueued_jobs only: Conversations::Inputs::DrainJob

      post conversation_inputs_path(conversation), headers: auth(SecureRandom.uuid), as: :json,
        params: { input: { kind: "direct_reply", context_mode: "raw", model: { model: "dev/mock-text" }, **input } }
      assert_response :accepted
      Current.reset
      perform_enqueued_jobs only: Conversations::Inputs::DrainJob
      turn = conversation.conversation_turns.order(:position).last
      origin = turn.active_variant
      assert_equal(engine == "loop" ? "agent_loop" : "inference", origin.source)
      [conversation, turn, origin, complete_reply(conversation, turn, origin)]
    end

    def regenerate(conversation, turn, model: "dev/mock-text-only", configuration: {})
      post regeneration_path(conversation, turn), headers: auth, as: :json,
        params: { regeneration: { model: { model: model }, configuration: configuration } }
      assert_response :accepted
      turn.conversation_turn_variants.find_by!(public_id: response.parsed_body.dig("variant", "public_id"))
    end

    def regeneration_path(conversation, turn)
      "#{conversation_turns_path(conversation)}/#{turn.public_id}/regeneration"
    end

    def complete_reply(conversation, turn, variant)
      Current.reset
      agent_loop = variant.agent_loop
      schedule_loop!(agent_loop) if agent_loop
      invocation = agent_loop ? agent_loop.model_invocations.sole : variant.model_invocation
      candidate = ModelInvocations::AdmitQueuedWork.call.admitted.find { |row| row.invocation.id == invocation.id }
      assert_not_nil candidate, "the accepted reply is admitted"
      clear_enqueued_jobs
      wire = nil
      fake_dispatch(sse_success("A reply.")) do |adapter|
        ModelInvocations::RunJob.perform_now(candidate.attempt.public_id)
        wire = JSON.parse(adapter.requests.sole.fetch(:body))
      end
      if agent_loop
        AgentLoops::ConvergeTerminalSteps.call(invocation_id: invocation.id)
        schedule_loop!(agent_loop)
        Conversations::Turns::Converge.call(conversation_id: conversation.id, agent_loop_id: agent_loop.id)
      else
        Conversations::Turns::Converge.call(invocation_id: invocation.id)
      end
      clear_enqueued_jobs
      assert_completed(conversation, turn, variant)
      wire
    end

    def assert_completed(conversation, turn, variant)
      get conversation_turns_path(conversation), headers: auth
      assert_response :success
      rendered = response.parsed_body.fetch("turns").find { |row| row.fetch("public_id") == turn.public_id }
      assert_equal "completed", rendered.fetch("status")
      assert_equal variant.public_id, rendered.dig("active_variant", "public_id")
    end

    def read_request(conversation, turn, variant)
      get request_path(conversation, turn, variant), headers: auth
      assert_response :success
      response.parsed_body.fetch("request")
    end

    def upload_picture
      Tempfile.create(["raw-regeneration", ".png"], binmode: true) do |file|
        file.write(png_bytes)
        file.flush
        post agent_api_v1_uploads_path, headers: auth,
          params: { upload: { file: Rack::Test::UploadedFile.new(file.path, "image/png", original_filename: "diagram.png") } }
        assert_response :created
        response.parsed_body.dig("upload", "public_id")
      end
    end
end
