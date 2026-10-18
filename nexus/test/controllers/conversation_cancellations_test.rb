require "test_helper"
require_relative "../test_helpers/schedules_console_test_helper"

class ConversationCancellationsTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper
  include InvocationHarness
  include RunLaneTestHelper
  include SchedulesConsoleTestHelper

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(@account)
    @conversation = Conversation.create!(workspace: @workspace, creating_user: users(:curator),
      answering_user: users(:agent), title: "Conversation to stop")
    sign_in_as @human
  end

  test "the confirmation is read only and preserves the exact reader and filtered list path" do
    seam = create_run_backed_turn(conversation: @conversation, acting_user: @human)
    list_path = workspace_conversations_path(@workspace, archived: "include", query: "stop")
    reader_path = conversation_path(@conversation, around_turn_public_id: seam.turn.public_id, return_to: list_path)

    get reader_path
    assert_response :success
    assert_select "a[href=?]", new_conversation_cancellation_path(@conversation, return_to: reader_path),
      text: I18n.t("conversation_cancellation.title")
    assert_no_changes -> { [@conversation.reload.attributes, seam.run.reload.attributes] } do
      assert_no_difference ["Input.count", "Turn.count", "Variant.count", "ModelInvocation.count", "Event.count", "EventItem.count"] do
        assert_no_enqueued_jobs do
          get new_conversation_cancellation_path(@conversation), params: { return_to: reader_path }
        end
      end
    end
    assert_response :success
    assert_select "h1", text: I18n.t("conversation_cancellation.title")
    assert_equal "same-origin", response.headers["Referrer-Policy"]
    assert_includes response.headers["Cache-Control"], "no-store"
    assert_select "meta[name='turbo-visit-control'][content='reload']"
    assert_select "form[action=?][method='post']", conversation_cancellation_path(@conversation)
    assert_select "input[name='return_to'][value=?]", reader_path
    assert_back_link reader_path
    %w[scope queued preserved follow].each do |key|
      assert_includes response.body, I18n.t("conversation_cancellation.#{key}")
    end

    post conversation_cancellation_path(@conversation), params: { return_to: reader_path }
    assert_response :see_other
    assert_redirected_to reader_path
    assert_equal I18n.t("conversation_cancellation.accepted"), flash[:notice]
    assert_equal "canceling", seam.run.reload.status
    follow_redirect!
    assert_back_link list_path
    assert_select "a[href=?]", run_path(seam.run, return_to: reader_path)
  end

  test "a direct reply without a Run stops its original invocation and shows the canceled candidate" do
    turn = direct_reply
    candidate = turn.active_variant
    invocation = candidate.model_invocation
    assert_nil candidate.run
    assert_equal "running", turn.status

    assert_no_difference ["Turn.count", "Variant.count", "Run.count", "ModelInvocation.count"] do
      post conversation_cancellation_path(@conversation)
    end
    assert_response :see_other
    assert_redirected_to conversation_path(@conversation)
    assert_equal I18n.t("conversation_cancellation.accepted"), flash[:notice]
    assert_equal "canceled", invocation.reload.status
    assert_equal "creator_requested", invocation.failure_reason_key

    Conversations::Turns::Converge.call
    assert_equal "canceled", turn.reload.status
    assert_equal "canceled", candidate.reload.status
    assert_equal candidate.id, turn.active_variant_id
    assert_nil @conversation.reload.active_turn_id
    get conversation_turn_variant_path(@conversation, turn.public_id, candidate.public_id)
    assert_response :success
    assert_select "[data-variant-id=?] .badge", candidate.public_id,
      text: I18n.t("conversation_console.variant_status.canceled")
  end

  test "stopping a regeneration preserves the already published candidate" do
    turn = direct_reply
    original = turn.active_variant
    complete_reply(original, "Keep the original answer")
    result = Conversations::Turns::Regenerate.call(Conversations::Turns::Regenerate::Command.new(
      conversation: @conversation.reload, turn_public_id: turn.public_id, acting_user: @human,
      provider_id: nil, model_ref: nil, reasoning_effort: nil, request_options: nil))
    assert_predicate result, :accepted?
    candidate = turn.variants.order(:position).last
    assert_not_equal original.id, candidate.id

    post conversation_cancellation_path(@conversation)
    assert_response :see_other
    Conversations::Turns::Converge.call
    assert_equal "canceled", candidate.reload.status
    assert_equal original.id, turn.reload.active_variant_id
    assert_equal "completed", original.reload.status
    get conversation_path(@conversation)
    assert_response :success
    assert_includes response.body, "Keep the original answer"
  end

  test "a completed source is cut once without changing its published answer or terminal state" do
    seam = retained_reply(run_status: "completed")
    seam.variant.update!(details_pruned_at: Time.current)
    seam.run.update!(details_pruned_at: Time.current)
    original = [seam.turn.reload.attributes, seam.variant.reload.attributes, seam.run.completed_at]
    assert_nil @conversation.reload.active_turn_id
    get conversation_path(@conversation)
    assert_response :success
    assert_select "a[href^=?]", new_conversation_cancellation_path(@conversation)

    post conversation_cancellation_path(@conversation)
    assert_response :see_other
    cut = seam.run.reload.stopped_at
    assert cut
    assert_equal "completed", seam.run.status
    assert_equal original, [seam.turn.reload.attributes, seam.variant.reload.attributes, seam.run.completed_at]
    follow_redirect!
    assert_includes response.body, "An already published answer"

    assert_no_difference ["Turn.count", "Variant.count", "Run.count", "ModelInvocation.count", "Event.count", "EventItem.count"] do
      assert_no_enqueued_jobs { post conversation_cancellation_path(@conversation) }
    end
    assert_response :conflict
    assert_includes response.body, I18n.t("conversation_cancellation.not_running")
    assert_back_link conversation_path(@conversation)
    assert_equal cut, seam.run.reload.stopped_at
    assert_equal "completed", seam.run.status
  end

  test "stopping historical background and current work preserves queued input and Schedule" do
    older = retained_reply(run_status: "running")
    background = older.run.tasks.create!(node_key: "background", type: Tasks::AwaitTask,
      authored_by: "author", detached: true, lifetime: "conversation")
    background.update!(status: "awaiting_input", started_at: Time.current, await_started_at: Time.current)
    current = create_run_backed_turn(conversation: @conversation.reload, acting_user: @human)
    queued = post_input!(@conversation.reload, acting_user: @human, text: "Continue this queued request",
      kind: "direct_reply", provider_id: "dev", model_ref: "mock-text")
    schedule = console_schedule
    queue_snapshot = queued.attributes
    schedule_snapshot = schedule.attributes

    post conversation_cancellation_path(@conversation)
    assert_response :see_other
    assert_predicate older.run.reload, :stopped?
    assert_predicate current.run.reload, :stopped?
    assert_equal queue_snapshot, queued.reload.attributes
    assert_equal schedule_snapshot, schedule.reload.attributes
    Runs::ScheduleSweep.call
    Conversations::Turns::Converge.call
    assert_equal "canceled", background.reload.status
    assert_equal "canceled", current.turn.reload.status
    assert_equal "completed", older.turn.reload.status
    assert_equal "completed", older.variant.reload.status

    Conversations::Inputs::ApplyNext.drain(conversation_id: @conversation.id)
    next_turn = @conversation.turns.find_by!(input_public_id: queued.public_id)
    next_candidate = next_turn.active_variant
    assert_equal "running", next_turn.status
    assert_not_equal current.turn.id, next_turn.id
    complete_reply(next_candidate, "The queued request completed")
    assert_equal "completed", next_turn.reload.status
    assert_equal schedule_snapshot, schedule.reload.attributes
    get conversation_turn_variant_path(@conversation, next_turn.public_id, next_candidate.public_id)
    assert_response :success
    assert_includes response.body, "The queued request completed"
  end

  test "an attention held Run remains stoppable without an active Turn" do
    seam = create_run_backed_turn(conversation: @conversation, acting_user: @human)
    Runs::Transition.run(seam.run, status: "needs_attention", attention_reason: "halt_failure")
    Conversations::Turns::Converge.call
    assert_nil @conversation.reload.active_turn_id
    assert_equal "failed", seam.turn.reload.status

    post conversation_cancellation_path(@conversation)
    assert_response :see_other
    assert_equal "canceling", seam.run.reload.status
    Runs::EvaluateQuiescence.call(seam.run)
    Conversations::Turns::Converge.call
    assert_equal "canceled", seam.run.reload.status
    assert_equal "canceled", seam.variant.reload.status
  end

  test "an archived Conversation and writable child or Side retain the ordinary stop door" do
    child = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: users(:agent),
      parent_conversation: @conversation, parent_conversation_public_id: @conversation.public_id)
    side = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: users(:agent), side: true)
    @conversation.update!(archived_at: Time.current)
    [@conversation, child, side].each do |conversation|
      seam = create_run_backed_turn(conversation: conversation, acting_user: @human)
      get new_conversation_cancellation_path(conversation)
      assert_response :success
      post conversation_cancellation_path(conversation)
      assert_response :see_other
      assert_equal "canceling", seam.run.reload.status
    end
    assert_predicate @conversation.reload, :archived?
  end

  test "read standing hides the entry and a formerly authorized confirmation cannot stop work" do
    seam = create_run_backed_turn(conversation: @conversation, acting_user: @human)
    get new_conversation_cancellation_path(@conversation)
    assert_response :success
    @conversation.update!(access_default: "read")
    get conversation_path(@conversation)
    assert_response :success
    assert_select "a[href^=?]", new_conversation_cancellation_path(@conversation), count: 0
    assert_cancellation_refused(@conversation, :forbidden)
    assert_nil seam.run.reload.stopped_at

    @conversation.update!(access_default: "none")
    assert_cancellation_refused(@conversation, :not_found)
    assert_nil seam.run.reload.stopped_at
  end

  test "Account owner Workspace owner and Agent steward have no content bypass" do
    seam = create_run_backed_turn(conversation: @conversation, acting_user: @human)
    sign_out
    sign_in_as users(:owner)
    @conversation.update!(access_default: "read")
    assert_cancellation_refused(@conversation, :forbidden)
    @conversation.update!(access_default: "none")
    assert_cancellation_refused(@conversation, :not_found)
    assert_nil seam.run.reload.stopped_at
  end

  test "private Workspace tombstone and unknown identifiers conceal both cancellation doors" do
    private_conversation = Conversation.create!(workspace: workspaces(:personal), creating_user: users(:curator),
      answering_user: users(:agent))
    @conversation.update!(tombstoned_at: Time.current)
    [private_conversation, @conversation, SecureRandom.uuid_v7].each do |conversation|
      assert_cancellation_refused(conversation, :not_found)
    end
  end

  test "Workspace archive refuses Stop while restoring follows the existing write predicate" do
    seam = create_run_backed_turn(conversation: @conversation, acting_user: @human)
    @workspace.update!(state: "archived", archived_at: Time.current)
    assert_cancellation_refused(@conversation, :forbidden)
    assert_nil seam.run.reload.stopped_at
    @workspace.update!(state: "restoring")
    post conversation_cancellation_path(@conversation)
    assert_response :see_other
    assert_predicate seam.run.reload, :stopped?
  end

  test "an empty conversation returns conflict and external return locations stay local" do
    ["https://elsewhere.invalid/", "//elsewhere.invalid/"].each do |return_to|
      get new_conversation_cancellation_path(@conversation), params: { return_to: return_to }
      assert_response :success
      assert_back_link conversation_path(@conversation)
      assert_select "input[name='return_to'][value=?]", conversation_path(@conversation)
      post conversation_cancellation_path(@conversation), params: { return_to: return_to }
      assert_response :conflict
      assert_includes response.body, I18n.t("conversation_cancellation.not_running")
      assert_equal "same-origin", response.headers["Referrer-Policy"]
    end
    create_run_backed_turn(conversation: @conversation, acting_user: @human)
    post conversation_cancellation_path(@conversation), params: { return_to: "https://elsewhere.invalid/" }
    assert_redirected_to conversation_path(@conversation)
  end

  test "sign in resumes a readable page without replaying Stop" do
    seam = create_run_backed_turn(conversation: @conversation, acting_user: @human)
    sign_out
    confirmation_path = new_conversation_cancellation_path(@conversation)
    get confirmation_path
    assert_redirected_to new_session_path(return_to: confirmation_path)
    post conversation_cancellation_path(@conversation), params: { return_to: conversation_path(@conversation) }
    assert_redirected_to new_session_path(return_to: conversation_path(@conversation))
    assert_nil seam.run.reload.stopped_at
  end

  test "CSRF rejects missing HTTPS provenance and cross-site Stop without changing work or queue" do
    seam = create_run_backed_turn(conversation: @conversation, acting_user: @human)
    queued = post_input!(@conversation.reload, acting_user: @human, text: "Keep this input")
    previous = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
    https!

    [{}, { "Sec-Fetch-Site" => "cross-site" }].each do |headers|
      assert_no_changes -> { [seam.run.reload.attributes, queued.reload.attributes, @conversation.reload.attributes] } do
        assert_no_difference ["Event.count", "EventItem.count", "Turn.count", "Variant.count", "ModelInvocation.count"] do
          assert_no_enqueued_jobs { post conversation_cancellation_path(@conversation), headers: headers }
        end
      end
      assert_response :unprocessable_entity
    end

    get new_conversation_cancellation_path(@conversation)
    assert_response :success
    token = response.parsed_body.at_css("meta[name='csrf-token']")["content"]
    post conversation_cancellation_path(@conversation),
      params: { authenticity_token: token }, headers: { "Sec-Fetch-Site" => "same-origin" }
    assert_response :see_other
    assert_predicate seam.run.reload, :stopped?
    assert Input.exists?(queued.id)
  ensure
    ActionController::Base.allow_forgery_protection = previous
  end

  private

    def direct_reply
      input = post_input!(@conversation.reload, acting_user: @human, text: "Please answer",
        kind: "direct_reply", provider_id: "dev", model_ref: "mock-text")
      Conversations::Inputs::ApplyNext.drain(conversation_id: @conversation.id)
      @conversation.turns.find_by!(input_public_id: input.public_id)
    end

    def complete_reply(candidate, text)
      admitted = ModelInvocations::AdmitQueuedWork.call.admitted.find do |work|
        work.attempt.model_invocation_id == candidate.model_invocation_id
      end
      assert admitted, "the exact reply's invocation must be admitted"
      apply_via(admitted.attempt, sse_success(text))
      Conversations::Turns::Converge.call
      assert_equal "completed", candidate.reload.status
    end

    def retained_reply(run_status:)
      seam = create_run_backed_turn(conversation: @conversation, acting_user: @human,
        turn_status: "completed", variant_status: "completed", run_status: run_status)
      seam.run.update!(delivered_at: Time.current, completed_at: (Time.current if run_status == "completed"))
      ContentBodies::Replace.call(owner: seam.variant, role: "content",
        entries: [{ "text" => "An already published answer" }], seal: true)
      @conversation.update!(active_turn: nil)
      seam
    end

    def assert_cancellation_refused(conversation, status)
      assert_no_difference ["Input.count", "Turn.count", "Variant.count", "Run.count", "ModelInvocation.count", "Event.count", "EventItem.count"] do
        assert_no_enqueued_jobs do
          get new_conversation_cancellation_path(conversation)
          assert_response status
          post conversation_cancellation_path(conversation)
          assert_response status
        end
      end
    end

    def assert_back_link(path)
      assert_select "nav[aria-label=?] a[href=?]", I18n.t("shared.back_navigation.back"), path
    end
end
