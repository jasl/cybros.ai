require "test_helper"

class RunSteersTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(@account)
    @conversation = Conversation.create!(workspace: @workspace, creating_user: users(:owner))
    @seam = create_run_backed_turn(conversation: @conversation, acting_user: @human)
    @run = @seam.run
    sign_in_as @human
  end

  test "Run navigation reaches a bounded exact target list" do
    unguarded = accept_steer(expected_steering_run_public_id: nil)
    queued = accept_steer(delivery_mode: "queue", expected_steering_run_public_id: nil)
    inputs = 22.times.map { |i| accept_steer(text: "Correction #{i}") }
    get run_path(@run)
    assert_response :success
    assert_select "a[href=?]", run_steers_path(@run, return_to: workspace_runs_path(@workspace))

    assert_no_queries_match(/FOR (?:NO KEY )?UPDATE/i) do
      assert_no_difference ["Input.count", "Run.count", "ModelInvocation.count"] do
        assert_no_enqueued_jobs { get run_steers_path(@run), params: { limit: 1000 } }
      end
    end
    assert_response :success
    ids = response.parsed_body.css("article[data-input-id]").map { |node| node["data-input-id"] }
    assert_equal inputs.first(20).map(&:public_id), ids
    assert_not_includes ids, unguarded.public_id
    assert_not_includes ids, queued.public_id
    get run_steers_path(@run), params: { page: 2 }
    assert_response :success
    assert_equal inputs.last(2).map(&:public_id), response.parsed_body.css("article[data-input-id]").map { |node| node["data-input-id"] }
  end

  test "read access permits inspection but refuses cancellation including missing rows" do
    input = accept_steer
    @conversation.reload.update!(access_default: "read")
    [run_steers_path(@run), observation(input.public_id)].each do |path|
      get path
      assert_response :success
        assert_select "form[action=?]", run_steer_cancellation_path(@run, input.public_id), count: 0
    end
    [input.public_id, SecureRandom.uuid_v7].each do |id|
      post run_steer_cancellation_path(@run, id)
      assert_response :forbidden
    end
  end

  test "correction navigation and cancellation keep the filtered work list" do
    input = accept_steer
    origin = workspace_runs_path(@workspace, kind: "all", status: "running")
    corrections = run_steers_path(@run, return_to: origin)
    follow = run_steering_observation_path(@run, input_public_id: input.public_id, return_to: origin)
    cancel = run_steer_cancellation_path(@run, input.public_id, return_to: origin)
    get run_path(@run, return_to: origin)
    assert_select "a[href=?]", corrections
    get corrections
    assert_select "a[href=?]", follow
    get follow
    assert_select "a[href=?]", origin
    assert_select "a[href=?]", corrections
    assert_select "form[action=?]", cancel
    2.times do
      post cancel
      assert_redirected_to follow
      follow_redirect!
      assert_select "a[href=?]", origin
      assert_select "a[href=?]", corrections
    end
  end

  test "workspace archival denies writes and concealed content has no administrator bypass" do
    input = accept_steer
    @workspace.update!(state: "archived", archived_at: Time.current)
    post run_steer_cancellation_path(@run, input.public_id)
    assert_response :forbidden
    @workspace.update!(state: "active", archived_at: nil)
    @conversation.reload.update!(access_default: "none")
    get observation(input.public_id)
    assert_response :not_found
    private_conversation = Conversation.create!(workspace: @workspace, creating_user: @human, access_default: "none")
    private_run = create_run_backed_turn(conversation: private_conversation, acting_user: @human).run
    sign_out
    sign_in_as users(:owner)
    get run_steers_path(private_run)
    assert_response :not_found
  end

  test "different targets and ordinary inputs stay absent from observation and mutation routes" do
    guarded = accept_steer
    unguarded = accept_steer(expected_steering_run_public_id: nil)
    @seam.variant.update!(status: "completed")
    variant = @seam.turn.variants.create!(account: @account, position: 1,
      status: "running", source: "run", origin_variant: @seam.variant)
    other = Run.create!(workspace: @workspace, creating_user: @human,
      status: "running", variant: variant, approval_mode: "bypass")
    [[@run, unguarded], [other, guarded]].each do |run, input|
      get run_steering_observation_path(run, input_public_id: input.public_id)
      assert_response :not_found
      post run_steer_cancellation_path(run, input.public_id)
      assert_response :not_found
      assert Input.exists?(input.id)
    end
  end

  test "consumption before a redirect or mutation is observed without a winning command notice" do
    input = accept_steer
    consume
    assert_not Input.exists?(input.id)
    [run_steer_cancellation_path(@run, input.public_id)].each do |path|
      post path, params: { input: { lock_version: input.lock_version } }
      assert_redirected_to observation(input.public_id)
      assert_nil flash[:notice]
      follow_redirect!
      assert_response :success
      assert_includes response.body, I18n.t("run_steering.states.consumed")
      assert_select "a[href^=?]", run_task_path(@run, "consume")
      assert_select "form[action=?]", path, count: 0
    end
  end

  test "cancellation records its target and unknown evidence does not claim consumption" do
    input = accept_steer
    post run_steer_cancellation_path(@run, input.public_id)
    assert_redirected_to observation(input.public_id)
    follow_redirect!
    assert_response :success
    assert_includes response.body, I18n.t("run_steering.states.canceled")
    event = @conversation.event_items.find_by!(item_type: "input_deleted")
    assert_equal @run.public_id, event.payload.fetch("expected_steering_run_public_id")
    get observation(SecureRandom.uuid_v7)
    assert_response :success
    assert_includes response.body, I18n.t("run_steering.states.unknown")
    assert_select "a[href^=?]", run_tasks_path(@run), count: 1 # Run header only.
  end

  test "hidden original candidates do not receive a direct navigation bypass" do
    input = accept_steer
    get observation(input.public_id)
    assert_response :success
    candidate_path = conversation_turn_variant_path(@conversation, @seam.turn.public_id, @seam.variant.public_id)
    assert_select "a[href^=?]", candidate_path
    @seam.turn.update!(visibility: "hidden")
    get observation(input.public_id)
    assert_response :success
    assert_select "a[href^=?]", candidate_path, count: 0
  end

  test "standalone and Side Runs reject all correction routes even when details are pruned" do
    standalone = Run.create!(workspace: @workspace, creating_user: @human, status: "running", approval_mode: "bypass")
    side = Conversation.create!(workspace: @workspace, creating_user: @human, side: true)
    side_run = create_run_backed_turn(conversation: side, acting_user: @human).run
    [standalone, side_run].each do |run|
      [nil, Time.current].each do |pruned_at|
        run.update!(details_pruned_at: pruned_at)
        [run_steers_path(run),
          run_steering_observation_path(run, input_public_id: SecureRandom.uuid_v7)].each do |path|
          get path
          assert_response :not_found
        end
        post run_steer_cancellation_path(run, SecureRandom.uuid_v7)
        assert_response :not_found
      end
    end
  end

  test "Session and CSRF are required for every correction mutation" do
    input = accept_steer
    previous = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
    # Nexus uses Rails' Fetch Metadata strategy. Missing provenance on HTTPS
    # and an explicitly cross-site browser request both fail that existing door.
    https!
    paths = [run_steer_cancellation_path(@run, input.public_id)]
    paths.each do |path|
      [{}, { "Sec-Fetch-Site" => "cross-site" }].each do |headers|
        assert_no_difference ["Input.count", "ConversationCommandReceipt.count"] do
          post path, headers: headers
        end
        assert_response :unprocessable_entity
      end
    end
    ActionController::Base.allow_forgery_protection = previous
    sign_out
    get run_steers_path(@run)
    assert_redirected_to new_session_path(return_to: run_steers_path(@run))
  ensure
    ActionController::Base.allow_forgery_protection = previous
  end

  private

    def observation(public_id)
      run_steering_observation_path(@run, input_public_id: public_id)
    end

    def accept_steer(text: "Correct this execution", **overrides)
      result = Conversations::Inputs::Create.call(Conversations::Inputs::Create::Command.new(**{
        host: @conversation, acting_user: @human, kind: "direct_reply", role: "user", entries: [{ "text" => text }],
        visible_in_context: nil, delivery_mode: "steer", context_mode: nil, context_options: nil,
        expected_context_revision: nil, expected_tail_turn_public_id: nil,
        expected_steering_run_public_id: @run.public_id, provider_id: nil, model_ref: nil,
        reasoning_effort: nil, request_options: nil,
      }.merge(overrides)))
      assert_predicate result, :accepted?, result.inspect
      result.value
    end

    def consume
      result = Runs::Tasks::Append.call(Runs::Tasks::Append::Command.authored(
        run: @run, steps: [model("consume", "prompt" => "Original request")]
      ))
      assert_predicate result, :applied?
      Runs::ScheduleReady.call(run_id: @run.id)
    end
end
