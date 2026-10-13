require "test_helper"
require_relative "../../../test_helpers/conversation_api_test_helper"

class AgentAPI::V1::ConversationReasoningTest < ActionDispatch::IntegrationTest
  include ConversationAPITestHelper
  include InvocationHarness

  test "a completed direct reply retains display text without its encrypted replay material" do
    conversation = create_conversation!
    post conversation_inputs_path(conversation), headers: auth("reasoning-direct"), as: :json,
      params: { input: { kind: "direct_reply", text: "Explain", model: { model: "dev/mock-text" } } }
    assert_response :accepted
    perform_enqueued_jobs only: Conversations::Inputs::DrainJob
    turn = conversation.conversation_turns.sole
    variant = turn.active_variant
    attempt = ModelInvocations::AdmitQueuedWork.call.admitted.sole.attempt
    apply_via(attempt, sse_success("Answer", reasoning: "Display this reasoning.", reasoning_encrypted: "opaque-native"))
    Conversations::Turns::Converge.call
    assert_equal "completed", turn.reload.status

    get reasoning_path(conversation, turn, variant), headers: auth

    assert_response :success
    item = response.parsed_body.fetch("items").sole
    assert_equal true, item.fetch("available")
    assert_equal "Display this reasoning.", item.fetch("text")
    assert_equal({ "provider_id" => "dev", "model_ref" => "mock-text", "reasoning_effort" => "medium", "reasoning_enabled" => true }, item.fetch("model"))
    assert_not item.key?("task_key")
    assert_not_includes response.body, "opaque-native"
    assert_equal({ "next_before" => nil, "has_older" => false }, response.parsed_body.fetch("pagination"))
  end

  test "loop reasoning pages visible selected rounds in creation order with their producing models" do
    conversation, seam = reasoning_loop
    first = reasoning_round(seam.agent_run, "r1", text: "First.")
    reasoning_round(seam.agent_run, "r1t0-child", text: "Branch.", model_ref: "branch-model")
    reasoning_round(seam.agent_run, "r2", text: nil)
    reasoning_round(seam.agent_run, "internal", text: "Hidden.", visibility: "hidden")
    seam.agent_run.agent_run_tasks.create!(node_key: "unstarted", type: AgentRunTasks::ModelTask.sti_name,
      provider_id: "dev", model_ref: "mock-text", authored_by: "author")

    get reasoning_path(conversation, seam.turn, seam.variant), headers: auth, params: { limit: 2 }

    assert_response :success
    items = response.parsed_body.fetch("items")
    assert_equal %w[r1t0-child r2], items.pluck("task_key")
    assert_equal "Branch.", items.first.fetch("text")
    assert_equal "branch-model", items.first.dig("model", "model_ref")
    assert_equal false, items.last.fetch("available")
    assert_not items.last.key?("text")
    cursor = response.parsed_body.dig("pagination", "next_before")
    assert_predicate cursor, :present?
    assert_not_equal first.id.to_s, cursor
    assert_equal true, response.parsed_body.dig("pagination", "has_older")

    get reasoning_path(conversation, seam.turn, seam.variant), headers: auth, params: { before: cursor, limit: 2 }

    assert_response :success
    assert_equal ["r1"], response.parsed_body.fetch("items").pluck("task_key")
    assert_equal false, response.parsed_body.dig("pagination", "has_older")
    assert_nil response.parsed_body.dig("pagination", "next_before")
  end

  test "reasoning reads have a fixed query count and take no row locks across a wider page" do
    conversation, seam = reasoning_loop
    25.times { |index| reasoning_round(seam.agent_run, "r#{index}", text: "Reason #{index}.") }
    path = reasoning_path(conversation, seam.turn, seam.variant)
    get path, headers: auth, params: { limit: 2 }
    narrow = sql_count { get path, headers: auth, params: { limit: 2 } }
    statements = []
    capture = ->(*, payload) { statements << payload[:sql] }
    wide = ActiveSupport::Notifications.subscribed(capture, "sql.active_record") do
      sql_count { get path, headers: auth, params: { limit: 25 } }
    end

    assert_response :success
    assert_equal 25, response.parsed_body.fetch("items").length
    assert_equal narrow, wide
    assert_empty statements.grep(/FOR (UPDATE|SHARE|NO KEY UPDATE|KEY SHARE)/i)
  end

  test "the page cap and empty window are independent of total loop size" do
    conversation, seam = reasoning_loop
    get reasoning_path(conversation, seam.turn, seam.variant), headers: auth
    assert_response :success
    assert_empty response.parsed_body.fetch("items")

    101.times { |index| reasoning_round(seam.agent_run, "r#{index}", text: nil) }
    get reasoning_path(conversation, seam.turn, seam.variant), headers: auth, params: { limit: 100 }
    assert_response :success
    assert_equal 100, response.parsed_body.fetch("items").length
    assert_equal true, response.parsed_body.dig("pagination", "has_older")
    get reasoning_path(conversation, seam.turn, seam.variant), headers: auth, params: { limit: 101 }
    assert_response :bad_request
    assert_equal "parameter_invalid", response.parsed_body.dig("error", "code")
    get reasoning_path(conversation, seam.turn, seam.variant), headers: auth, params: { before: "not-a-cursor" }
    assert_response :bad_request
    assert_equal "parameter_invalid", response.parsed_body.dig("error", "code")
  end

  test "read standing permits reasoning and none or an executor bearer cannot read it" do
    conversation, seam = reasoning_loop
    reasoning_round(seam.agent_run, "r1", text: "Retained reasoning.")
    other = create_access_token_fixture(user: users(:curator), name: "Reader")
    headers = { "Authorization" => "Bearer #{other.secret}" }
    conversation.update!(access_default: "read")
    path = reasoning_path(conversation, seam.turn, seam.variant)

    get path, headers: headers
    assert_response :success
    assert_equal "Retained reasoning.", response.parsed_body.fetch("items").sole.fetch("text")
    conversation.update!(access_default: "none")
    get path, headers: headers
    assert_response :not_found
    get path, headers: { "Authorization" => "Bearer #{suite_runner_connection.executor_access_secret}" }
    assert_response :unauthorized
  end

  test "turn and variant scope conceal unrelated or concealed content while hidden turns remain readable" do
    conversation, seam = reasoning_loop
    reasoning_round(seam.agent_run, "r1", text: "Retained reasoning.")
    other = create_conversation!
    get reasoning_path(other, seam.turn, seam.variant), headers: auth
    assert_response :not_found
    get reasoning_path(conversation, seam.turn, Data.define(:public_id).new(SecureRandom.uuid_v7)), headers: auth
    assert_response :not_found

    seam.turn.update!(visibility: "hidden")
    get reasoning_path(conversation, seam.turn, seam.variant), headers: auth
    assert_response :success
    # Read fixtures model completed history; changing visibility does not
    # grant access to a candidate that the deck has concealed.
    seam.turn.update_columns(active_variant_id: nil)
    seam.variant.update_columns(status: "completed", deleted_at: Time.current)
    get reasoning_path(conversation, seam.turn, seam.variant), headers: auth
    assert_response :not_found
    seam.variant.update_columns(deleted_at: nil)
    seam.turn.update_columns(deleted_at: Time.current)
    get reasoning_path(conversation, seam.turn, seam.variant), headers: auth
    assert_response :not_found
  end

  test "fork reasoning reads its inherited candidate and obeys the fork concealment override" do
    conversation, seam = reasoning_loop
    reasoning_round(seam.agent_run, "r1", text: "Inherited reasoning.")
    AgentRuns::Transition.agent_run(seam.agent_run, status: "completed", completed_at: Time.current)
    Conversations::Turns::Converge.call
    post conversation_inputs_path(conversation), headers: auth("fork-boundary"), as: :json,
      params: { input: { text: "Boundary" } }
    perform_enqueued_jobs only: Conversations::Inputs::DrainJob
    boundary = conversation.conversation_turns.order(:position).last
    post conversation_forks_path(conversation), headers: auth("reasoning-fork"), as: :json,
      params: { fork: { turn_public_id: boundary.public_id } }
    assert_response :created
    fork = Conversation.find_by!(public_id: response.parsed_body.dig("conversation", "public_id"))

    get reasoning_path(fork, seam.turn, seam.variant), headers: auth
    assert_response :success
    assert_equal "Inherited reasoning.", response.parsed_body.fetch("items").sole.fetch("text")
    patch "#{conversation_turns_path(fork)}/#{seam.turn.public_id}", headers: auth, as: :json,
      params: { turn: { concealed: true } }
    assert_response :success
    get reasoning_path(fork, seam.turn, seam.variant), headers: auth
    assert_response :not_found
    get reasoning_path(conversation, seam.turn, seam.variant), headers: auth
    assert_response :success
    patch "#{conversation_turns_path(fork)}/#{seam.turn.public_id}", headers: auth, as: :json,
      params: { turn: { concealed: false } }
    assert_response :success

    patch "#{conversation_turns_path(conversation)}/#{seam.turn.public_id}", headers: auth, as: :json,
      params: { turn: { concealed: true } }
    assert_response :success
    get reasoning_path(fork, seam.turn, seam.variant), headers: auth
    assert_response :success
    assert_equal "Inherited reasoning.", response.parsed_body.fetch("items").sole.fetch("text")
    get reasoning_path(conversation, seam.turn, seam.variant), headers: auth
    assert_response :not_found
  end

  test "pruned reasoning returns gone rather than claiming the provider supplied no text" do
    conversation, seam = reasoning_loop
    reasoning_round(seam.agent_run, "r1", text: "Retained reasoning.")
    seam.agent_run.update_columns(details_pruned_at: Time.current)
    get reasoning_path(conversation, seam.turn, seam.variant), headers: auth
    assert_response :gone
    assert_equal "execution_details_pruned", response.parsed_body.dig("error", "code")
    seam.agent_run.update_columns(details_pruned_at: nil)
    seam.variant.update_columns(details_pruned_at: Time.current)
    get reasoning_path(conversation, seam.turn, seam.variant), headers: auth
    assert_response :gone
  end

  test "a manual candidate has an empty reasoning window" do
    conversation = create_conversation!
    post conversation_inputs_path(conversation), headers: auth("manual-reasoning"), as: :json,
      params: { input: { text: "A person's own words." } }
    assert_response :accepted
    perform_enqueued_jobs only: Conversations::Inputs::DrainJob
    turn = conversation.conversation_turns.sole

    get reasoning_path(conversation, turn, turn.active_variant), headers: auth

    assert_response :success
    assert_empty response.parsed_body.fetch("items")
    assert_equal({ "next_before" => nil, "has_older" => false }, response.parsed_body.fetch("pagination"))
  end

  private

    def reasoning_loop
      conversation = create_conversation!
      [conversation, create_run_backed_turn(conversation: conversation, acting_user: @human)]
    end

    def reasoning_round(agent_run, key, text:, model_ref: "mock-text", visibility: "visible")
      invocation = agent_run.model_invocations.create!(
        creating_user: @human, provider_id: "dev", model_ref: model_ref,
        internal_creation_key: SecureRandom.uuid_v7, admission_deadline_seconds: 120,
        status: "completed", terminal_at: Time.current
      )
      if text
        ContentBodies::Replace.call(owner: invocation, role: "reasoning",
          entries: Nexus::InputEntries.for(text), seal: true)
      end
      ContentBodies::Replace.call(owner: invocation, role: "reasoning_trace",
        entries: [{ "encrypted_content" => "never-display-native" }], seal: true)
      agent_run.agent_run_tasks.create!(node_key: key, type: AgentRunTasks::ModelTask.sti_name,
        provider_id: "dev", model_ref: model_ref, authored_by: "author",
        selected_model_invocation: invocation, transcript_visibility: visibility)
    end

    def reasoning_path(conversation, turn, variant)
      "#{conversation_turns_path(conversation)}/#{turn.public_id}/variants/#{variant.public_id}/reasoning"
    end
end
