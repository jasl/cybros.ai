require "test_helper"

class ConversationInputsTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper
  include RunLaneTestHelper

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @workspace = workspaces(:shared)
    @agent = connect_agent_session(steward: @human, agent_identifier: "continuation.console").access_token.user
    @agent.update!(default_model: "dev/mock-text")
    DevModelLane.ensure_enabled!(@account)
    @conversation = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: @agent)
    sign_in_as @human
  end

  test "Conversation navigation reaches an ordered bounded list of pending and blocked inputs" do
    first = accept_input(text: "First queued request")
    delayed = accept_input(text: "Delayed request", deliver_at: 1.day.from_now.change(usec: 0))
    blocked = accept_input(text: "Blocked request")
    blocked.update!(state: "blocked", blocked_reason: "provider_disabled")
    20.times { |i| accept_input(text: "Queue item #{i}") }
    kernel = kernel_input

    get conversation_path(@conversation)
    assert_response :success
    assert_select "a[href=?]", conversation_inputs_path(@conversation, return_to: conversation_path(@conversation))

    assert_no_difference ["Input.count", "Run.count", "ModelInvocation.count"] do
      assert_queries_match(/FROM "content_fragments"/, count: 1) do
        get conversation_inputs_path(@conversation), params: { limit: 1000 }
      end
    end
    assert_response :success
    ids = response.parsed_body.css("article[data-input-id]").map { |node| node["data-input-id"] }
    assert_equal 20, ids.size
    assert_equal [kernel, first, delayed, blocked].map(&:public_id), ids.first(4)
    assert_select "time[datetime=?]", delayed.deliver_at.iso8601
    assert_includes response.body, I18n.t("conversation_reading.refusals.provider_disabled")
    assert_includes response.body, @human.display_name
    assert_select "a[href=?]", conversation_input_path(@conversation, first.public_id, return_to: request.fullpath)

    get conversation_inputs_path(@conversation), params: { page: 2 }
    assert_response :success
    second_ids = response.parsed_body.css("article[data-input-id]").map { |node| node["data-input-id"] }
    assert_equal 4, second_ids.size
    assert_empty ids & second_ids
  end

  test "pending input navigation and cancellation preserve the original filtered conversation page" do
    input = accept_input(text: "Queued request")
    origin = workspace_conversations_path(@workspace, q: "review", order: "asc")
    conversation = conversation_path(@conversation, return_to: origin)
    get conversation
    assert_select "nav[aria-label=Back] a[href=?]", origin, text: "Back"
    pending = css_select("a").find { |link| link.text == "Pending inputs" }["href"]
    get pending
    assert_select "nav[aria-label=Back] a[href=?]", conversation
    observation = conversation_input_path(@conversation, input.public_id, return_to: request.fullpath)
    assert_select "a[href=?]", observation
    get observation
    assert_select "nav[aria-label=Back] a[href=?]", pending
    cancellation = conversation_input_cancellation_path(@conversation, input.public_id, return_to: pending)
    assert_select "form[action=?]", cancellation
    post cancellation
    assert_redirected_to pending
    follow_redirect!
    assert_select "article[data-input-id]", count: 0
    assert_select "nav[aria-label=Back] a[href=?]", conversation
    get conversation
    assert_select "nav[aria-label=Back] a[href=?]", origin
  end

  test "cancellation removes a structured pending input but never a kernel input" do
    input = accept_input(entries: [{ "role" => "user", "parts" => [{ "type" => "text", "text" => "Structured" }] }])
    assert_difference "Input.count", -1 do
      post conversation_input_cancellation_path(@conversation, input.public_id)
    end
    assert_redirected_to conversation_inputs_path(@conversation)
    kernel = kernel_input
    assert_no_difference "Input.count" do
      post conversation_input_cancellation_path(@conversation, kernel.public_id)
    end
    assert_response :not_found
  end

  test "cancel submitted after materialization follows the original input without stopping its run" do
    declare_tools!(@agent, tools: [Nexus::Tools::ASK], default_model: "dev/mock-text")
    input = accept_input
    get conversation_input_path(@conversation, input.public_id)
    assert_select "form[action=?]", conversation_input_cancellation_path(@conversation, input.public_id)
    Conversations::Inputs::ApplyNext.drain(conversation_id: @conversation.id)
    turn = @conversation.turns.sole
    original = turn.variants.sole
    run = original.run
    assert run
    before = run.attributes

    assert_no_difference ["Input.count", "Turn.count", "Variant.count", "Run.count"] do
      post conversation_input_cancellation_path(@conversation, input.public_id)
    end
    assert_redirected_to conversation_input_path(@conversation, input.public_id)
    assert_equal before, run.reload.attributes
    follow_redirect!
    assert_select "[data-variant-id=?]", original.public_id
    assert_includes response.body, I18n.t("conversation_inputs.already_materialized")
  end

  test "read only and concealed access apply to input pages and commands without an administrator bypass" do
    @conversation = Conversation.create!(workspace: @workspace, creating_user: users(:owner), answering_user: @agent)
    input = accept_input
    @conversation.update!(access_default: "read")
    get conversation_inputs_path(@conversation)
    assert_response :success
    get conversation_input_path(@conversation, input.public_id)
    assert_response :success
    assert_select "form[action=?]", conversation_input_cancellation_path(@conversation, input.public_id), count: 0
    post conversation_input_cancellation_path(@conversation, input.public_id)
    assert_response :forbidden

    @conversation.update!(access_default: "none")
    get conversation_inputs_path(@conversation)
    assert_response :not_found
    private_conversation = Conversation.create!(workspace: @workspace, creating_user: @human,
      answering_user: @agent, access_default: "none")
    private_input = accept_input(host: private_conversation)
    sign_out
    sign_in_as users(:owner)
    get conversation_inputs_path(private_conversation)
    assert_response :not_found
    post conversation_input_cancellation_path(private_conversation, private_input.public_id)
    assert_response :not_found
  end

  test "archive keeps pending reads while denying cancellation" do
    input = accept_input
    @conversation.update!(archived_at: Time.current)
    get conversation_inputs_path(@conversation)
    assert_response :success
    get conversation_input_path(@conversation, input.public_id)
    assert_response :success
    assert_select "form[action=?]", conversation_input_cancellation_path(@conversation, input.public_id), count: 0
    assert_no_difference "Input.count" do
      post conversation_input_cancellation_path(@conversation, input.public_id)
      assert_response :conflict
    end
    assert_equal "Original request", input.reload.text
  end

  private

    def accept_input(text: "Original request", **overrides)
      result = Conversations::Inputs::Create.call(Conversations::Inputs::Create::Command.new(**{
        host: @conversation, acting_user: @human, kind: "direct_reply", role: "user", entries: [{ "text" => text }],
        visible_in_context: nil, delivery_mode: "queue", context_mode: nil, context_options: nil,
        expected_context_revision: nil, expected_tail_turn_public_id: nil, provider_id: "dev", model_ref: "mock-text",
        reasoning_effort: nil, request_options: nil,
      }.merge(overrides)))
      assert_predicate result, :accepted?, result.inspect
      result.value
    end

    def kernel_input
      result = Conversations::Inputs::Create.call(Conversations::Inputs::Create::Command.kernel(
        host: @conversation, acting_user: @human, entries: [{ "text" => "Kernel result" }],
        origin: Input::TASK_RESULT_ORIGIN, sender_conversation_public_id: @conversation.public_id
      ))
      assert_predicate result, :accepted?
      result.value
    end
end
