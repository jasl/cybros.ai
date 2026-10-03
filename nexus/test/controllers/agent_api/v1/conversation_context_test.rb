require "test_helper"
require_relative "../../../test_helpers/conversation_api_test_helper"

class AgentAPI::V1::ConversationContextTest < ActionDispatch::IntegrationTest
  include ConversationAPITestHelper

  test "the estimate counts the assembled surface" do
    conversation = create_conversation!
    post conversation_inputs_path(conversation), headers: auth("i-4"), as: :json,
      params: { input: { text: "some context to count" } }
    perform_enqueued_jobs only: Conversations::Inputs::DrainJob

    post conversation_context_estimate_path(conversation), headers: auth, as: :json,
      params: { context_estimate: { prompt: "and a prompt",
                                    model: { model: "dev/mock-text" } } }

    assert_response :success
    estimate = response.parsed_body.fetch("context_estimate")
    assert_operator estimate.fetch("input_tokens"), :>, 0
    assert_equal 8192, estimate.fetch("catalog_input_token_limit")
  end

  # COMPACT NOW. The kernel picks no threshold and this does not change
  # that — it is a CALLER asking, which the wall-only trigger never left
  # room for. Every comparable product ships this button; this plane had
  # no route, no verb and no way to ask on either plane.
  test "a caller can compact on demand, and each refusal says something different" do
    conversation = create_conversation!

    # NOTHING TO COMPACT is not the same answer as a busy lane, and a
    # person who pressed a button is owed the difference.
    post conversation_compaction_path(conversation), headers: auth, as: :json
    assert_response :unprocessable_content
    assert_equal "nothing_to_compact", response.parsed_body.dig("error", "code")

    post conversation_inputs_path(conversation), headers: auth("k-1"), as: :json,
      params: { input: { text: "the work so far", model: { model: "dev/mock-text" } } }
    perform_enqueued_jobs only: Conversations::Inputs::DrainJob

    post conversation_compaction_path(conversation), headers: auth, as: :json,
      params: { compaction: { model: "dev/mock-text" } }
    assert_response :accepted
    assert_equal "compaction_summary", response.parsed_body.dig("turn", "kind")
    assert_equal "running", response.parsed_body.dig("turn", "status")

    # The lane is busy with the summary it just created, so asking again
    # is a conflict rather than a second summary.
    post conversation_compaction_path(conversation), headers: auth, as: :json,
      params: { compaction: { model: "dev/mock-text" } }
    assert_response :conflict
    assert_equal "conversation_busy", response.parsed_body.dig("error", "code")

    turn = conversation.conversation_turns.order(:position).last
    assert_equal "compaction_summary", turn.kind
    assert_equal "user", turn.role, "a summary of what a user said is never an instruction"
    item = conversation.conversation_event_items.where(item_type: "context_compacted").last
    assert_equal "manual", item.payload["trigger"],
      "a client reads a summary very differently when a person asked for it"
    refute item.payload.key?("input_public_id"), "there was no input to name"
  end

  # THE MANUAL DOOR MID-TURN: with a loop-backed reply running, the same route reaches that reply's
  # backing loop under conv → loop and answers the LOOP's vocabulary — here the round already on the
  # wire — and, when it arms, the round repaired and the summarizer's key beside the turn, read by
  # presence.
  test "compacting a running loop-backed turn answers the loop's vocabulary and the round it repaired" do
    agent = users(:agent)
    outcome = Users::DeclareConfiguration.call(user: agent,
      tool_definitions: [
        { "type" => "function", "function" => { "name" => "read_file", "parameters" => { "type" => "object" } } },
      ],
      approval_mode: "bypass", approval_rules: nil, prompt_mechanism: nil, prompt_template: nil,
      compaction_policy: nil
    )
    assert_equal :declared, outcome.outcome
    conversation = Conversation.create!(workspace: @workspace, creating_user: agent)
    post conversation_inputs_path(conversation), headers: auth("m-1"), as: :json,
      params: { input: { kind: "direct_reply", text: "read the index", model: { model: "dev/mock-text" } } }
    assert_response :accepted
    perform_enqueued_jobs only: Conversations::Inputs::DrainJob
    perform_enqueued_jobs only: AgentLoops::ScheduleJob
    turn = conversation.conversation_turns.sole
    agent_loop = turn.active_variant.agent_loop
    round = agent_loop.agent_loop_nodes.find_by!(node_key: "r1")
    assert_equal "running", round.status, "round one is on the wire: its request is sealed"

    post conversation_compaction_path(conversation), headers: auth, as: :json
    assert_response :conflict
    assert_equal "task_not_queued", response.parsed_body.dig("error", "code"),
      "the loop's own word, not `conversation_busy`: only a direct reply in flight is busy"

    armed = Conversations::Outcome.accepted(Conversations::Compaction::Request::Compacted.new(
      turn: turn, task: round, summary_task_key: "k1"
    ))
    Conversations::Compaction::Request.stub(:call, armed) do
      post conversation_compaction_path(conversation), headers: auth, as: :json
    end
    assert_response :accepted
    assert_equal turn.public_id, response.parsed_body.dig("turn", "public_id")
    assert_equal "direct_reply", response.parsed_body.dig("turn", "kind")
    assert_equal({ "key" => "r1", "status" => "running" }, response.parsed_body.fetch("task"))
    assert_equal "k1", response.parsed_body.fetch("summary_task_key")
  end

  # THE PREVIEW: the same door, rendered — the entries the seal would write, the storage line, the
  # thin evidence; `answering_user_public_id` resolved as the input door resolves it; a trial
  # `template` refused at its path; `render` a JSON boolean or nothing.
  test "the estimate rendered is the preview: entries, storage, blocks, the addressee, the trial template" do
    conversation = create_conversation!
    PromptDocuments::Write.call(anchor: { workspace: @workspace }, slot: "character", content: "The room.")
    post conversation_inputs_path(conversation), headers: auth("pv-1"), as: :json,
      params: { input: { text: "some context" } }
    perform_enqueued_jobs only: Conversations::Inputs::DrainJob

    post conversation_context_estimate_path(conversation), headers: auth, as: :json,
      params: { context_estimate: { prompt: "and so?", model: { model: "dev/mock-text" }, render: true } }
    assert_response :success
    estimate = response.parsed_body.fetch("context_estimate")
    assert_equal %w[input_tokens tokenizer_exact catalog_input_token_limit advisory_input_token_limit message_count
                    history mechanism entries storage blocks memory slots], estimate.keys
    assert_equal "default", estimate.fetch("mechanism")
    assert_equal %w[system user], estimate.fetch("entries").map { |entry| entry["role"] }
    assert_equal "The room.", estimate.dig("entries", 0, "parts", 0, "text")
    assert_equal %w[bytes bound within_bound], estimate.fetch("storage").keys, "within: no refusal member"
    assert_equal Nexus::SizeBounds.fetch(:snapshot_bound), estimate.dig("storage", "bound")
    assert_equal %w[block index type role state tokens allocated_tokens], estimate.fetch("blocks").first.keys
    assert_equal %w[slot:system_prompt slot:character slot:persona memory skills history lead tail input],
      estimate.fetch("blocks").map { |block| block["block"] }
    assert_equal({ "character" => 1 }, estimate.fetch("slots"))
    assert_equal({ "included" => 0, "omitted" => 0 }, estimate.fetch("memory"))

    post conversation_context_estimate_path(conversation), headers: auth, as: :json,
      params: { context_estimate: { prompt: "p", model: { model: "dev/mock-text" } } }
    assert_not response.parsed_body.fetch("context_estimate").key?("entries"), "unrendered: the count alone"

    post conversation_context_estimate_path(conversation), headers: auth, as: :json,
      params: { context_estimate: { prompt: "p", model: { model: "dev/mock-text" }, render: "true" } }
    assert_response :bad_request, "a string is not a request for the bytes"

    post conversation_context_estimate_path(conversation), headers: auth, as: :json,
      params: { context_estimate: { prompt: "p", model: { model: "dev/mock-text" },
                                    answering_user_public_id: "@nobody-here" } }
    assert_response :unprocessable_content
    assert_equal "principal_unknown", response.parsed_body.dig("error", "code")

    post conversation_context_estimate_path(conversation), headers: auth, as: :json,
      params: { context_estimate: { prompt: "p", model: { model: "dev/mock-text" }, render: true,
                                    template: { blocks: [{ type: "input" }, { type: "history" }] } } }
    assert_response :unprocessable_content
    assert_equal "prompt_template_invalid", response.parsed_body.dig("error", "code")
    assert_includes response.parsed_body.dig("error", "message"), "/blocks/1", "the refusal names its path"

    post conversation_context_estimate_path(conversation), headers: auth, as: :json,
      params: { context_estimate: { prompt: "p", model: { model: "dev/mock-text" }, variables: "scene" } }
    assert_response :bad_request, "variables is an object"
    assert_equal 0, ModelInvocation.count, "the preview wrote nothing"
  end
end
