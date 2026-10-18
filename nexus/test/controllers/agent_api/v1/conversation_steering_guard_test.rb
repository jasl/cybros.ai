require "test_helper"
require_relative "../../../test_helpers/conversation_api_test_helper"

class AgentAPI::V1::ConversationSteeringGuardTest < ActionDispatch::IntegrationTest
  include ConversationAPITestHelper

  setup do
    @conversation = create_conversation!
    @seam = create_run_backed_turn(conversation: @conversation, acting_user: @human)
  end

  def steer(target: @seam.run.public_id, mode: "steer", key: SecureRandom.uuid, **fields)
    post inputs_path(@conversation), headers: auth(key), as: :json,
      params: { input: { text: "only this execution", delivery_mode: mode,
        expected_steering_run_public_id: target, **fields } }
  end

  test "the selected loop accepts a guarded steer and exact replay survives its cancellation" do
    steer(target: @seam.run.public_id.upcase, key: "guarded")
    assert_response :accepted
    accepted = response.parsed_body.fetch("input")
    assert_equal "steering", accepted.fetch("state")
    assert_equal @seam.run.public_id, accepted.fetch("expected_steering_run_public_id")
    input = Input.find_by!(public_id: accepted.fetch("public_id"))
    assert_equal [input.id], @seam.run.steering_inputs.pluck(:id)
    accepted_event = @conversation.event_items.where(item_type: "input_accepted").sole
    assert_equal @seam.run.public_id, accepted_event.payload.fetch("expected_steering_run_public_id")
    assert_not accepted_event.payload.key?("run_public_id"), "the target does not replace the sender identity"

    @seam.run.with_lock do
      Runs::Transition.run(@seam.run, status: "canceled", completed_at: Time.current)
    end
    assert_not Input.exists?(input.id), "a guarded steer never becomes the next turn"
    deleted = @conversation.event_items.where(item_type: "input_deleted").sole
    assert_equal true, deleted.payload.fetch("steer_canceled")
    assert_equal input.public_id, deleted.payload.fetch("input_public_id")
    assert_equal @seam.run.public_id, deleted.payload.fetch("expected_steering_run_public_id")

    get events_path(@conversation), headers: auth
    assert_response :success
    targets = response.parsed_body.fetch("events")
      .select { |event| %w[input_accepted input_deleted].include?(event.fetch("type")) }
      .map { |event| event.fetch("payload").fetch("expected_steering_run_public_id") }
    assert_equal [@seam.run.public_id, @seam.run.public_id], targets

    steer(key: "guarded")
    assert_response :accepted
    assert_equal "true", response.headers["Idempotency-Replayed"]
    assert_equal accepted, response.parsed_body.fetch("input")
    assert_not Input.exists?(input.id), "replay returns acceptance without recreating the input"

    steer(target: SecureRandom.uuid_v7, key: "guarded")
    assert_response :conflict
    assert_equal "idempotency_envelope_mismatch", response.parsed_body.dig("error", "code")
  end

  test "public HTTP events retain guarded target identity and omit it for an ordinary steer" do
    steer
    assert_response :accepted
    guarded_id = response.parsed_body.dig("input", "public_id")
    post inputs_path(@conversation), headers: auth("ordinary"), as: :json,
      params: { input: { text: "ordinary correction", delivery_mode: "steer" } }
    assert_response :accepted
    ordinary_id = response.parsed_body.dig("input", "public_id")
    [guarded_id, ordinary_id].each do |public_id|
      delete "#{inputs_path(@conversation)}/#{public_id}", headers: auth
      assert_response :no_content
    end

    get events_path(@conversation), headers: auth
    assert_response :success
    items = response.parsed_body.fetch("events")
    %w[input_accepted input_deleted].each do |type|
      guarded = items.find { |item| item.fetch("type") == type && item.dig("payload", "input_public_id") == guarded_id }
      ordinary = items.find { |item| item.fetch("type") == type && item.dig("payload", "input_public_id") == ordinary_id }
      assert_equal @seam.run.public_id, guarded.fetch("payload").fetch("expected_steering_run_public_id")
      assert_not ordinary.fetch("payload").key?("expected_steering_run_public_id")
    end
  end

  test "a changed execution refuses without input receipt or event" do
    @seam.variant.update!(status: "completed")
    @seam.turn.update!(status: "completed")
    replacement = create_run_backed_turn(conversation: @conversation, acting_user: @human)

    assert_no_difference ["Input.count", "ConversationCommandReceipt.count", "EventItem.count"] do
      steer
      assert_response :conflict
      assert_equal "steering_target_changed", response.parsed_body.dig("error", "code")
    end
    assert_empty replacement.run.steering_inputs

    steer(target: replacement.run.public_id)
    assert_response :accepted
    assert_equal [replacement.turn.id], Input.pluck(:steering_target_turn_id)
  end

  test "idle delivered canceled and other addressee targets do not fall back to queue" do
    steer(answering_user_public_id: users(:agent).public_id)
    assert_response :conflict
    assert_equal "steering_target_changed", response.parsed_body.dig("error", "code")
    @seam.run.update!(delivered_at: Time.current)
    steer
    assert_response :conflict
    @seam.run.update!(delivered_at: nil, status: "canceling", canceling_since: Time.current)
    steer
    assert_response :conflict
    @seam.turn.update!(status: "completed")
    steer
    assert_response :conflict
    assert_empty Input.all

    post inputs_path(@conversation), headers: auth("unguarded"), as: :json,
      params: { input: { text: "next turn", delivery_mode: "steer" } }
    assert_response :accepted
    assert_equal "pending", response.parsed_body.dig("input", "state")
  end

  test "the guard requires steer and malformed selectors cannot be silently omitted" do
    steer(mode: "queue")
    assert_response :unprocessable_content
    assert_equal "steering_guard_requires_steer", response.parsed_body.dig("error", "code")
    ["broken", [@seam.run.public_id], { id: @seam.run.public_id }].each do |target|
      steer(target: target)
      assert_response :bad_request
      assert_equal "parameter_invalid", response.parsed_body.dig("error", "code")
    end
    assert_empty Input.all
  end

  test "the guard honors merged query parameters before scalar filtering" do
    [SecureRandom.uuid_v7, "broken", @seam.run.public_id.upcase].each_with_index do |target, index|
      query = URI.encode_www_form("input[text]" => "only this execution", "input[delivery_mode]" => "steer",
        "input[expected_steering_run_public_id]" => target)
      post "#{inputs_path(@conversation)}?#{query}", headers: auth("query-guard-#{index}"), as: :json,
        params: { input: {} }

      assert_response [:conflict, :bad_request, :accepted].fetch(index)
    end
    input = Input.sole
    assert_equal @seam.run.public_id, input.expected_steering_run_public_id
    assert_equal "steering", input.state
  end

  test "immediate steer keeps its guarded execution and wakes its scheduler" do
    clear_enqueued_jobs
    assert_enqueued_with(job: Runs::ScheduleJob, args: [@seam.run.id]) do
      steer(mode: "steer_now", key: "immediate")
      assert_response :accepted
    end
    accepted = response.parsed_body.fetch("input")
    assert_equal "steer_now", accepted.fetch("delivery_mode")
    assert_equal "steering", accepted.fetch("state")
    assert_equal @seam.run.public_id, accepted.fetch("expected_steering_run_public_id")

    assert_no_enqueued_jobs do
      steer(mode: "steer_now", key: "immediate")
      assert_response :accepted
      assert_equal accepted, response.parsed_body.fetch("input")
    end
  end

  test "archive admits only a steer pinned to its live execution and permits its timing upgrade" do
    assert_predicate Conversations::Archive.call(conversation: @conversation), :accepted?
    steer
    assert_response :accepted
    input = Input.find_by!(public_id: response.parsed_body.dig("input", "public_id"))
    patch "#{inputs_path(@conversation)}/#{input.public_id}", headers: auth, as: :json,
      params: { input: { delivery_mode: "steer_now" } }
    assert_response :success
    assert_equal "steer_now", input.reload.delivery_mode

    post inputs_path(@conversation), headers: auth("new-topic"), as: :json,
      params: { input: { text: "new independent work", delivery_mode: "steer" } }
    assert_response :conflict
    assert_equal "conversation_archived", response.parsed_body.dig("error", "code")

    steer(target: SecureRandom.uuid_v7)
    assert_response :conflict
    assert_equal "steering_target_changed", response.parsed_body.dig("error", "code")
    @seam.run.update!(delivered_at: Time.current)
    steer
    assert_response :conflict
    assert_equal "steering_target_changed", response.parsed_body.dig("error", "code")
    assert_equal [input.id], @conversation.inputs.pluck(:id)
  end

  test "send now upgrades a held input without changing its content target or identity" do
    steer
    input = Input.find_by!(public_id: response.parsed_body.dig("input", "public_id"))
    original = input.attributes.except("delivery_mode", "updated_at", "lock_version")
    body_id = input.content_body.id
    version = input.lock_version
    path = "#{inputs_path(@conversation)}/#{input.public_id}"
    clear_enqueued_jobs

    assert_enqueued_with(job: Runs::ScheduleJob, args: [@seam.run.id]) do
      patch path, headers: auth, as: :json,
        params: { input: { delivery_mode: "steer_now", expected_lock_version: version } }
      assert_response :success
    end
    assert_equal original, input.reload.attributes.except("delivery_mode", "updated_at", "lock_version")
    assert_equal "steer_now", input.delivery_mode
    assert_equal body_id, input.content_body.id
    assert_equal "only this execution", input.text
    assert_equal "steer_now", @conversation.event_items.where(item_type: "input_edited").sole.payload.fetch("delivery_mode")

    assert_no_difference "EventItem.count" do
      patch path, headers: auth, as: :json, params: { input: { delivery_mode: "steer_now" } }
      assert_response :success
    end
    patch path, headers: auth, as: :json,
      params: { input: { delivery_mode: "steer_now", expected_lock_version: version } }
    assert_response :conflict
    assert_equal "stale_object", response.parsed_body.dig("error", "code")
  end

  test "send now cannot edit held content or turn a queued row into a different target" do
    steer
    input = Input.find_by!(public_id: response.parsed_body.dig("input", "public_id"))
    path = "#{inputs_path(@conversation)}/#{input.public_id}"
    patch path, headers: auth, as: :json, params: { input: { delivery_mode: "steer_now", text: "replace" } }
    assert_response :conflict
    assert_equal "steering_held", response.parsed_body.dig("error", "code")
    assert_equal ["steer", "only this execution"], [input.reload.delivery_mode, input.text]

    patch path, headers: auth, as: :json, params: { input: { delivery_mode: "queue" } }
    assert_response :unprocessable_content
    assert_equal "steer", input.reload.delivery_mode

    post inputs_path(@conversation), headers: auth("queued"), as: :json,
      params: { input: { text: "next turn", delivery_mode: "queue" } }
    queued = response.parsed_body.dig("input", "public_id")
    patch "#{inputs_path(@conversation)}/#{queued}", headers: auth, as: :json,
      params: { input: { delivery_mode: "steer_now" } }
    assert_response :unprocessable_content
    assert_equal "queue", Input.find_by!(public_id: queued).delivery_mode
  end

  test "regeneration reads only its own correction and ending the old loop cancels its guard" do
    steer
    assert_response :accepted
    old_input = Input.find_by!(public_id: response.parsed_body.dig("input", "public_id"))
    @seam.variant.update!(status: "completed")
    variant = @seam.turn.variants.create!(account: @account, position: 1,
      status: "running", source: "run", origin_variant: @seam.variant)
    replacement = Run.create!(workspace: @workspace, creating_user: @human,
      status: "running", variant: variant, approval_mode: "bypass")
    assert_empty replacement.steering_inputs
    steer
    assert_response :conflict
    steer(target: replacement.public_id)
    assert_response :accepted
    new_id = response.parsed_body.dig("input", "public_id")
    assert_equal [new_id], replacement.steering_inputs.pluck(:public_id)

    @seam.run.with_lock do
      Runs::Transition.run(@seam.run, status: "canceled", completed_at: Time.current)
    end
    assert_not Input.exists?(old_input.id)
    assert_equal [new_id], replacement.steering_inputs.pluck(:public_id)
  end
end
