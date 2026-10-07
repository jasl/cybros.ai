require "test_helper"
require "test_helpers/conversation_api_test_helper"

class AgentAPI::V1::ConversationRegenerationRequestTest < ActionDispatch::IntegrationTest
  include ConversationAPITestHelper
  include InvocationHarness
  include RunLaneTestHelper

  INSTRUCTIONS = "Answer using the supplied facts only.".freeze
  ORIGINAL_CONFIGURATION = { "temperature" => 0.2, "max_output_tokens" => 37 }.freeze

  %w[direct loop].each do |engine|
    test "#{engine} regeneration replays one acceptance while running and after completion" do
      conversation, turn, = settled_reply(engine)
      path = "#{conversation_turns_path(conversation)}/#{turn.public_id}/regeneration"
      key = SecureRandom.uuid
      post path, headers: auth(key), as: :json, params: { regeneration: {} }
      assert_response :accepted
      accepted = response.parsed_body
      sibling = turn.conversation_turn_variants.find_by!(public_id: accepted.dig("variant", "public_id"))
      clear_enqueued_jobs

      assert_regeneration_replay(path, key, turn, accepted)
      complete_reply(conversation, turn, sibling)
      assert_regeneration_replay(path, key, turn, accepted)

      assert_no_difference -> { turn.conversation_turn_variants.count } do
        post path, headers: auth(key), as: :json, params: { regeneration: { configuration: {} } }
        assert_response :conflict
        assert_equal "idempotency_envelope_mismatch", response.parsed_body.dig("error", "code")
        post path, headers: auth(key), as: :json, params: { regeneration: { model: { model: "dev/mock-text-only" } } }
        assert_response :conflict
        assert_equal "idempotency_envelope_mismatch", response.parsed_body.dig("error", "code")
        post "#{conversation_turns_path(conversation)}/#{SecureRandom.uuid_v7}/regeneration",
          headers: auth(key), as: :json, params: { regeneration: {} }
        assert_response :conflict
        assert_equal "idempotency_envelope_mismatch", response.parsed_body.dig("error", "code")
      end

      assert_difference -> { turn.conversation_turn_variants.count }, 1 do
        post path, headers: auth(SecureRandom.uuid), as: :json, params: { regeneration: {} }
        assert_response :accepted
        assert_not_equal sibling.public_id, response.parsed_body.dig("variant", "public_id")
      end
    end

    test "#{engine} regeneration inherits omitted configuration and raw instructions" do
      assert_regenerated_request(engine, regeneration: {}, expected: ORIGINAL_CONFIGURATION)
    end

    test "#{engine} regeneration replaces explicit configuration but retains raw instructions" do
      assert_regenerated_request(engine,
        regeneration: { configuration: { temperature: 0.7 } },
        expected: { "temperature" => 0.7, "max_output_tokens" => 256 })
    end

    test "#{engine} regeneration resets empty configuration but retains raw instructions" do
      assert_regenerated_request(engine, regeneration: { configuration: {} },
        expected: { "temperature" => 1.0, "max_output_tokens" => 256 })
    end

    test "#{engine} regeneration rejects incompatible inherited configuration until explicitly reset" do
      conversation, turn, origin, = settled_reply(engine)
      original_request = read_request(conversation, turn, origin)
      path = "#{conversation_turns_path(conversation)}/#{turn.public_id}/regeneration"
      model = { model: "dev/mock-windowless" }

      assert_no_difference -> { turn.conversation_turn_variants.count } do
        post path, headers: auth(SecureRandom.uuid), as: :json, params: { regeneration: { model: model } }
        assert_response :unprocessable_entity
        assert_equal "unsupported_generation_parameter", response.parsed_body.dig("error", "code")
      end
      get conversation_turns_path(conversation), headers: auth
      assert_response :success
      assert_equal "completed", response.parsed_body.fetch("turns").sole.fetch("status")

      post path, headers: auth(SecureRandom.uuid), as: :json, params: { regeneration: { model: model, configuration: {} } }
      assert_response :accepted
      sibling = turn.conversation_turn_variants.find_by!(public_id: response.parsed_body.dig("variant", "public_id"))
      wire = complete_reply(conversation, turn, sibling)
      assert_equal INSTRUCTIONS, wire["instructions"]
      assert_empty wire.slice(*ORIGINAL_CONFIGURATION.keys)
      assert_equal original_request, read_request(conversation, turn, origin)
    end
  end

  test "regeneration requires a key and a retained receipt is caller scoped and read only" do
    conversation, turn, = settled_reply("direct")
    path = "#{conversation_turns_path(conversation)}/#{turn.public_id}/regeneration"
    assert_no_difference -> { turn.conversation_turn_variants.count } do
      post path, headers: auth, as: :json, params: { regeneration: {} }
      assert_response :bad_request
    end

    key = SecureRandom.uuid
    post path, headers: auth(key), as: :json, params: { regeneration: {} }
    assert_response :accepted
    accepted = response.parsed_body
    receipt = ConversationCommandReceipt.find_by!(host: conversation, operation: "regeneration", idempotency_key: key)
    receipt_path = "#{conversation_path(conversation)}/regeneration_receipt"
    clear_enqueued_jobs
    assert_no_changes -> { [receipt.reload.attributes, turn.reload.attributes, turn.conversation_turn_variants.count] } do
      assert_no_enqueued_jobs do
        get receipt_path, headers: auth, params: { idempotency_key: key }
        assert_response :success
        assert_equal accepted, response.parsed_body
      end
    end

    other = create_access_token_fixture(user: users(:curator), name: "Receipt reader").secret
    get receipt_path, headers: { "Authorization" => "Bearer #{other}" }, params: { idempotency_key: key }
    assert_response :not_found
    get "#{conversation_path(create_reply_conversation("direct"))}/regeneration_receipt",
      headers: auth, params: { idempotency_key: key }
    assert_response :not_found

    receipt.update_columns(created_at: 25.hours.ago)
    assert_no_difference "ConversationCommandReceipt.count" do
      get receipt_path, headers: auth, params: { idempotency_key: key }
      assert_response :not_found
    end
    assert receipt.reload, "expiry on a GET neither deletes nor runs work"
  end

  private

    def assert_regeneration_replay(path, key, turn, accepted)
      assert_no_difference -> { turn.conversation_turn_variants.count } do
        assert_no_enqueued_jobs do
          post path, headers: auth(key), as: :json, params: { regeneration: {} }
          assert_response :accepted
          assert_equal "true", response.headers["Idempotency-Replayed"]
          assert_equal accepted, response.parsed_body
        end
      end
    end

    def assert_regenerated_request(engine, regeneration:, expected:)
      conversation, turn, origin, original_wire = settled_reply(engine)
      original_request = read_request(conversation, turn, origin)

      post "#{conversation_turns_path(conversation)}/#{turn.public_id}/regeneration",
        headers: auth(SecureRandom.uuid), as: :json, params: { regeneration: regeneration }
      assert_response :accepted
      sibling = turn.conversation_turn_variants.find_by!(
        public_id: response.parsed_body.dig("variant", "public_id")
      )
      assert_equal origin.source, sibling.source
      regenerated_wire = complete_reply(conversation, turn, sibling)
      regenerated_request = read_request(conversation, turn, sibling)

      assert_equal INSTRUCTIONS, regenerated_wire["instructions"], "raw instructions reach the provider again"
      assert_equal INSTRUCTIONS, regenerated_request.dig("request_options", "instructions")
      assert_equal expected, regenerated_wire.slice(*ORIGINAL_CONFIGURATION.keys)
      assert_equal expected, regenerated_request.fetch("request_options").slice(*ORIGINAL_CONFIGURATION.keys)
      assert_equal original_wire.fetch("input"), regenerated_wire.fetch("input"), "same model, same sealed input"
      assert_equal original_request.fetch("entries"), regenerated_request.fetch("entries")
      assert_equal original_request, read_request(conversation, turn, origin), "the original request remains immutable"
    end

    def settled_reply(engine)
      conversation = create_reply_conversation(engine)
      post conversation_inputs_path(conversation), headers: auth(SecureRandom.uuid), as: :json,
        params: { input: { kind: "direct_reply", context_mode: "raw", instructions: INSTRUCTIONS,
                           model: { model: "dev/mock-text" }, configuration: ORIGINAL_CONFIGURATION,
                           text: "A fact." } }
      assert_response :accepted
      Current.reset
      perform_enqueued_jobs only: Conversations::Inputs::DrainJob
      turn = conversation.conversation_turns.sole
      origin = turn.active_variant
      assert_equal(engine == "loop" ? "run" : "inference", origin.source)
      wire = complete_reply(conversation, turn, origin)
      assert_equal INSTRUCTIONS, wire.fetch("instructions")
      assert_equal ORIGINAL_CONFIGURATION, wire.slice(*ORIGINAL_CONFIGURATION.keys)
      [conversation, turn, origin, wire]
    end

    def create_reply_conversation(engine)
      fields = { title: "Raw regeneration" }
      if engine == "loop"
        agent = users(:agent)
        declare_tools!(agent)
        fields[:answering_user_public_id] = agent.public_id
      end
      post conversations_path, headers: auth(SecureRandom.uuid), as: :json,
        params: { conversation: fields }
      assert_response :created
      Conversation.find_by!(public_id: response.parsed_body.dig("conversation", "public_id"))
    end

    def complete_reply(conversation, turn, variant)
      Current.reset
      agent_run = variant.agent_run
      schedule_loop!(agent_run) if agent_run
      invocation = agent_run ? agent_run.model_invocations.sole : variant.model_invocation
      candidate = ModelInvocations::AdmitQueuedWork.call.admitted.find { |row| row.invocation.id == invocation.id }
      assert_not_nil candidate, "the accepted reply is admitted"
      clear_enqueued_jobs
      wire = nil
      fake_dispatch(sse_success("A reply.")) do |adapter|
        ModelInvocations::RunJob.perform_now(candidate.attempt.public_id)
        wire = JSON.parse(adapter.requests.sole.fetch(:body))
      end
      if agent_run
        AgentRuns::ConvergeTerminalSteps.call(invocation_id: invocation.id)
        schedule_loop!(agent_run)
        Conversations::Turns::Converge.call(conversation_id: conversation.id, agent_run_id: agent_run.id)
      else
        Conversations::Turns::Converge.call(invocation_id: invocation.id)
      end
      clear_enqueued_jobs
      get conversation_turns_path(conversation), headers: auth
      assert_response :success
      rendered = response.parsed_body.fetch("turns").sole
      assert_equal "completed", rendered.fetch("status")
      assert_equal variant.public_id, rendered.dig("active_variant", "public_id")
      wire
    end

    def read_request(conversation, turn, variant)
      get request_path(conversation, turn, variant), headers: auth
      assert_response :success
      response.parsed_body.fetch("request")
    end
end
